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
    { pattern = "%f[%a]function%s*[%w_%.:]*%s*%(", code = "FUNCTION_BODY", message = "function bodies are never executed" },
    { literal = "=>", code = "FUNCTION_BODY", message = "function bodies are never executed" },
}

Capabilities.UNSAFE_CONSTRUCTS = unsafe_constructs

function Capabilities.findUnsupported(value)
    local lower = type(value) == "string" and value:lower() or ""
    for _, definition in ipairs(unsafe_constructs) do
        local matched = definition.literal and lower:find(definition.literal, 1, true)
            or definition.pattern and lower:find(definition.pattern)
        if matched then return definition.code, definition.message end
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
