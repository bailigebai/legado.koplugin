local Crypto = require("legado.lib.license_crypto")
local Json = require("legado.lib.json_codec")
local Url = require("legado.lib.safe_functions").functions.urlencode

local Auth = {}
Auth.__index = Auth

local API = "https://i.weread.qq.com"
local WX = "https://open.weixin.qq.com"
local APP_ID = "wxab9b71ad2b90ff34"
local USER_AGENT = "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)"

local function headers(extra)
    local values = { ["User-Agent"] = USER_AGENT, baseapi = "30", appver = "2.1.2.10245900",
        basever = "2.1.2.10245900", osver = "11", channelId = "900" }
    for key, value in pairs(extra or {}) do values[key] = value end
    return values
end

local function decode(response)
    if type(response) ~= "table" or type(response.body) ~= "string" then return nil end
    local ok, value = pcall(Json.decode, response.body)
    if ok and type(value) == "table" then return value end
end

local function success(response, err)
    local status = response and tonumber(response.status or response.code)
    return not err and status and status >= 200 and status < 300
end

local function query(values)
    local parts = {}
    for _, key in ipairs({ "appid", "noncestr", "timestamp", "scope", "signature", "f", "uuid", "last" }) do
        if values[key] ~= nil then parts[#parts + 1] = Url(key) .. "=" .. Url(tostring(values[key])) end
    end
    return table.concat(parts, "&")
end

local function copy_session(session)
    if not session then return nil end
    return { vid = session.vid, access_token = session.access_token,
        refresh_token = session.refresh_token, device_id = session.device_id }
end

local function valid_session(session)
    if type(session) ~= "table" then return false end
    for _, key in ipairs({ "vid", "access_token", "refresh_token", "device_id" }) do
        if type(session[key]) ~= "string" or session[key] == "" or #session[key] > 4096 then return false end
    end
    return true
end

function Auth.new(options)
    options = options or {}
    assert(options.requests and options.fs and options.path, "WeRead auth requires requests, fs and path")
    local self = setmetatable({ requests = options.requests, fs = options.fs, path = options.path,
        sha256 = options.sha256 or Crypto.sha256,
        now = options.now or os.time, random = options.random or function() return math.random(0, 999) end }, Auth)
    local raw = type(self.fs.readBounded)=='function' and self.fs:readBounded(self.path, 16384) or nil
    if type(raw) == "string" then
        local ok, session = pcall(Json.decode, raw)
        if ok and valid_session(session) then self.saved = copy_session(session) end
    end
    return self
end

function Auth:session() return copy_session(self.saved) end
function Auth:hasSession() return self.saved ~= nil end

function Auth:_save(session)
    if not valid_session(session) then return nil, "登录响应缺少会话信息" end
    local ok, encoded = pcall(Json.encode, session)
    if not ok then return nil, "无法保存登录会话" end
    local saved = self.fs:atomicWrite(self.path, encoded)
    if not saved then return nil, "无法保存登录会话" end
    self.saved = copy_session(session)
    return self:session()
end

function Auth:_deviceId()
    if self.saved then return self.saved.device_id end
    local digits = {}
    for index = 1, 19 do
        digits[index] = tostring(math.floor(tonumber(self.random()) or 0) % (index == 1 and 9 or 10))
    end
    return "eink334691225" .. table.concat(digits)
end

function Auth:_loginBody(device_id, fields)
    local timestamp = math.floor((tonumber(self.now()) or 0) * 1000)
    local random = math.floor(tonumber(self.random()) or 0) % 1000
    local signature = self.sha256(tostring(timestamp) .. device_id .. tostring(random))
    if type(signature) ~= "string" or #signature ~= 64 then return nil end
    local body = { deviceId = device_id, deviceName = "BOOX", deviceType = 3,
        random = random, signature = signature, timestamp = timestamp, trackId = "" }
    for key, value in pairs(fields) do body[key] = value end
    return body
end

function Auth:beginLogin(callback)
    local cancelled, advanced, active = false, false, nil
    local ticket_handle = self.requests:execute({ url = API .. "/wxticket?nonceStr=weread", method = "GET", source_id = "weread",
        headers = headers(), priority = "foreground" }, function(response, err)
        if cancelled then return end
        advanced = true
        local ticket = success(response, err) and decode(response) or nil
        if not ticket or type(ticket.signature) ~= "string" or ticket.timeStamp == nil then
            return callback(nil, "获取微信读书二维码票据失败")
        end
        active = self.requests:execute({ url = WX .. "/connect/sdk/qrconnect?" .. query({
            appid = APP_ID, noncestr = "weread", timestamp = ticket.timeStamp,
            scope = "snsapi_userinfo,snsapi_timeline,snsapi_friend", signature = ticket.signature,
        }), method = "GET", source_id = "weread", headers = { ["User-Agent"] = USER_AGENT }, priority = "foreground" }, function(result, qr_error)
            if cancelled then return end
            local data = success(result, qr_error) and decode(result) or nil
            if not data or tonumber(data.errcode) ~= 0 or type(data.uuid) ~= "string" or data.uuid == "" then
                return callback(nil, "获取微信扫码标识失败")
            end
            callback({ uuid = data.uuid, payload = WX .. "/connect/confirm?uuid=" .. Url(data.uuid) })
        end)
    end)
    if not advanced then active = ticket_handle end
    return { cancel = function()
        if cancelled then return false end
        cancelled = true
        if active and type(active.cancel) == "function" then active:cancel() end
        return true
    end }
end

function Auth:pollLogin(uuid, callback)
    if type(uuid) ~= "string" or uuid == "" or #uuid > 256 then
        callback(nil, "error", "扫码标识无效"); return nil
    end
    if self.poll_uuid ~= uuid then self.poll_uuid, self.poll_last = uuid, nil end
    return self.requests:execute({ url = "https://long.open.weixin.qq.com/connect/l/qrconnect?"
        .. query({ f = "json", uuid = uuid, last = self.poll_last }), method = "GET", source_id = "weread", timeout = 20,
        headers = { ["User-Agent"] = "Mozilla/5.0" }, priority = "foreground" }, function(response, err)
        if self.poll_uuid ~= uuid then return end
        if err and err.code == "TIMEOUT" then return callback(nil, "waiting") end
        local data = success(response, err) and decode(response) or nil
        local code = data and tonumber(data.wx_errcode)
        if code == 405 and type(data.wx_code) == "string" and data.wx_code ~= "" then
            self.poll_uuid, self.poll_last = nil, nil
            callback(data.wx_code, "confirmed")
        elseif code == 404 or code == 408 then
            self.poll_last = code
            callback(nil, code == 404 and "scanned" or "waiting")
        else
            self.poll_uuid, self.poll_last = nil, nil
            if code == 403 then callback(nil, "denied", "已在微信中拒绝登录")
            else callback(nil, "expired", "二维码已失效，请重新登录") end
        end
    end)
end

function Auth:_exchange(fields, previous, callback, device_id)
    device_id = device_id or previous and previous.device_id or self:_deviceId()
    local body = self:_loginBody(device_id, fields)
    if not body then callback(nil, "签名组件不可用"); return nil end
    return self.requests:execute({ url = API .. "/login", method = "POST", source_id = "weread", body = body,
        body_type = "json", headers = headers(), priority = "foreground" }, function(response, err)
        local data = success(response, err) and decode(response) or nil
        local session = data and {
            vid = tostring(data.vid or previous and previous.vid or ""),
            access_token = data.accessToken,
            refresh_token = data.refreshToken or previous and previous.refresh_token,
            device_id = device_id,
        } or nil
        if not valid_session(session) then return callback(nil, "微信读书登录或续期失败") end
        local saved, save_error = self:_save(session)
        callback(saved, save_error)
    end)
end

function Auth:completeLogin(code, callback)
    if type(code) ~= "string" or code == "" or #code > 4096 then
        callback(nil, "微信确认码无效"); return nil
    end
    local device_id = self:_deviceId()
    local digits={}
    for index=1,26 do digits[index]=tostring(math.floor(tonumber(self.random()) or 0)%10) end
    return self:_exchange({ code = code, appFirstInstall = 1, isAutoLogout = 0,
        isFromQrcode = 1, installId = "eink31" .. table.concat(digits) }, nil, callback, device_id)
end

function Auth:refresh(callback)
    local current = self:session()
    if not current then callback(nil, "请先扫码登录微信读书"); return nil end
    return self:_exchange({ refreshToken = current.refresh_token, inBackground = 0,
        kickType = 1, refCgi = "" }, current, callback)
end

return Auth
