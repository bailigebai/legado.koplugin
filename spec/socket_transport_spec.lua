local assertx = require("assertions")
local SocketTransport = require("legado.lib.socket_transport")

local observed = {}
local function client(name)
    return {
        TIMEOUT = 60,
        request = function(parameters)
            observed[#observed + 1] = {
                name = name,
                timeout = name == "http" and 7 or 9,
                parameters = parameters,
            }
            local accepted, sink_error = parameters.sink("chunk")
            if accepted == nil then return nil, sink_error end
            return 1, name == "http" and 200 or 201, { ["X-Client"] = name }, "HTTP/1.1 OK"
        end,
    }
end
local http, https = client("http"), client("https")
http.request = function(parameters)
    observed[#observed + 1] = { name = "http", timeout = http.TIMEOUT, parameters = parameters }
    local accepted, sink_error = parameters.sink("chunk")
    if accepted == nil then return nil, sink_error end
    return 1, 200, { ["X-Client"] = "http" }, "HTTP/1.1 OK"
end
https.request = function(parameters)
    observed[#observed + 1] = { name = "https", timeout = https.TIMEOUT, parameters = parameters }
    local accepted, sink_error = parameters.sink("chunk")
    if accepted == nil then return nil, sink_error end
    return 1, 201, { ["X-Client"] = "https" }, "HTTP/1.1 Created"
end
local ltn12 = {
    source = {
        string = function(value)
            local sent = false
            return function()
                if sent then return nil end
                sent = true
                return value
            end
        end,
    },
}
local transport = SocketTransport.new({ http = http, https = https, ltn12 = ltn12 })

local chunks = {}
local response, response_error = transport:request({
    url = "http://books.test/search",
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = "{\"q\":\"safe\"}",
    timeout = 7,
}, function(chunk) chunks[#chunks + 1] = chunk; return true end)
assertx.equal(nil, response_error, "HTTP request succeeds")
assertx.equal(200, response.status, "HTTP status")
assertx.equal("chunk", table.concat(chunks), "response is streamed through caller sink")
assertx.equal("POST", observed[1].parameters.method, "method forwarded")
assertx.equal(12, observed[1].parameters.headers["Content-Length"], "body length header")
assertx.equal("{\"q\":\"safe\"}", observed[1].parameters.source(), "body source")
assertx.equal(7, observed[1].timeout, "request timeout applied")
assertx.equal(60, http.TIMEOUT, "HTTP module timeout restored")

local secure = transport:request({ url = "https://books.test/chapter", timeout = 9 }, function() return true end)
assertx.equal(201, secure.status, "HTTPS client selected")
assertx.equal(9, observed[2].timeout, "HTTPS timeout applied")
assertx.equal(60, https.TIMEOUT, "HTTPS module timeout restored")

local stopped, stopped_error = transport:request({ url = "https://books.test/large" }, function()
    return nil, "limit reached"
end)
assertx.equal(nil, stopped, "sink abort stops the transport")
assertx.equal("limit reached", stopped_error, "sink abort reason is preserved")

local invalid, invalid_error = transport:request({ url = "file:///etc/passwd" }, function() return true end)
assertx.equal(nil, invalid, "non-network scheme is rejected")
assertx.equal("unsupported URL scheme", invalid_error, "scheme rejection is diagnostic")

return 15
