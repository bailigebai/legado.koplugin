local Capabilities = {
    SEARCH = "search",
    BOOK_INFO = "book_info",
    CATALOG = "catalog",
    CONTENT = "content",
}

Capabilities.LIMITS = {
    MAX_RECURSION = 16,
    MAX_TEMPLATE_DEPTH = 8,
    MAX_DOM_DEPTH = 64,
    MAX_OUTPUT_ITEMS = 1000,
    MAX_HTML_NODES = 10000,
}

Capabilities.SAFE_FUNCTIONS = {
    urlencode = true,
    urldecode = true,
    htmldecode = true,
    base64encode = true,
    base64decode = true,
    md5 = true,
    sha = true,
    sha1 = true,
    sha256 = true,
    trim = true,
    lower = true,
    upper = true,
    replace = true,
    resolveurl = true,
}

local unsafe_constructs = {
    { pattern = "@%s*j%s*s%s*:", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { pattern = "<%s*j%s*s%f[^%w_]", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { pattern = "<%s*/%s*j%s*s%s*>", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { pattern = "%f[%w_]e%s*v%s*a%s*l%s*%(", code = "DYNAMIC_EVAL", message = "dynamic evaluation is never executed" },
    { pattern = "%f[%w_]l%s*o%s*g%s*i%s*n%s*u%s*i%f[^%w_]", code = "LOGIN_UI", message = "login UI rules are unsupported" },
    { pattern = "%f[%w_]l%s*o%s*g%s*i%s*n%s*c%s*h%s*e%s*c%s*k%s*j%s*s%f[^%w_]", code = "LOGIN_UI", message = "login UI rules are unsupported" },
    { pattern = "%f[%w_]a%s*n%s*d%s*r%s*o%s*i%s*d%s*%.", code = "ANDROID_API", message = "Android APIs are unsupported" },
    { pattern = "%f[%w_]j%s*a%s*v%s*a%s*%.", code = "JAVA_API", message = "Java APIs are unsupported" },
    { pattern = "%f[%w_]p%s*a%s*c%s*k%s*a%s*g%s*e%s*s%f[^%w_]", code = "JAVA_API", message = "Java APIs are unsupported" },
    { pattern = "%f[%w_]w%s*e%s*b%s*v%s*i%s*e%s*w%f[^%w_]", code = "WEBVIEW", message = "WebView rules are unsupported" },
    { pattern = "%f[%w_]function%f[^%w_]", code = "FUNCTION_BODY", message = "function bodies are never executed" },
    { pattern = "=%s*>", code = "FUNCTION_BODY", message = "function bodies are never executed" },
}

Capabilities.UNSAFE_CONSTRUCTS = unsafe_constructs

local function decode_identifier_escapes(value)
    value = value:gsub("\\u{(%x+)}", function(hex)
        local codepoint = tonumber(hex, 16)
        if codepoint and codepoint <= 0x7f then return string.char(codepoint) end
        return "\\u{" .. hex .. "}"
    end)
    return (value:gsub("\\u(%x%x%x%x)", function(hex)
        local codepoint = tonumber(hex, 16)
        if codepoint and codepoint <= 0x7f then return string.char(codepoint) end
        return "\\u" .. hex
    end))
end

local function normalize_tokens(value)
    local output, index, quote = {}, 1, nil
    while index <= #value do
        local pair = value:sub(index, index + 1)
        local character = value:sub(index, index)
        if quote then
            if character == "\\" then index = index + 2
            elseif character == quote then quote = nil; index = index + 1
            else index = index + 1 end
        elseif character == "'" or character == '"' then
            output[#output + 1] = " "
            quote = character
            index = index + 1
        elseif pair == "/*" then
            output[#output + 1] = " "
            local depth = 1
            index = index + 2
            while index <= #value and depth > 0 do
                pair = value:sub(index, index + 1)
                if pair == "/*" then depth = depth + 1; index = index + 2
                elseif pair == "*/" then depth = depth - 1; index = index + 2
                else index = index + 1 end
            end
        elseif pair == "--" or pair == "//" then
            output[#output + 1] = " "
            index = index + 2
            while index <= #value and not value:sub(index, index):match("[\r\n]") do index = index + 1 end
        elseif character:match("%s") then output[#output + 1] = " "; index = index + 1
        else output[#output + 1] = character:lower(); index = index + 1 end
    end
    return (table.concat(output):gsub("%s+", " "))
end

function Capabilities.findUnsupported(value)
    local decoded = decode_identifier_escapes(type(value) == "string" and value or "")
    local normalized = normalize_tokens(decoded)
    local candidates = { normalized }
    for _, definition in ipairs(unsafe_constructs) do
        for _, candidate in ipairs(candidates) do
            local matched = definition.literal and candidate:find(definition.literal, 1, true)
                or definition.pattern and candidate:find(definition.pattern)
            if matched then return definition.code, definition.message end
        end
    end
    return nil
end

Capabilities.CORE = {
    Capabilities.SEARCH,
    Capabilities.BOOK_INFO,
    Capabilities.CATALOG,
    Capabilities.CONTENT,
}

return Capabilities
