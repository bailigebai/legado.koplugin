local Errors = require("legado.lib.errors")
local XmlText = require("legado.lib.xml_text")

local Serializer = {}

local allowed = { p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    em = true, strong = true, b = true, i = true, a = true, img = true, br = true,
    blockquote = true, ul = true, ol = true, li = true, code = true, pre = true }
local void = { img = true, br = true }
local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", copy = "©" }

local function utf8(codepoint)
    if not codepoint or codepoint < 0 or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF) then
        return "�"
    end
    if codepoint < 0x80 then return string.char(codepoint) end
    if codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    end
    if codepoint < 0x10000 then
        return string.char(0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xF0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

local function decode_entities(value)
    return tostring(value or ""):gsub("&([^;%s<>]+);", function(entity)
        local hex = entity:match("^#[xX]([%da-fA-F]+)$")
        if hex then return utf8(tonumber(hex, 16)) end
        local decimal = entity:match("^#(%d+)$")
        if decimal then return utf8(tonumber(decimal, 10)) end
        return named[entity] or "&" .. entity .. ";"
    end)
end

local function escape(value)
    return XmlText.escape(decode_entities(value))
end

local function safe_url(value)
    value = decode_entities(value):gsub("[%c%s]", "")
    if value == "" then return nil end
    local scheme = value:match("^([%a][%w+.-]*):")
    if not scheme or scheme:lower() == "http" or scheme:lower() == "https" then return value end
end

local function attributes(tag, source)
    local found = {}
    local function accept(name, value)
        name = name:lower()
        if tag == "a" and (name == "href" or name == "title") then
            found[name] = name == "href" and safe_url(value) or decode_entities(value)
        elseif tag == "img" and (name == "src" or name == "alt" or name == "title") then
            found[name] = name == "src" and safe_url(value) or decode_entities(value)
        end
    end
    for name, value in source:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do accept(name, value) end
    for name, value in source:gmatch("([%w:_-]+)%s*=%s*'([^']*)'") do accept(name, value) end
    local order = tag == "a" and { "href", "title" } or { "src", "alt", "title" }
    local output = {}
    for _, name in ipairs(order) do if found[name] then output[#output + 1] = " " .. name .. '="' .. escape(found[name]) .. '"' end end
    return table.concat(output)
end

local function append_text(parent, value)
    if value ~= "" then parent.children[#parent.children + 1] = { text = value } end
end

local function serialize(node, output)
    if node.text ~= nil then output[#output + 1] = escape(node.text); return end
    if node.tag then
        output[#output + 1] = "<" .. node.tag .. (node.attributes or "") .. (void[node.tag] and "/>" or ">")
    end
    if not void[node.tag] then
        for _, child in ipairs(node.children or {}) do serialize(child, output) end
        if node.tag then output[#output + 1] = "</" .. node.tag .. ">" end
    end
end

function Serializer.fragment(input)
    if type(input) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "XHTML fragment must be a string") end
    local root = { children = {} }
    local stack, cursor = { root }, 1
    for start_at, slash, raw_name, raw_attributes, end_at in input:gmatch("()<(%/?)([%a%d]+)(.-)>()") do
        append_text(stack[#stack], input:sub(cursor, start_at - 1))
        cursor = end_at
        local name = raw_name:lower()
        if allowed[name] then
            if slash == "/" then
                local match
                for index = #stack, 2, -1 do if stack[index].tag == name then match = index; break end end
                if match then while #stack >= match do table.remove(stack) end end
            else
                local node = { tag = name, attributes = attributes(name, raw_attributes), children = {} }
                stack[#stack].children[#stack[#stack].children + 1] = node
                if not void[name] then stack[#stack + 1] = node end
            end
        end
    end
    append_text(stack[#stack], input:sub(cursor))
    local output = {}; for _, child in ipairs(root.children) do serialize(child, output) end
    local value = table.concat(output)
    if value == "" then return nil, Errors.new(Errors.PARSE_ERROR, "XHTML fragment is empty") end
    return value
end

return Serializer
