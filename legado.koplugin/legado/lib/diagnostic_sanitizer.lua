local Capabilities = require("legado.lib.rule_capabilities")

local Sanitizer = {}

local status_values = { usable = true, partial = true, unsupported = true }
local root_fields = {
    searchUrl = true,
    ruleSearch = true,
    ruleBookInfo = true,
    ruleToc = true,
    ruleContent = true,
}
local messages = {
    MISSING_SEARCH_URL = "Required search URL is missing",
    MISSING_SEARCH = "Required search rule is missing",
    MISSING_BOOK_INFO = "Required book information rule is missing",
    MISSING_TOC = "Required catalog rule is missing",
    MISSING_CONTENT = "Required content rule is missing",
    MALFORMED_COMMENT = "Malformed rule comments are unsupported",
    EXECUTABLE_JS = "JavaScript rules are never executed",
    DYNAMIC_EVAL = "Dynamic evaluation is never executed",
    LOGIN_UI = "Login UI rules are unsupported",
    ANDROID_API = "Android APIs are unsupported",
    JAVA_API = "Java APIs are unsupported",
    WEBVIEW = "WebView rules are unsupported",
    FUNCTION_BODY = "Function bodies are never executed",
    UNSUPPORTED_RULE = "Unsupported rule construct",
}

local function field(value, key)
    if type(value) ~= "table" then return nil end
    return rawget(value, key)
end

function Sanitizer.issueCode(value)
    if type(value) == "string" and messages[value] then return value end
    return "UNSUPPORTED_RULE"
end

function Sanitizer.issueField(value)
    if type(value) ~= "string" then return "other" end
    local root = value:match("^([A-Za-z][A-Za-z0-9_]*)")
    if not root_fields[root] then return "other" end
    if value == root then return root end
    return root .. ".rule"
end

function Sanitizer.compatibility(value)
    local status = field(value, "status")
    if not status_values[status] then status = "unsupported" end
    local input_capabilities = field(value, "capabilities")
    local capabilities = {}
    for _, capability in ipairs(Capabilities.CORE) do
        capabilities[capability] = field(input_capabilities, capability) == true
    end
    local issues, input_issues = {}, field(value, "issues")
    if type(input_issues) == "table" then
        for index = 1, 100 do
            local issue = rawget(input_issues, index)
            if issue == nil then break end
            local code = Sanitizer.issueCode(field(issue, "code"))
            issues[#issues + 1] = {
                field = Sanitizer.issueField(field(issue, "field")),
                code = code,
                message = messages[code],
            }
        end
    end
    return { status = status, capabilities = capabilities, issues = issues }
end

return Sanitizer
