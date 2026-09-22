local SocketTransport = {}
SocketTransport.__index = SocketTransport

local function loaded(name)
    local ok, module = pcall(require, name)
    if ok then return module end
    return nil
end

local function copy_headers(headers)
    local result = {}
    for name, value in pairs(headers or {}) do result[name] = value end
    return result
end

local function has_header(headers, wanted)
    wanted = wanted:lower()
    for name in pairs(headers) do
        if tostring(name):lower() == wanted then return true end
    end
    return false
end

function SocketTransport.new(options)
    options = options or {}
    return setmetatable({
        http = options.http or loaded("socket.http"),
        https = options.https or loaded("ssl.https"),
        ltn12 = options.ltn12 or loaded("ltn12"),
        -- LuaSocket's timeout is per blocking operation. Only the subprocess
        -- parent can enforce the engine's absolute, interruptible deadline.
        total_deadline_safe = false,
    }, SocketTransport)
end

function SocketTransport:request(request, sink)
    local scheme = type(request.url) == "string" and request.url:match("^([%a][%w+.-]*):")
    scheme = scheme and scheme:lower() or nil
    if scheme ~= "http" and scheme ~= "https" then return nil, "unsupported URL scheme" end
    local client = scheme == "https" and self.https or self.http
    if not client or type(client.request) ~= "function" or not self.ltn12 then
        return nil, "network transport capability is unavailable"
    end

    local headers = copy_headers(request.headers)
    local body = request.body
    if body ~= nil and type(body) ~= "string" then return nil, "request body must be a string" end
    if body and not has_header(headers, "content-length") then headers["Content-Length"] = #body end
    local parameters = {
        url = request.url,
        method = request.method or (body and "POST" or "GET"),
        headers = headers,
        redirect = false,
        sink = function(chunk, err)
            if chunk == nil then return true end
            return sink(chunk, err)
        end,
    }
    if body then
        if not self.ltn12.source or type(self.ltn12.source.string) ~= "function" then
            return nil, "LTN12 string source is unavailable"
        end
        parameters.source = self.ltn12.source.string(body)
    end

    local previous_timeout = client.TIMEOUT
    client.TIMEOUT = tonumber(request.timeout) or 20
    local called, result, code, response_headers, status_line = pcall(client.request, parameters)
    client.TIMEOUT = previous_timeout
    if not called then return nil, tostring(result) end
    if not result then return nil, tostring(code or "transport failure") end
    return {
        status = tonumber(code) or code,
        headers = response_headers or {},
        status_line = status_line,
        final_url = request.url,
    }, nil
end

return SocketTransport
