local Errors = require("legado.lib.errors")
local IconvAdapter = require("legado.lib.iconv_adapter")

local Charset = {}
Charset.__index = Charset

local function normalize(value)
    value = tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^['\"]", ""):gsub("['\"]$", "")
    if value == "utf8" then return "utf-8" end
    if value == "gb_2312" or value == "gb-2312" then return "gb2312" end
    if value == "gb-18030" then return "gb18030" end
    return value
end

local function header_value(headers, wanted)
    wanted = wanted:lower()
    for name, value in pairs(headers or {}) do
        if tostring(name):lower() == wanted then return value end
    end
    return nil
end

local function bom(body)
    if body:sub(1, 3) == "\239\187\191" then return "utf-8", 4 end
    if body:sub(1, 4) == "\255\254\0\0" then return "utf-32le", 5 end
    if body:sub(1, 4) == "\0\0\254\255" then return "utf-32be", 5 end
    if body:sub(1, 2) == "\255\254" then return "utf-16le", 3 end
    if body:sub(1, 2) == "\254\255" then return "utf-16be", 3 end
    return nil, 1
end

local function detect_http(headers)
    local content_type = tostring(header_value(headers, "content-type") or "")
    return content_type:match("[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*['\"]?([%w._%-]+)")
end

local function detect_meta(body)
    local head = body:sub(1, 8192)
    for tag in head:gmatch("<[Mm][Ee][Tt][Aa][^>]*>") do
        local attributes, cursor = {}, 6
        while cursor <= #tag do
            local _, finish, name = tag:find("%s*([%w:_%-]+)%s*=%s*", cursor)
            if not finish then break end
            cursor = finish + 1
            local quote = tag:sub(cursor, cursor)
            local value
            if quote == '"' or quote == "'" then
                local close = tag:find(quote, cursor + 1, true)
                if not close then break end
                value, cursor = tag:sub(cursor + 1, close - 1), close + 1
            else
                local value_finish = tag:find("[%s>]", cursor) or (#tag + 1)
                value, cursor = tag:sub(cursor, value_finish - 1), value_finish
            end
            attributes[name:lower()] = value
        end
        if attributes.charset and attributes.charset:match("^[%w._%-]+$") then return attributes.charset end
        if attributes["http-equiv"] and attributes["http-equiv"]:lower() == "content-type" then
            local declared = attributes.content and attributes.content:match(
                "[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*([%w._%-]+)")
            if declared then return declared end
        end
    end
    return nil
end

local function iconv_converter()
    for _, module_name in ipairs({ "iconv", "ffi/iconv" }) do
        local loaded, iconv = pcall(require, module_name)
        if loaded and type(iconv) == "table" and (type(iconv.new) == "function" or type(iconv.open) == "function") then
            return {
                convert = function(_, input, from, to)
                    local open = iconv.new or iconv.open
                    local descriptor, open_error = open(to, from)
                    if not descriptor then return nil, open_error end
                    local method = descriptor.iconv or descriptor.convert
                    if type(method) ~= "function" then return nil, "iconv descriptor has no conversion method" end
                    local output, convert_error = method(descriptor, input)
                    if output == nil or convert_error ~= nil then return nil, convert_error end
                    return output
                end,
            }
        end
    end
    return nil
end

function Charset.new(options)
    options = options or {}
    local converter = options.converter
    if converter == nil then
        local native = IconvAdapter.new()
        converter = native:available() and native or iconv_converter()
    end
    if converter == false then converter = nil end
    return setmetatable({ converter = converter }, Charset)
end

function Charset:detect(body, headers)
    body = type(body) == "string" and body or ""
    local detected, offset = bom(body)
    if detected then return detected, offset end
    return normalize(detect_http(headers) or detect_meta(body) or "utf-8"), 1
end

function Charset:decode(body, headers)
    if type(body) ~= "string" then
        return nil, nil, Errors.new(Errors.ENCODING_ERROR, "response body must be a string")
    end
    local detected, offset = self:detect(body, headers)
    body = body:sub(offset)
    if detected == "utf-8" or detected == "us-ascii" or detected == "ascii" then
        return body, detected == "ascii" and "us-ascii" or detected, nil
    end
    if not self.converter then
        return nil, detected, Errors.new(Errors.ENCODING_ERROR, "character conversion capability is unavailable", {
            charset = detected,
        })
    end
    local ok, converted, cause
    if type(self.converter) == "function" then
        ok, converted, cause = pcall(self.converter, body, detected, "utf-8")
    elseif type(self.converter.convert) == "function" then
        ok, converted, cause = pcall(self.converter.convert, self.converter, body, detected, "utf-8")
    else
        ok, converted, cause = false, nil, "invalid charset converter"
    end
    if not ok or converted == nil then
        return nil, detected, Errors.new(Errors.ENCODING_ERROR, "response character conversion failed", {
            charset = detected,
            cause = tostring(ok and cause or converted),
        })
    end
    return converted, detected, nil
end

return Charset
