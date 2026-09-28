local A = require("assertions")
local Json = require("legado.lib.json_codec")
local Auth = require("legado.lib.weread_session")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local pending, saved = {}, nil
local clock_now = 1788134400
local requests = { execute = function(_, request, callback)
    local row = { request = request, callback = callback, cancelled = false }
    pending[#pending + 1] = row
    return { cancel = function() row.cancelled = true end }
end }
local fs = {
    readBounded = function() return saved end,
    atomicWrite = function(_, _, value) saved = value; return true end,
}
local function new_auth()
    return Auth.new{ requests = requests, fs = fs, path = "weread-session.json",
        sha256 = function() return string.rep("a", 64) end,
        now = function() return clock_now end, random = function() return 7 end }
end
local auth = new_auth()
local qr, failure
auth:beginLogin(function(value, err) qr, failure = value, err end)
eq(true, pending[1].request.url:find("/wxticket", 1, true) ~= nil, "login starts with WeRead ticket")
pending[1].callback({ status = 200, body = Json.encode({ signature = "signed", timeStamp = 123 }) })
eq(true, pending[2].request.url:find("open.weixin.qq.com/connect/sdk/qrconnect", 1, true) ~= nil,
    "ticket is exchanged for a WeChat QR identifier")
pending[2].callback({ status = 200, body = Json.encode({ errcode = 0, uuid = "qr-123" }) })
eq("qr-123", qr.uuid, "QR identifier is returned")
eq("https://open.weixin.qq.com/connect/confirm?uuid=qr-123", qr.payload, "QR payload can be displayed locally")
eq(nil, failure, "valid QR has no failure")
local state, code
auth:pollLogin(qr.uuid, function(value, status) code, state = value, status end)
pending[3].callback({ status = 200, body = Json.encode({ wx_errcode = 408 }) })
eq("waiting", state, "unscanned QR can be polled again")
auth:pollLogin(qr.uuid, function(value, status) code, state = value, status end)
eq(true, pending[4].request.url:find("last=408", 1, true) ~= nil,
    "the next QR poll sends the last waiting state")
pending[4].callback({ status = 200, body = Json.encode({ wx_errcode = 405, wx_code = "wx-code" }) })
eq("confirmed", state, "confirmed scan is detected")
eq("wx-code", code, "confirmation returns the one-time code")
local logged
auth:completeLogin(code, function(value) logged = value end)
eq(true, pending[5].request.url:find("i.weread.qq.com/login", 1, true) ~= nil,
    "one-time code is exchanged at the Eink login endpoint")
local body = pending[5].request.body
if type(body) == "string" then body = Json.decode(body) end
eq("wx-code", body.code, "login body contains the one-time code")
eq(string.rep("a", 64), body.signature, "login body is signed")
eq(32,#body.deviceId,'Eink device identifier has the expected length')
eq(32,#body.installId,'Eink installation identifier has the expected length')
pending[5].callback({ status = 200, body = Json.encode({ vid = 1234, accessToken = "access", refreshToken = "refresh" }) })
eq("1234", logged.vid, "login returns the user identifier")
eq("access", auth:session().access_token, "access token is available in memory")
eq(true, type(saved) == "string" and saved:find("refresh", 1, true) ~= nil,
    "refresh token is durably stored on device")
local restarted = new_auth()
eq("1234", restarted:session().vid, "session is restored after restart")
local renewed
restarted:refresh(function(value) renewed = value end)
local refresh_body = pending[6].request.body
if type(refresh_body) == "string" then refresh_body = Json.decode(refresh_body) end
eq("refresh", refresh_body.refreshToken, "refresh uses the stored token")
pending[6].callback({ status = 200, body = Json.encode({ vid = 1234, accessToken = "new-access" }) })
eq("new-access", renewed.access_token, "refresh replaces the access token")
eq("refresh", restarted:session().refresh_token, "refresh may retain the previous refresh token")
local cancelled_called = false
local handle = restarted:beginLogin(function() cancelled_called = true end)
handle:cancel()
eq(true, pending[7].cancelled, "cancel stops an active QR request")
pending[7].callback({ status = 200, body = Json.encode({ signature = "later", timeStamp = 1 }) })
eq(false, cancelled_called, "cancelled QR callback is ignored")
auth:pollLogin("new-qr", function() end)
eq(nil, pending[8].request.url:find("last=", 1, true), "another QR begins without the previous state")
pending[8].callback({ status = 200, body = Json.encode({ wx_errcode = 404 }) })
auth:pollLogin("new-qr", function() end)
eq(true, pending[9].request.url:find("last=404", 1, true) ~= nil,
    "the scanned state is carried into the next QR poll")

local retry_state
auth:pollLogin("network-qr", function(_, status) retry_state = status end)
pending[10].callback(nil, {code = "NETWORK_ERROR"})
eq("retrying", retry_state, "temporary network errors keep the current QR available")

local deadline_state
auth:pollLogin("deadline-qr", function(_, status) deadline_state = status end)
clock_now = clock_now + 299
pending[11].callback(nil, {code = "TIMEOUT"})
eq("waiting", deadline_state, "long-poll timeout before the deadline keeps waiting")
local request_count = #pending
clock_now = clock_now + 2
auth:pollLogin("deadline-qr", function(_, status) deadline_state = status end)
eq("expired", deadline_state, "QR polling stops after five minutes")
eq(request_count, #pending, "expired QR does not start another network request")

do
    local shared = new_auth()
    local before = #pending
    local first, second
    shared:refresh(function(value) first = value end)
    shared:refresh(function(value) second = value end)
    eq(before + 1, #pending, "concurrent refresh callers share one login request")
    pending[before + 1].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "shared-access" }) })
    eq("shared-access", first.access_token, "first caller receives the renewed session")
    eq("shared-access", second.access_token, "second caller receives the same renewed session")
end

do
    local shared = new_auth()
    local before = #pending
    local cancelled_called, remaining
    local first = shared:refresh(function() cancelled_called = true end)
    shared:refresh(function(value) remaining = value end)
    first:cancel()
    eq(false, pending[before + 1].cancelled,
        "cancelling one waiter keeps the shared login request active")
    pending[before + 1].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "remaining-access" }) })
    eq(nil, cancelled_called, "cancelled waiter does not receive the renewal result")
    eq("remaining-access", remaining.access_token, "remaining waiter receives the renewal result")
end

do
    local shared = new_auth()
    local before, saved_before = #pending, saved
    local callbacks = 0
    local first = shared:refresh(function() callbacks = callbacks + 1 end)
    local second = shared:refresh(function() callbacks = callbacks + 1 end)
    first:cancel()
    second:cancel()
    eq(true, pending[before + 1].cancelled, "last waiter cancels the shared login request")
    pending[before + 1].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "late-access" }) })
    eq(0, callbacks, "late cancelled renewal cannot notify former waiters")
    eq(saved_before, saved, "late cancelled renewal cannot overwrite the saved session")
    local renewed
    shared:refresh(function(value) renewed = value end)
    eq(before + 2, #pending, "a new request may start after all waiters cancel")
    pending[before + 2].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "next-access" }) })
    eq("next-access", renewed.access_token, "new renewal still succeeds")
end

do
    local shared = new_auth()
    local before = #pending
    local second_handle, cancel_result, second_called
    shared:refresh(function() cancel_result = second_handle:cancel() end)
    second_handle = shared:refresh(function() second_called = true end)
    pending[before + 1].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "fanout-access" }) })
    eq(true, cancel_result, "first waiter can cancel an undelivered second waiter")
    eq(nil, second_called, "cancelled second waiter is skipped during result delivery")
end

do
    local shared = new_auth()
    local before = #pending
    local second
    shared:refresh(function() error("first waiter failed") end)
    shared:refresh(function(value) second = value end)
    local ok, callback_error = pcall(pending[before + 1].callback, { status = 200,
        body = Json.encode({ vid = 1234, accessToken = "isolated-access" }) })
    eq(false, ok, "a caller exception remains visible")
    eq(true, tostring(callback_error):find("first waiter failed", 1, true) ~= nil,
        "a caller exception retains its original reason")
    eq("isolated-access", second and second.access_token,
        "one caller exception does not strand other renewal waiters")
end

do
    local shared = new_auth()
    local before = #pending
    local first_error, second_error
    shared:refresh(function(_, err) first_error = err end)
    shared:refresh(function(_, err) second_error = err end)
    eq(before + 1, #pending, "failed concurrent renewals still use one login request")
    pending[before + 1].callback({ status = 401, body = "{}" })
    eq("微信读书登录或续期失败", first_error, "first caller receives the renewal failure")
    eq(first_error, second_error, "second caller receives the same renewal failure")
end

do
    local shared = new_auth()
    local before = #pending
    local refreshed, refresh_error, logged
    shared:refresh(function(value, err) refreshed, refresh_error = value, err end)
    shared:completeLogin("new-account-code", function(value) logged = value end)
    pending[before + 2].callback({ status = 200,
        body = Json.encode({ vid = 9999, accessToken = "new-account-access",
            refreshToken = "new-account-refresh" }) })
    eq("9999", logged.vid, "new account login succeeds while old renewal is pending")
    local new_account_renewed
    shared:refresh(function(value) new_account_renewed = value end)
    eq(before + 3, #pending, "new account does not join the old account renewal")
    local new_refresh_body = pending[before + 3].request.body
    if type(new_refresh_body) == "string" then new_refresh_body = Json.decode(new_refresh_body) end
    eq("new-account-refresh", new_refresh_body.refreshToken,
        "new account renews with its own refresh token")
    pending[before + 1].callback({ status = 200,
        body = Json.encode({ vid = 1234, accessToken = "old-account-late" }) })
    eq("9999", shared:session().vid, "late old-account renewal cannot replace the new login")
    eq(nil, refreshed, "late old-account renewal does not report stale credentials")
    eq("微信读书会话已更新", refresh_error, "stale renewal reports the account change")
    pending[before + 3].callback({ status = 200,
        body = Json.encode({ vid = 9999, accessToken = "new-account-renewed" }) })
    eq("new-account-renewed", new_account_renewed.access_token,
        "new account renewal completes independently")
end

do
    local sync_calls = 0
    local synchronous = Auth.new{
        requests = { execute = function(_, _, callback)
            sync_calls = sync_calls + 1
            callback({ status = 200, body = Json.encode({ vid = 1234,
                accessToken = "instant-" .. sync_calls }) })
            return { cancel = function() end }
        end },
        fs = fs, path = "weread-session.json", sha256 = function() return string.rep("a", 64) end,
        now = function() return clock_now end, random = function() return 7 end,
    }
    local first, second
    synchronous:refresh(function(value) first = value end)
    synchronous:refresh(function(value) second = value end)
    eq("instant-1", first.access_token, "synchronous renewal reaches its caller")
    eq("instant-2", second.access_token, "completed synchronous renewal clears the shared flight")
    eq(2, sync_calls, "later synchronous renewal starts a new login request")
end
return count
