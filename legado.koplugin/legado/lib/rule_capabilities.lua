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
    { literal = "@js:", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { literal = "<js", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { literal = "</js>", code = "EXECUTABLE_JS", message = "JavaScript rules are never executed" },
    { pattern = "eval%s*%(", code = "DYNAMIC_EVAL", message = "dynamic evaluation is never executed" },
    { literal = "loginui", code = "LOGIN_UI", message = "login UI rules are unsupported" },
    { literal = "logincheckjs", code = "LOGIN_UI", message = "login UI rules are unsupported" },
    { pattern = "android%.", code = "ANDROID_API", message = "Android APIs are unsupported" },
    { pattern = "java%.", code = "JAVA_API", message = "Java APIs are unsupported" },
    { literal = "packages", code = "JAVA_API", message = "Java APIs are unsupported" },
    { literal = "webview", code = "WEBVIEW", message = "WebView rules are unsupported" },
    { pattern = "%f[%a]function[%w_%.:]*%(", code = "FUNCTION_BODY", message = "function bodies are never executed" },
    { literal = "=>", code = "FUNCTION_BODY", message = "function bodies are never executed" },
}

Capabilities.UNSAFE_CONSTRUCTS = unsafe_constructs

local function decode_identifier_escapes(value)
    return (value:gsub("\\u(%x%x%x%x)", function(hex)
        local codepoint = tonumber(hex, 16)
        if codepoint and codepoint <= 0x7f then return string.char(codepoint) end
        return "\\u" .. hex
    end))
end

local function remove_comments_and_spacing(value)
    local output, index = {}, 1
    while index <= #value do
        local pair = value:sub(index, index + 1)
        local character = value:sub(index, index)
        if pair == "/*" then
            local depth = 1
            index = index + 2
            while index <= #value and depth > 0 do
                pair = value:sub(index, index + 1)
                if pair == "/*" then depth = depth + 1; index = index + 2
                elseif pair == "*/" then depth = depth - 1; index = index + 2
                else index = index + 1 end
            end
        elseif pair == "--" or pair == "//" then
            index = index + 2
            while index <= #value and not value:sub(index, index):match("[\r\n]") do index = index + 1 end
        elseif character:match("%s") then index = index + 1
        else output[#output + 1] = character:lower(); index = index + 1 end
    end
    return table.concat(output)
end

local function compact_spacing(value)
    return (value:lower():gsub("%s+", ""))
end

function Capabilities.findUnsupported(value)
    local decoded = decode_identifier_escapes(type(value) == "string" and value or "")
    local candidates = { compact_spacing(decoded), remove_comments_and_spacing(decoded) }
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
