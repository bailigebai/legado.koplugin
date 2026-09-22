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
local function decode_attr(value)
    value = tostring(value or "")
    local names = { Tab = "\t", NewLine = "\n", colon = ":" }
    value = value:gsub("&#x([%da-fA-F]+);", function(number) local n = tonumber(number, 16); return n and n <= 0x7F and string.char(n) or "" end)
    value = value:gsub("&#(%d+);", function(number) local n = tonumber(number); return n and n <= 0x7F and string.char(n) or "" end)
    value = value:gsub("&([%a]+);", function(name) return names[name] or "" end)
    return value:gsub("[%c%s]", "")
end
local function safe_url(value, image)
    value = decode_attr(value)
    if value == "" then return nil end
    local scheme = value:match("^([%a][%w+.-]*):")
    if not scheme then return value end
    scheme = scheme:lower()
    if scheme == "http" or scheme == "https" then return value end
    return nil
end
local function validate_regexes(value)
    if type(value) == "string" then value = { value }
    elseif type(value) ~= "table" then return nil, Errors.new(Errors.INVALID_INPUT, "replaceRegex must be a string or dense array") end
    local count, maximum = 0, 0
    for key, regex in pairs(value) do
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
            return nil, Errors.new(Errors.INVALID_INPUT, "replaceRegex must be a dense array")
        end
        count, maximum = count + 1, math.max(maximum, key)
        if type(regex) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "replaceRegex entries must be strings") end
    end
    if count ~= maximum or count > 16 then return nil, Errors.new(Errors.INVALID_INPUT, count > 16 and "too many replaceRegex rules" or "replaceRegex must be a dense array") end
    for index = 1, count do
        local regex = value[index]
        if #regex > 512 then return nil, Errors.new(Errors.INVALID_INPUT, "replaceRegex rule exceeds length limit", { index = index }) end
        if regex:find("@js:", 1, true) or regex:lower():find("<js", 1, true)
            or regex:find("%%b") or regex:find("%%f") or regex:find("%%[1-9]")
            or regex:find("[()]" ) then
            return nil, Errors.new(Errors.UNSUPPORTED_RULE, "unsafe replaceRegex", { index = index })
        end
        local ok = pcall(string.find, "", regex)
        if not ok then return nil, Errors.new(Errors.PARSE_ERROR, "invalid replaceRegex", { index = index }) end
    end
    return value
end
local function stripped(value, regexes)
    value = value:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    value = value:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>", "")
    value = value:gsub("<[iI][fF][rR][aA][mM][eE][^>]*>.-</[iI][fF][rR][aA][mM][eE]%s*>", "")
    value = value:gsub("<[fF][oO][rR][mM][^>]*>.-</[fF][oO][rR][mM]%s*>", "")
    for _, regex in ipairs(regexes) do
        local ok, result = pcall(string.gsub, value, regex, "")
        if not ok then return nil, Errors.new(Errors.PARSE_ERROR, "invalid replaceRegex") end
        value = result
    end
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
    local regexes
    if options.replaceRegex ~= nil then regexes = options.replaceRegex
    elseif options.replace_regex ~= nil then regexes = options.replace_regex
    else regexes = {} end
    local regex_error
    regexes, regex_error = validate_regexes(regexes)
    if not regexes then return nil, regex_error end
    local stripped_value, stripped_error = stripped(input, regexes)
    if not stripped_value then return nil, stripped_error end
    input = stripped_value
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
    local value = table.concat(out):gsub("&nbsp;", " ")
    value = value:gsub('<p>(.-)</p>', function(content)
        if content:find('<img',1,true) then return '<p>'..content..'</p>' end
        local text = content:gsub('<[^>]*>',''):gsub('&#160;',''):gsub('&#[xX]0*[aA]0;','')
            :gsub('　',''):gsub('\194\160',''):gsub('\226\128\139','')
        if not text:match('%S') then return '' end
        return '<p>'..content..'</p>'
    end)
    local reversed, tail = value:reverse(), 1
    while true do
        local _,last = reversed:find('^%s*>rb<',tail)
        if not last then break end
        tail=last+1
    end
    value=value:sub(1,#value-tail+1)
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
