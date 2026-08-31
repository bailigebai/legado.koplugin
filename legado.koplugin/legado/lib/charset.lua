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

local MIME_TOKEN = "^[%w!#$%%&'*+.^_`|~%-]+"

local function skip_whitespace(value, cursor)
    local whitespace = value:sub(cursor):match("^(%s*)") or ""
    return cursor + #whitespace
end

local function charset_parameter(value)
    value = tostring(value or "")
    local cursor = value:find(";", 1, true)
    if not cursor then return nil end
    local detected
    while cursor <= #value do
        if value:sub(cursor, cursor) ~= ";" then return nil end
        cursor = skip_whitespace(value, cursor + 1)
        if cursor > #value then return nil end
        local name = value:sub(cursor):match(MIME_TOKEN)
        if not name then return nil end
        cursor = skip_whitespace(value, cursor + #name)
        if value:sub(cursor, cursor) ~= "=" then return nil end
        cursor = skip_whitespace(value, cursor + 1)

        local parameter_value
        if value:sub(cursor, cursor) == '"' then
            local output, closed = {}, false
            cursor = cursor + 1
            while cursor <= #value do
                local character = value:sub(cursor, cursor)
                local byte = character:byte()
                if character == '"' then
                    closed, cursor = true, cursor + 1
                    break
                end
                if character == "\\" or not byte or byte < 32 or byte == 127 then return nil end
                output[#output + 1] = character
                cursor = cursor + 1
            end
            if not closed then return nil end
            parameter_value = table.concat(output)
        else
            parameter_value = value:sub(cursor):match(MIME_TOKEN)
            if not parameter_value then return nil end
            cursor = cursor + #parameter_value
        end

        cursor = skip_whitespace(value, cursor)
        if cursor <= #value and value:sub(cursor, cursor) ~= ";" then return nil end
        if name:lower() == "charset" then
            if detected ~= nil or not parameter_value:match("^[%w._%-]+$") then return nil end
            detected = parameter_value
        end
    end
    return detected
end

local function detect_http(headers)
    return charset_parameter(header_value(headers, "content-type"))
end

local function find_tag_end(text, start)
    local quote
    for index = start, #text do
        local character = text:sub(index, index)
        if quote then
            if character == quote then quote = nil end
        elseif character == '"' or character == "'" then
            quote = character
        elseif character == ">" then
            return index
        end
    end
    return nil
end

local function attributes_of(tag, cursor)
    local attributes = {}
    while cursor <= #tag do
        local whitespace = tag:sub(cursor):match("^(%s*)") or ""
        cursor = cursor + #whitespace
        local character = tag:sub(cursor, cursor)
        if character == ">" or character == "/" or character == "" then break end
        local name = tag:sub(cursor):match("^([%w:_%-]+)")
        if not name then return nil end
        cursor = cursor + #name
        whitespace = tag:sub(cursor):match("^(%s*)") or ""
        cursor = cursor + #whitespace
        local has_value = tag:sub(cursor, cursor) == "="
        if has_value then
            cursor = cursor + 1
            whitespace = tag:sub(cursor):match("^(%s*)") or ""
            cursor = cursor + #whitespace
        end
        local quote = tag:sub(cursor, cursor)
        local value
        if not has_value then
            value = ""
        elseif quote == '"' or quote == "'" then
            local close = tag:find(quote, cursor + 1, true)
            if not close then return nil end
            value, cursor = tag:sub(cursor + 1, close - 1), close + 1
        else
            local value_finish = tag:find("[%s>]", cursor) or (#tag + 1)
            value, cursor = tag:sub(cursor, value_finish - 1), value_finish
        end
        name = name:lower()
        if attributes[name] ~= nil then return nil end
        attributes[name] = value
    end
    return attributes
end

local function raw_text_end(head, lower, name, start)
    local needle, cursor = "</" .. name, start
    while true do
        local close = lower:find(needle, cursor, true)
        if not close then return #head + 1 end
        local boundary = lower:sub(close + #needle, close + #needle)
        if boundary == "" or boundary:match("[%s/>]") then
            local finish = find_tag_end(head, close + #needle)
            return finish and finish + 1 or (#head + 1)
        end
        cursor = close + #needle
    end
end

local function detect_meta(body)
    local head = body:sub(1, 8192)
    local lower, cursor = head:lower(), 1
    while cursor <= #head do
        local opening = head:find("<", cursor, true)
        if not opening then break end
        if head:sub(opening, opening + 3) == "<!--" then
            local close = head:find("-->", opening + 4, true)
            cursor = close and close + 3 or (#head + 1)
        else
            local prefix = head:sub(opening)
            local slash, name = prefix:match("^<(%/?)([%a][%w:_%-]*)")
            if not name then
                cursor = opening + 1
            else
                local finish = find_tag_end(head, opening + #name + #slash + 1)
                if not finish then break end
                name = name:lower()
                local tag = head:sub(opening, finish)
                if slash == "" and (name == "script" or name == "style") then
                    cursor = raw_text_end(head, lower, name, finish + 1)
                else
                    if slash == "" and name == "meta" then
                        local attributes = attributes_of(tag, 6)
                        if attributes then
                            if attributes.charset and attributes.charset:match("^[%w._%-]+$") then
                                return attributes.charset
                            end
                            if attributes["http-equiv"]
                                and attributes["http-equiv"]:lower() == "content-type" then
                                local declared = charset_parameter(attributes.content)
                                if declared then return declared end
                            end
                        end
                    end
                    cursor = finish + 1
                end
            end
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
