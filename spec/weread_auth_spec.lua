local A = require("assertions")
local Json = require("legado.lib.json_codec")
local Auth = require("legado.lib.weread_session")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local pending, saved = {}, nil
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
        now = function() return 1788134400 end, random = function() return 7 end }
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
return count
