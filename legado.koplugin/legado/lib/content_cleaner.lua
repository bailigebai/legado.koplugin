local Errors = require("legado.lib.errors")

local Cleaner = {}

local allowed = { p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, em = true, strong = true, b = true, i = true, a = true, img = true, br = true, blockquote = true, ul = true, ol = true, li = true, code = true, pre = true }
local void = { img = true, br = true }

local function escape_text(value)
    local entities, index = {}, 0
    value = value:gsub("&(#%d+);", function(entity)
        index = index + 1; entities[index] = "&" .. entity .. ";"; return "\1E" .. index .. "\2"
    end):gsub("&(#x[%da-fA-F]+);", function(entity)
        index = index + 1; entities[index] = "&" .. entity .. ";"; return "\1E" .. index .. "\2"
    end):gsub("&([%a][%w]+);", function(entity)
        index = index + 1; entities[index] = "&" .. entity .. ";"; return "\1E" .. index .. "\2"
    end)
    value = value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return value:gsub("\1E(%d+)\2", function(number) return entities[tonumber(number)] or "" end)
end
local function escape_attr(value) return escape_text(value):gsub('"', "&quot;") end
local function safe_url(value, image)
    value = tostring(value or ""):match("^%s*(.-)%s*$")
    if value == "" then return nil end
    local scheme = value:match("^([%a][%w+.-]*):")
    if not scheme then return value end
    scheme = scheme:lower()
    if scheme == "http" or scheme == "https" then return value end
    if image and scheme == "data" and value:match("^data:image/[%w+.-]+;base64,[A-Za-z0-9+/=]+$") then return value end
    return nil
end
local function stripped(value, regexes)
    value = value:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    value = value:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>", "")
    value = value:gsub("<[iI][fF][rR][aA][mM][eE][^>]*>.-</[iI][fF][rR][aA][mM][eE]%s*>", "")
    value = value:gsub("<[fF][oO][rR][mM][^>]*>.-</[fF][oO][rR][mM]%s*>", "")
    for _, regex in ipairs(regexes or {}) do if type(regex) == "string" and regex ~= "" then value = value:gsub(regex, "") end end
    return value
end
local function attrs(tag, source)
    if tag ~= "a" and tag ~= "img" then return "" end
    local output = {}
    local function add(name, value)
        name = name:lower()
        if tag == "a" and (name == "href" or name == "title") then
            local final = name == "href" and safe_url(value, false) or (name == "title" and value or nil)
            if final then output[#output + 1] = name .. '="' .. escape_attr(final) .. '"' end
        elseif tag == "img" and (name == "src" or name == "alt" or name == "title") then
            local final = name == "src" and safe_url(value, true) or ((name == "alt" or name == "title") and value or nil)
            if final then output[#output + 1] = name .. '="' .. escape_attr(final) .. '"' end
        end
    end
    for name, value in source:gmatch('([%w:_-]+)%s*=%s*"([^"]*)"') do add(name, value) end
    for name, value in source:gmatch("([%w:_-]+)%s*=%s*'([^']*)'") do add(name, value) end
    return #output > 0 and " " .. table.concat(output, " ") or ""
end
function Cleaner.normalize(input, options)
    if type(input) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "chapter content must be a string") end
    options = options or {}
    local regexes = options.replaceRegex or options.replace_regex or {}
    if type(regexes) == "string" then regexes = { regexes } end
    input = stripped(input, regexes)
    local out, cursor = {}, 1
    for raw, closing, tag, attributes in input:gmatch("()<(%/?)([%a%d]+)(.-)>") do
        local text = input:sub(cursor, raw - 1)
        if text ~= "" then out[#out + 1] = escape_text(text) end
        cursor = raw + #closing + #tag + #attributes + 2
        tag = tag:lower()
        if allowed[tag] then
            if closing == "/" then if not void[tag] then out[#out + 1] = "</" .. tag .. ">" end
            else
                out[#out + 1] = "<" .. tag .. attrs(tag, attributes) .. ">"
            end
        end
    end
    if cursor <= #input then out[#out + 1] = escape_text(input:sub(cursor)) end
    local value = table.concat(out):gsub("&nbsp;", " "):gsub("<p>%s*</p>", "")
    local headings = {}
    for level = 1, 6 do
        local tag = "h" .. level
        value = value:gsub("<" .. tag .. "([^>]*)>(.-)</" .. tag .. ">", function(attributes, text)
            local key = text:gsub("<[^>]->", ""):gsub("&[%w#]+;", ""):match("^%s*(.-)%s*$"):lower()
            if key ~= "" and headings[key] then return "" end
            if key ~= "" then headings[key] = true end
            return "<" .. tag .. attributes .. ">" .. text .. "</" .. tag .. ">"
        end)
    end
    if not value:find("<[%a]", 1) and value:match("%S") then value = "<p>" .. value .. "</p>" end
    if not value:match("%S") then return nil, Errors.new(Errors.PARSE_ERROR, "chapter content is empty after sanitization") end
    return value
end
return Cleaner
