-- A deliberately small JSON decoder used only when KOReader's `json` module
-- is unavailable. It parses data literals directly and never calls load.
local Json = {}
local array_values = setmetatable({}, { __mode = "k" })
local NULL = {}

local function utf8_character(codepoint)
    if codepoint <= 0x7f then return string.char(codepoint) end
    if codepoint <= 0x7ff then
        return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
    end
    if codepoint <= 0xffff then
        return string.char(0xe0 + math.floor(codepoint / 0x1000), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
    end
    return string.char(0xf0 + math.floor(codepoint / 0x40000), 0x80 + (math.floor(codepoint / 0x1000) % 0x40), 0x80 + (math.floor(codepoint / 0x40) % 0x40), 0x80 + (codepoint % 0x40))
end

function Json.decode(input)
    if type(input) ~= "string" then error("JSON input must be a string") end
    local index, length = 1, #input
    local parse_value

    local function whitespace()
        while index <= length and input:sub(index, index):match("[ \t\r\n]") do index = index + 1 end
    end

    local function unicode_escape()
        local digits = input:sub(index, index + 3)
        if not digits:match("^%x%x%x%x$") then error("invalid unicode escape") end
        index = index + 4
        local codepoint = tonumber(digits, 16)
        if codepoint >= 0xd800 and codepoint <= 0xdbff and input:sub(index, index + 1) == "\\u" then
            index = index + 2
            local low_digits = input:sub(index, index + 3)
            if not low_digits:match("^%x%x%x%x$") then error("invalid unicode escape") end
            index = index + 4
            local low = tonumber(low_digits, 16)
            if low >= 0xdc00 and low <= 0xdfff then codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
            else error("invalid unicode surrogate pair") end
        elseif codepoint >= 0xd800 and codepoint <= 0xdfff then
            error("invalid unicode surrogate")
        end
        return utf8_character(codepoint)
    end

    local function parse_string()
        if input:sub(index, index) ~= '"' then error("expected JSON string") end
        index = index + 1
        local output = {}
        while index <= length do
            local character = input:sub(index, index)
            index = index + 1
            if character == '"' then return table.concat(output) end
            if character == "\\" then
                local escaped = input:sub(index, index)
                index = index + 1
                local replacements = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if escaped == "u" then output[#output + 1] = unicode_escape()
                elseif replacements[escaped] then output[#output + 1] = replacements[escaped]
                else error("invalid JSON string escape") end
            elseif character:byte() < 0x20 then
                error("unescaped control character")
            else
                output[#output + 1] = character
            end
        end
        error("unterminated JSON string")
    end

    local function parse_array()
        index = index + 1
        local result = {}
        array_values[result] = true
        whitespace()
        if input:sub(index, index) == "]" then index = index + 1 return result end
        local position = 1
        while true do
            local value = parse_value()
            result[position] = value
            position = position + 1
            whitespace()
            local separator = input:sub(index, index)
            if separator == "]" then index = index + 1 return result end
            if separator ~= "," then error("expected JSON array separator") end
            index = index + 1
        end
    end

    local function parse_object()
        index = index + 1
        local result = {}
        whitespace()
        if input:sub(index, index) == "}" then index = index + 1 return result end
        while true do
            whitespace()
            local key = parse_string()
            whitespace()
            if input:sub(index, index) ~= ":" then error("expected JSON object colon") end
            index = index + 1
            result[key] = parse_value()
            whitespace()
            local separator = input:sub(index, index)
            if separator == "}" then index = index + 1 return result end
            if separator ~= "," then error("expected JSON object separator") end
            index = index + 1
        end
    end

    parse_value = function()
        whitespace()
        local character = input:sub(index, index)
        if character == '"' then return parse_string() end
        if character == "{" then return parse_object() end
        if character == "[" then return parse_array() end
        if input:sub(index, index + 3) == "true" then index = index + 4 return true end
        if input:sub(index, index + 4) == "false" then index = index + 5 return false end
        if input:sub(index, index + 3) == "null" then index = index + 4 return NULL end
        local number = input:sub(index):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if number and number ~= "-" then index = index + #number return tonumber(number) end
        error("invalid JSON value")
    end

    local value = parse_value()
    whitespace()
    if index <= length then error("trailing JSON data") end
    return value
end

function Json.isArray(value)
    return array_values[value] == true
end

function Json.isNull(value)
    return value == NULL
end

return Json
