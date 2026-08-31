local Errors = require("legado.lib.errors")
local Json = require("legado.lib.json_codec")
local SafeFunctions = require("legado.lib.safe_functions")

local UrlTemplate = {}
UrlTemplate.__index = UrlTemplate
UrlTemplate.MAX_PAGES = 20

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

function UrlTemplate.new(options)
    options = options or {}
    assert(options.rule_engine, "UrlTemplate requires rule_engine")
    return setmetatable({
        rule_engine = options.rule_engine,
        json = options.json or Json,
        resolver = options.resolver or SafeFunctions.resolve_url,
    }, UrlTemplate)
end

function UrlTemplate:_expand(value, context)
    if type(value) ~= "string" or not value:find("{{", 1, true) then return value, nil end
    return self.rule_engine:parse("", value, context or {}, false)
end

function UrlTemplate:resolve(base, relative)
    return self.resolver(base, relative)
end

local function merge_headers(defaults, overrides)
    local result = {}
    for name, value in pairs(defaults or {}) do result[name] = copy(value) end
    for name, value in pairs(overrides or {}) do
        local lowered = tostring(name):lower()
        for existing in pairs(result) do if tostring(existing):lower() == lowered then result[existing] = nil end end
        result[name] = copy(value)
    end
    return result
end

function UrlTemplate:build(specification, context, default_headers)
    local request
    if type(specification) == "table" then
        request = copy(specification)
    elseif type(specification) == "string" then
        local url, options_text = specification:match("^(.-),(%s*{.*}%s*)$")
        if options_text then
            local ok, options = pcall(self.json.decode, options_text)
            if not ok or type(options) ~= "table" then
                return nil, Errors.new(Errors.PARSE_ERROR, "invalid request template options")
            end
            request = copy(options)
            request.url = url
        else
            request = { url = specification }
        end
    else
        return nil, Errors.new(Errors.INVALID_INPUT, "request template must be a string or table")
    end

    request.method = tostring(request.method or (request.body ~= nil and "POST" or "GET")):upper()
    request.headers = merge_headers(default_headers, type(request.headers) == "table" and request.headers or {})
    for _, field in ipairs({ "url", "body" }) do
        local expanded, expand_error = self:_expand(request[field], context)
        if expand_error then return nil, expand_error end
        request[field] = expanded
    end
    for name, value in pairs(request.headers) do
        local expanded, expand_error = self:_expand(value, context)
        if expand_error then return nil, expand_error end
        request.headers[name] = expanded
    end
    return request, nil
end

function UrlTemplate:page(specification, key, page, base_url)
    local request, err = self:build(specification, {
        key = key,
        page = page,
        baseUrl = base_url,
    })
    if not request then return nil, err end
    if base_url then request.url = self:resolve(base_url, request.url) end
    return request, nil
end

function UrlTemplate:paginate(specification, key, first_page, count, base_url)
    first_page = tonumber(first_page) or 1
    count = tonumber(count) or 1
    if count < 0 or count > UrlTemplate.MAX_PAGES or count % 1 ~= 0 then
        return nil, Errors.new(Errors.INVALID_INPUT, "pagination count is outside the safe range", {
            maximum = UrlTemplate.MAX_PAGES,
        })
    end
    local requests = {}
    for offset = 0, count - 1 do
        local request, err = self:page(specification, key, first_page + offset, base_url)
        if not request then return nil, err end
        requests[#requests + 1] = request
    end
    return requests, nil
end

return UrlTemplate
