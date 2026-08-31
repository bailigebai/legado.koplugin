local Errors = require("legado.lib.errors")
local Logger = require("legado.lib.logger")
local Charset = require("legado.lib.charset")
local CookieJar = require("legado.lib.cookie_jar")
local SafeFunctions = require("legado.lib.safe_functions")
local SocketTransport = require("legado.lib.socket_transport")
local SubprocessAdapter = require("legado.lib.subprocess_adapter")
local Wire = require("legado.lib.wire_codec")

local RequestEngine = {}
RequestEngine.__index = RequestEngine
RequestEngine.DEFAULT_TIMEOUT = 20
RequestEngine.MAX_TIMEOUT = 20
RequestEngine.DEFAULT_MAX_BYTES = 4 * 1024 * 1024
RequestEngine.MAX_BYTES = 4 * 1024 * 1024
RequestEngine.DEFAULT_REDIRECTS = 5
RequestEngine.MAX_REDIRECTS = 5
RequestEngine.DEFAULT_CONCURRENCY = 2
RequestEngine.MAX_CONCURRENCY = 3
RequestEngine.POLL_INTERVAL = 0.05

local function optional_require(name)
    local ok, value = pcall(require, name)
    if ok then return value end
    return nil
end

local function shallow_copy(value)
    local result = {}
    for key, child in pairs(value or {}) do result[key] = child end
    return result
end

local function header_value(headers, wanted)
    wanted = wanted:lower()
    for name, value in pairs(headers or {}) do
        if tostring(name):lower() == wanted then return value, name end
    end
    return nil, nil
end

local function set_default_header(headers, name, value)
    if header_value(headers, name) == nil then headers[name] = value end
end

local function remove_header(headers, wanted)
    local _, name = header_value(headers, wanted)
    if name ~= nil then headers[name] = nil end
end

local function clamp(value, fallback, maximum, integer, allow_zero)
    value = tonumber(value) or fallback
    if value < 0 or (value == 0 and not allow_zero) then value = fallback end
    value = math.min(value, maximum)
    if integer then value = math.floor(value) end
    return value
end

local function setting(settings, key, fallback)
    if type(settings) ~= "table" then return fallback end
    if type(settings.get) == "function" then
        local ok, value = pcall(settings.get, settings, key)
        if ok and value ~= nil then return value end
    elseif settings[key] ~= nil then
        return settings[key]
    end
    return fallback
end

local json_escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_string(value)
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        return json_escapes[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
end

local function json_encode(value, seen)
    local value_type = type(value)
    if value == nil then return "null" end
    if value_type == "boolean" or value_type == "number" then return tostring(value) end
    if value_type == "string" then return json_string(value) end
    if value_type ~= "table" then error("unsupported JSON value type") end
    seen = seen or {}
    if seen[value] then error("JSON body contains a cycle") end
    seen[value] = true
    local count, maximum, array = 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then array = false
        else maximum = math.max(maximum, key) end
    end
    if array and maximum ~= count then array = false end
    local output = {}
    if array then
        for index = 1, count do output[#output + 1] = json_encode(value[index], seen) end
        seen[value] = nil
        return "[" .. table.concat(output, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then error("JSON object keys must be strings") end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do output[#output + 1] = json_string(key) .. ":" .. json_encode(value[key], seen) end
    seen[value] = nil
    return "{" .. table.concat(output, ",") .. "}"
end

local function form_encode(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then error("form body must be a string or table") end
    local keys, output = {}, {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        output[#output + 1] = SafeFunctions.functions.urlencode(key)
            .. "=" .. SafeFunctions.functions.urlencode(value[key])
    end
    return table.concat(output, "&")
end

local function origin(url)
    local scheme, authority = tostring(url or ""):match("^([%a][%w+.-]*)://([^/?#]+)")
    if not scheme then return nil end
    return scheme:lower() .. "://" .. authority:lower()
end

local function is_redirect(status)
    return status == 301 or status == 302 or status == 303 or status == 307 or status == 308
end

local function site_rejected(status, body)
    if status == 403 or status == 429 then return true end
    local lower = tostring(body or ""):lower()
    return lower:find("captcha", 1, true) ~= nil
        or lower:find("cloudflare", 1, true) ~= nil
        or lower:find("cf-chl-", 1, true) ~= nil
        or lower:find("just a moment", 1, true) ~= nil
        or lower:find("attention required", 1, true) ~= nil
end

local function transport_error(cause, url)
    local message = tostring(cause or "network transport failed")
    if message:lower():find("timeout", 1, true) then
        return Errors.new(Errors.TIMEOUT, "source request timed out", { url = url })
    end
    return Errors.new(Errors.NETWORK_ERROR, "source request failed", { url = url, cause = message })
end

local function default_scheduler()
    return optional_require("ui/uimanager")
end

local function default_now(scheduler)
    if scheduler and type(scheduler.now) == "function" then
        return function() return scheduler:now() end
    end
    local socket = optional_require("socket")
    if socket and type(socket.gettime) == "function" then return socket.gettime end
    return os.time
end

local function safe_log(logger, level, value)
    if not logger or type(logger[level]) ~= "function" then return end
    logger[level](logger, Logger.redact(value))
end

function RequestEngine.new(options)
    options = options or {}
    local scheduler = options.scheduler or default_scheduler()
    assert(scheduler and type(scheduler.scheduleIn) == "function", "RequestEngine requires scheduler.scheduleIn")
    local settings = options.settings
    local concurrency = clamp(
        options.concurrency or setting(settings, "concurrency", RequestEngine.DEFAULT_CONCURRENCY),
        RequestEngine.DEFAULT_CONCURRENCY, RequestEngine.MAX_CONCURRENCY, true)
    return setmetatable({
        transport = options.transport or SocketTransport.new(),
        scheduler = scheduler,
        subprocess = options.subprocess or SubprocessAdapter.new(),
        charset = options.charset or Charset.new({ converter = options.charset_converter }),
        cookies = options.cookie_store or CookieJar.new(),
        logger = options.logger or Logger.new(),
        settings = settings,
        now = options.now or default_now(scheduler),
        concurrency = concurrency,
    }, RequestEngine)
end

function RequestEngine:getConcurrencyLimit()
    return self.concurrency
end

function RequestEngine:_normalize(request)
    if type(request) ~= "table" or type(request.url) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "request requires a URL")
    end
    local scheme = request.url:match("^([%a][%w+.-]*):")
    if not scheme or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then
        return nil, Errors.new(Errors.INVALID_INPUT, "request URL must use HTTP or HTTPS")
    end
    local normalized = shallow_copy(request)
    normalized.headers = shallow_copy(request.headers)
    normalized.method = tostring(request.method or (request.body ~= nil and "POST" or "GET")):upper()
    if normalized.method ~= "GET" and normalized.method ~= "POST" and normalized.method ~= "HEAD" then
        return nil, Errors.new(Errors.INVALID_INPUT, "request method is unsupported", { method = normalized.method })
    end
    normalized.timeout = clamp(request.timeout or setting(self.settings, "timeout", RequestEngine.DEFAULT_TIMEOUT),
        RequestEngine.DEFAULT_TIMEOUT, RequestEngine.MAX_TIMEOUT, false)
    normalized.max_bytes = clamp(request.max_bytes or setting(self.settings, "max_response_bytes", RequestEngine.DEFAULT_MAX_BYTES),
        RequestEngine.DEFAULT_MAX_BYTES, RequestEngine.MAX_BYTES, true)
    normalized.max_redirects = clamp(request.max_redirects or setting(self.settings, "redirects", RequestEngine.DEFAULT_REDIRECTS),
        RequestEngine.DEFAULT_REDIRECTS, RequestEngine.MAX_REDIRECTS, true, true)

    if request.body_type == "json" and type(request.body) ~= "string" then
        local ok, encoded = pcall(json_encode, request.body)
        if not ok then return nil, Errors.new(Errors.INVALID_INPUT, "JSON request body is invalid", { cause = tostring(encoded) }) end
        normalized.body = encoded
        set_default_header(normalized.headers, "Content-Type", "application/json; charset=utf-8")
    elseif request.body_type == "form" then
        local ok, encoded = pcall(form_encode, request.body)
        if not ok then return nil, Errors.new(Errors.INVALID_INPUT, "form request body is invalid", { cause = tostring(encoded) }) end
        normalized.body = encoded
        set_default_header(normalized.headers, "Content-Type", "application/x-www-form-urlencoded")
    elseif request.body ~= nil and type(request.body) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "request body must be a string unless body_type is json or form")
    end
    return normalized, nil
end

function RequestEngine:_request_once(request)
    local chunks, received, limit_error = {}, 0, nil
    local response, err = self.transport:request(request, function(chunk)
        if type(chunk) ~= "string" then return nil, "invalid response chunk" end
        received = received + #chunk
        if received > request.max_bytes then
            limit_error = Errors.new(Errors.RESPONSE_TOO_LARGE, "source response exceeds byte limit", {
                max_bytes = request.max_bytes,
                received_bytes = received,
            })
            return nil, "response byte limit reached"
        end
        chunks[#chunks + 1] = chunk
        return true
    end)
    if limit_error then return nil, limit_error end
    if not response then return nil, transport_error(err, request.url) end
    response.body = table.concat(chunks)
    response.headers = response.headers or {}
    response.final_url = request.url
    return response, nil
end

function RequestEngine:_perform(request)
    local current = shallow_copy(request)
    current.headers = shallow_copy(request.headers)
    local seen = { [current.url] = true }
    local redirects = 0
    local cookie_updates = {}
    local function outcome(value)
        value.cookie_updates = cookie_updates
        return value
    end
    while true do
        local jar_cookie = type(self.cookies.header) == "function"
            and self.cookies:header(current.source_id, current.url) or nil
        if jar_cookie then
            local supplied = header_value(current.headers, "cookie")
            local _, cookie_name = header_value(current.headers, "cookie")
            current.headers[cookie_name or "Cookie"] = supplied and (supplied .. "; " .. jar_cookie) or jar_cookie
        end
        safe_log(self.logger, "debug", {
            event = "source_request", url = current.url, method = current.method, headers = current.headers,
        })
        local response, request_error = self:_request_once(current)
        if not response then return outcome({ error = request_error }) end

        local set_cookie = header_value(response.headers, "set-cookie")
        if set_cookie and type(self.cookies.store) == "function" then
            self.cookies:store(current.source_id, current.url, set_cookie)
            cookie_updates[#cookie_updates + 1] = {
                source_id = current.source_id,
                url = current.url,
                value = set_cookie,
            }
        end

        local status = tonumber(response.status)
        local location = header_value(response.headers, "location")
        if status and is_redirect(status) and location then
            if redirects >= current.max_redirects then
                return outcome({ error = Errors.new(Errors.NETWORK_ERROR, "source redirect limit exceeded", {
                    reason = "max_redirects", status = status, redirects = redirects,
                }) })
            end
            local target = SafeFunctions.resolve_url(current.url, tostring(location))
            local target_scheme = target:match("^([%a][%w+.-]*):")
            if not target_scheme or (target_scheme:lower() ~= "http" and target_scheme:lower() ~= "https") then
                return outcome({ error = Errors.new(Errors.NETWORK_ERROR, "redirect target is unsupported", {
                    reason = "redirect_scheme", status = status,
                }) })
            end
            if seen[target] then
                return outcome({ error = Errors.new(Errors.NETWORK_ERROR, "source redirect loop detected", {
                    reason = "redirect_loop", status = status,
                }) })
            end
            seen[target] = true
            redirects = redirects + 1
            local prior_origin = origin(current.url)
            current.url = target
            if prior_origin ~= origin(target) then
                remove_header(current.headers, "authorization")
                remove_header(current.headers, "cookie")
            else
                remove_header(current.headers, "cookie")
            end
            if status == 303 or ((status == 301 or status == 302) and current.method == "POST") then
                current.method, current.body = "GET", nil
                remove_header(current.headers, "content-type")
                remove_header(current.headers, "content-length")
            end
        else
            if status == 408 then
                return outcome({ error = Errors.new(Errors.TIMEOUT, "source request timed out", { status = status, url = current.url }) })
            end
            if site_rejected(status, response.body) then
                return outcome({ error = Errors.new(Errors.SITE_REJECTED, "source rejected the request", {
                    status = status, url = current.url,
                }) })
            end
            if status and status >= 400 then
                return outcome({ error = Errors.new(Errors.NETWORK_ERROR, "source returned an HTTP error", {
                    status = status, url = current.url,
                }) })
            end
            local decoded, detected, decode_error = self.charset:decode(response.body, response.headers)
            if decode_error then return outcome({ error = decode_error }) end
            response.body = decoded
            response.charset = detected
            response.final_url = current.url
            safe_log(self.logger, "debug", {
                event = "source_response", status = response.status, final_url = response.final_url,
            })
            return outcome({ response = response })
        end
    end
end

function RequestEngine:_apply_cookie_updates(updates)
    if type(updates) ~= "table" or type(self.cookies.store) ~= "function" then return end
    for _, update in ipairs(updates) do
        if type(update) == "table" and type(update.url) == "string" then
            self.cookies:store(update.source_id, update.url, update.value)
        end
    end
end

function RequestEngine:_run_work(request)
    local ok, payload = pcall(self._perform, self, request)
    if not ok then return { panic = tostring(payload) } end
    return payload
end

function RequestEngine:_decode_child_payload(payload)
    if type(payload) == "string" then
        local decoded, decode_error = Wire.decode(payload)
        if not decoded then
            return nil, Errors.new(Errors.NETWORK_ERROR, "subprocess returned malformed data", {
                reason = "malformed_child_payload", cause = decode_error,
            })
        end
        payload = decoded
    end
    if type(payload) == "table" and payload.panic ~= nil then
        return nil, Errors.new(Errors.NETWORK_ERROR, "request worker failed safely", {
            reason = "worker_failure", cause = tostring(payload.panic),
        })
    end
    if type(payload) ~= "table" or (payload.response == nil and payload.error == nil) then
        return nil, Errors.new(Errors.NETWORK_ERROR, "subprocess returned malformed data", {
            reason = "malformed_child_payload",
        })
    end
    return payload, nil
end

function RequestEngine:_schedule(delay, action)
    self.scheduler:scheduleIn(delay, action)
    return action
end

function RequestEngine:_cleanup_child(state, after)
    if not state.child then after(); return end
    local done = self.subprocess:reap(state.child)
    if done then
        self.subprocess:close(state.child)
        state.child = nil
        after()
        return
    end
    state.scheduled = self:_schedule(RequestEngine.POLL_INTERVAL, function()
        self:_cleanup_child(state, after)
    end)
end

function RequestEngine:execute(request, callback)
    assert(type(callback) == "function", "RequestEngine callback must be a function")
    local normalized, normalize_error = self:_normalize(request)
    local state = { cancelled = false, completed = false, child = nil, scheduled = nil }
    local engine = self

    local function finish(response, err)
        if state.completed or state.cancelled then return end
        state.completed = true
        callback(response, err)
    end

    local handle = {}
    function handle:cancel()
        if state.completed or state.cancelled then return false end
        state.cancelled = true
        if state.scheduled and type(engine.scheduler.unschedule) == "function" then
            engine.scheduler:unschedule(state.scheduled)
            state.scheduled = nil
        end
        if state.child then
            engine.subprocess:terminate(state.child)
            engine:_cleanup_child(state, function() end)
        end
        return true
    end

    if normalize_error then
        state.scheduled = self:_schedule(0, function() finish(nil, normalize_error) end)
        return handle
    end

    local subprocess_available = self.subprocess and type(self.subprocess.available) == "function"
        and self.subprocess:available()
    if subprocess_available then
        local child, start_error = self.subprocess:start(function() return self:_run_work(normalized) end)
        if child then
            state.child = child
            local deadline = self.now() + normalized.timeout
            local poll
            poll = function()
                if state.cancelled or state.completed then return end
                if self.now() >= deadline then
                    self.subprocess:terminate(child)
                    self:_cleanup_child(state, function()
                        finish(nil, Errors.new(Errors.TIMEOUT, "source request timed out", { url = normalized.url }))
                    end)
                    return
                end
                local done, payload, poll_error = self.subprocess:poll(child)
                if not done then state.scheduled = self:_schedule(RequestEngine.POLL_INTERVAL, poll); return end
                if poll_error then self.subprocess:terminate(child) end
                self:_cleanup_child(state, function()
                    if poll_error then finish(nil, transport_error(poll_error, normalized.url)); return end
                    local decoded, decode_error = self:_decode_child_payload(payload)
                    if not decoded then finish(nil, decode_error); return end
                    self:_apply_cookie_updates(decoded.cookie_updates)
                    finish(decoded.response, decoded.error)
                end)
            end
            state.scheduled = self:_schedule(0, poll)
            return handle
        end
        safe_log(self.logger, "warn", { event = "subprocess_fallback", cause = tostring(start_error) })
    end

    state.scheduled = self:_schedule(0, function()
        if state.cancelled then return end
        local payload = self:_run_work(normalized)
        local decoded, decode_error = self:_decode_child_payload(payload)
        if not decoded then finish(nil, decode_error); return end
        self:_apply_cookie_updates(decoded.cookie_updates)
        finish(decoded.response, decoded.error)
    end)
    return handle
end

return RequestEngine
