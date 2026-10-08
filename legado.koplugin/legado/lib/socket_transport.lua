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
    if request.tls_pin_sha256 or request.tls_ca_file then client=self.http end
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
    if request.tls_pin_sha256 or request.tls_ca_file then
        local pin=request.tls_pin_sha256
        if scheme~='https' or type(pin)~='string' or #pin~=64 or pin:find('[^a-f0-9]')
            or type(request.tls_ca_file)~='string' or request.tls_ca_file==''
            or not self.https or type(self.https.tcp)~='function' or not self.http then
            return nil,'pinned TLS transport unavailable'
        end
        -- ssl.https forbids a custom create callback. Reuse its TLS socket
        -- factory with socket.http, and validate the approved certificate before
        -- returning from connect (before HTTP headers or body can be sent).
        local factory=self.https.tcp{protocol='tlsv1_2',verify='peer',cafile=request.tls_ca_file,
            options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}}
        parameters.create=function()
            local connection=factory()
            local connect=connection.connect
            connection.connect=function(conn,...)
                local ok,result,err=pcall(connect,conn,...)
                local checked,digest=pcall(function()
                    local cert=conn:getpeercertificate()
                    return cert and cert:digest('sha256')
                end)
                digest=type(digest)=='string' and digest:gsub(':',''):lower() or ''
                if not ok or not result or not checked or digest~=pin then
                    if conn.sock and conn.sock.close then pcall(conn.sock.close,conn.sock) end
                    return nil,'receiver TLS certificate verification failed'
                end
                return result,err
            end
            return connection
        end
        client=self.http
    end
    if body then
        if not self.ltn12.source or type(self.ltn12.source.string) ~= "function" then
            return nil, "LTN12 string source is unavailable"
        end
        parameters.source = self.ltn12.source.string(body)
    end

    local previous_timeout = client.TIMEOUT
    local previous_tls_timeout=self.https and self.https.TIMEOUT
    if parameters.create then self.https.TIMEOUT=tonumber(request.timeout) or 20 end
    client.TIMEOUT = tonumber(request.timeout) or 20
    local called, result, code, response_headers, status_line = pcall(client.request, parameters)
    client.TIMEOUT = previous_timeout
    if parameters.create then self.https.TIMEOUT=previous_tls_timeout end
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
