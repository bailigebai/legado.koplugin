local Capabilities = require("legado.lib.rule_capabilities")

local Scanner = {}

local core_fields = {
    { field = "searchUrl", capability = Capabilities.SEARCH, missing = "MISSING_SEARCH_URL" },
    { field = "ruleSearch", capability = Capabilities.SEARCH, missing = "MISSING_SEARCH" },
    { field = "ruleBookInfo", capability = Capabilities.BOOK_INFO, missing = "MISSING_BOOK_INFO" },
    { field = "ruleToc", capability = Capabilities.CATALOG, missing = "MISSING_TOC" },
    { field = "ruleContent", capability = Capabilities.CONTENT, missing = "MISSING_CONTENT" },
}

local core_lookup = {}
for _, item in ipairs(core_fields) do core_lookup[item.field] = item.capability end

local function add_issue(issues, field, code, message)
    issues[#issues + 1] = { field = field, code = code, message = message }
end

local function dangerous_construct(value, path)
    local lower = (path .. "\n" .. value):lower()
    if lower:find("@js:", 1, true) or lower:find("<js", 1, true) then return "EXECUTABLE_JS", "JavaScript rules are never executed" end
    if lower:find("eval%s*%(") then return "DYNAMIC_EVAL", "dynamic evaluation is never executed" end
    if lower:find("loginui", 1, true) or lower:find("logincheckjs", 1, true) then return "LOGIN_UI", "login UI rules are unsupported" end
    if lower:find("android%.") then return "ANDROID_API", "Android APIs are unsupported" end
    if lower:find("java%.") or lower:find("packages", 1, true) then return "JAVA_API", "Java APIs are unsupported" end
    if lower:find("webview", 1, true) then return "WEBVIEW", "WebView rules are unsupported" end
    return nil
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    return keys
end

function Scanner.scan(source)
    source = type(source) == "table" and source or {}
    local issues, capabilities = {}, {}
    for _, capability in ipairs(Capabilities.CORE) do capabilities[capability] = true end

    for _, definition in ipairs(core_fields) do
        local value = source[definition.field]
        if type(value) ~= "string" or value:match("^%s*$") then
            capabilities[definition.capability] = false
            add_issue(issues, definition.field, definition.missing, "required " .. definition.field .. " is missing")
        end
    end

    local seen = {}
    local function inspect(value, path, root_field)
        local code, message = dangerous_construct(type(value) == "string" and value or "", path)
        if code then
            add_issue(issues, path, code, message)
            if core_lookup[root_field] then capabilities[core_lookup[root_field]] = false end
        end
        if type(value) == "table" and not seen[value] then
            seen[value] = true
            for _, key in ipairs(sorted_keys(value)) do
                local child_path = path == "" and tostring(key) or path .. "." .. tostring(key)
                inspect(value[key], child_path, root_field or tostring(key))
            end
            seen[value] = nil
        end
    end

    for _, definition in ipairs(core_fields) do inspect(source[definition.field], definition.field, definition.field) end
    for _, key in ipairs(sorted_keys(source)) do
        if not core_lookup[key] then inspect(source[key], tostring(key), tostring(key)) end
    end

    local unsupported = false
    for _, capability in ipairs(Capabilities.CORE) do
        if not capabilities[capability] then unsupported = true end
    end
    return {
        status = unsupported and "unsupported" or (#issues > 0 and "partial" or "usable"),
        capabilities = capabilities,
        issues = issues,
    }
end

return Scanner
