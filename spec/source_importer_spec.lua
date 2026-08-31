local assertx = require("assertions")

-- These tests catch regressions where source ingestion either decodes arbitrary
-- code, commits a partially valid batch, or silently classifies unsafe rules.
local SourceImporter = require("legado.lib.source_importer")
local Scanner = require("legado.lib.compatibility_scanner")
local Capabilities = require("legado.lib.rule_capabilities")

local function new_storage(initial)
    local state = {}
    for id, source in pairs(initial or {}) do state[id] = source end
    local storage = { replace_calls = 0 }

    function storage:getSource(id)
        return state[id]
    end

    function storage:listSources()
        local values = {}
        for _, source in pairs(state) do values[#values + 1] = source end
        return values
    end

    function storage:replaceSources(sources)
        local replacement = {}
        for _, source in ipairs(sources) do replacement[source.id] = source end
        state = replacement
        self.replace_calls = self.replace_calls + 1
        return true
    end

    return storage
end

local usable_json = [[{
  "bookSourceName":"Synthetic source",
  "bookSourceUrl":"https://example.test/catalog",
  "bookSourceGroup":"  Demo  ",
  "enabled":false,
  "header":"Accept: text/html",
  "searchUrl":"https://example.test/search?key={{key}}",
  "ruleSearch":".result",
  "ruleBookInfo":".info",
  "ruleToc":".chapter",
  "ruleContent":"#content",
  "customField":{"kept":true}
}]]

local storage = new_storage()
local importer = SourceImporter:new({ storage = storage, now = function() return 1234567890 end })
local report = assert(importer:importJson(usable_json, "https://imports.example.test/source.json"))
assertx.equal(1, report.imported, "single object imports one source")
assertx.equal(0, report.updated, "first import is not an update")
assertx.equal(0, report.rejected, "valid source is not rejected")
assertx.equal(1, #report.compatibility, "report includes one compatibility result")
assertx.equal("usable", report.compatibility[1].status, "ordinary selector rules are usable")
assertx.equal(true, report.compatibility[1].capabilities[Capabilities.SEARCH], "search capability is reported")
local stored = assert(storage:getSource("https://example.test/catalog"))
assertx.equal("Demo", stored.bookSourceGroup, "known text fields are normalized")
assertx.equal(false, stored.enabled, "imported enabled setting is retained initially")
assertx.equal(true, stored.customField.kept, "unknown source fields survive normalization")
assertx.equal("https://imports.example.test/source.json", stored.import_origin, "remote origin metadata is retained")
assertx.equal(1234567890, stored.imported_at, "import timestamp is stored")
assertx.equal(nil, stored.insecure_origin_warning, "HTTPS origins do not receive an insecure warning")

local injected_decode_calls = 0
local injected_importer = SourceImporter:new({
    storage = new_storage(),
    json = { decode = function(text)
        injected_decode_calls = injected_decode_calls + 1
        assertx.equal("synthetic injected payload", text, "injected decoder receives raw source JSON")
        return {
            bookSourceName = "Injected source", bookSourceUrl = "https://example.test/injected",
            searchUrl = "https://example.test/search?key={{key}}", ruleSearch = ".result",
            ruleBookInfo = ".info", ruleToc = ".chapter", ruleContent = "#content",
        }
    end },
})
assertx.equal(1, assert(injected_importer:importJson("synthetic injected payload", "C:/sources/injected.json")).imported, "injected KOReader-compatible decoder is supported")
assertx.equal(1, injected_decode_calls, "injected decoder is used exactly once")

local update_json = [[{
  "bookSourceName":"Updated synthetic source",
  "bookSourceUrl":"https://example.test/catalog",
  "searchUrl":"https://example.test/updated?key={{key}}",
  "ruleSearch":".updated",
  "ruleBookInfo":".info",
  "ruleToc":".chapter",
  "ruleContent":"#content"
}]]
local update_report = assert(importer:importJson(update_json, "C:/sources/updated.json"))
assertx.equal(0, update_report.imported, "same URL does not create a duplicate")
assertx.equal(1, update_report.updated, "same URL updates existing source")
stored = assert(storage:getSource("https://example.test/catalog"))
assertx.equal(false, stored.enabled, "updates preserve the user's enabled state")
assertx.equal(".updated", stored.ruleSearch, "updates replace imported rule payload")
assertx.equal("C:/sources/updated.json", stored.import_origin, "local update origin is retained")
assertx.equal(nil, stored.insecure_origin_warning, "local origins have no insecure warning")

local second_json = usable_json:gsub("https://example.test/catalog", "https://example.test/catalog-2")
local array_report = assert(importer:importJson("[" .. usable_json .. "," .. second_json .. "]", "http://imports.example.test/list.json"))
assertx.equal(1, array_report.imported, "array import adds new source once")
assertx.equal(1, array_report.updated, "array import updates repeated URL once")
assertx.equal(2, #array_report.compatibility, "array report retains input order")
assertx.equal(1, #array_report.warnings, "HTTP import produces one stable warning")
assertx.equal("INSECURE_ORIGIN", array_report.warnings[1].code, "HTTP warning code is stable")

local stable_before_invalid = storage:getSource("https://example.test/catalog")
local invalid_report = assert(importer:importJson("[" .. usable_json .. ",42]", "C:/sources/bad.json"))
assertx.equal(1, invalid_report.rejected, "non-object array member is rejected")
assertx.equal(0, invalid_report.imported, "invalid batch does not commit valid members")
assertx.equal(".result", assert(storage:getSource("https://example.test/catalog")).ruleSearch, "invalid batch preserves previous state")
assertx.equal(stable_before_invalid, storage:getSource("https://example.test/catalog"), "atomic rejection does not replace source object")

local malformed_report = assert(importer:importJson("{ definitely not json", "C:/sources/malformed.json"))
assertx.equal(1, malformed_report.rejected, "malformed JSON is rejected")
assertx.equal("PARSE_ERROR", malformed_report.error.code, "malformed JSON produces a structured parse error")

local bounded_text = usable_json
local bounded = SourceImporter:new({ storage = new_storage(), max_bytes = #bounded_text })
assertx.equal(1, assert(bounded:importJson(bounded_text, "C:/sources/bounded.json")).imported, "byte limit accepts exactly the configured boundary")
local over_limit = SourceImporter:new({ storage = new_storage(), max_bytes = #bounded_text - 1 })
local over_report = assert(over_limit:importJson(bounded_text, "C:/sources/bounded.json"))
assertx.equal(1, over_report.rejected, "byte limit rejects input before decode")
assertx.equal("RESPONSE_TOO_LARGE", over_report.error.code, "oversize import has stable error code")
assertx.equal(5 * 1024 * 1024, SourceImporter.DEFAULT_MAX_BYTES, "default limit is exactly five MiB")

local five_mebibyte_text = usable_json .. string.rep(" ", SourceImporter.DEFAULT_MAX_BYTES - #usable_json)
local default_limit = SourceImporter:new({ storage = new_storage() })
assertx.equal(1, assert(default_limit:importJson(five_mebibyte_text, "C:/sources/exact.json")).imported, "default limit accepts exactly five MiB")
local above_default = SourceImporter:new({ storage = new_storage() })
assertx.equal(1, assert(above_default:importJson(five_mebibyte_text .. " ", "C:/sources/over.json")).rejected, "default limit rejects more than five MiB")

local https_url = SourceImporter.validateRemoteUrl("https://imports.example.test/sources.json")
assertx.equal(true, https_url.valid, "HTTPS remote URL is accepted without transport")
assertx.equal(nil, https_url.warning, "HTTPS remote URL has no warning")
local uppercase_https_url = SourceImporter.validateRemoteUrl("HTTPS://imports.example.test/sources.json")
assertx.equal(true, uppercase_https_url.valid, "remote URL validation treats HTTPS schemes case-insensitively")
local http_url = SourceImporter.validateRemoteUrl("http://imports.example.test/sources.json")
assertx.equal(true, http_url.valid, "HTTP remote URL is accepted without transport")
assertx.equal("INSECURE_ORIGIN", http_url.warning.code, "HTTP remote URL returns an explicit warning")
local blocked_url = SourceImporter.validateRemoteUrl("file:///mnt/us/source.json")
assertx.equal(false, blocked_url.valid, "non-HTTP URL is rejected for remote import")
assertx.equal("INVALID_INPUT", blocked_url.error.code, "rejected URL returns structured validation error")

local optional_js = Scanner.scan({
    searchUrl = "https://example.test/search?key={{key}}",
    ruleSearch = ".result", ruleBookInfo = ".info", ruleToc = ".chapter", ruleContent = "#content",
    customScript = "@js: return 1",
})
assertx.equal("partial", optional_js.status, "optional JavaScript makes a source partial")
assertx.equal("EXECUTABLE_JS", optional_js.issues[1].code, "optional JavaScript issue is classified stably")
assertx.equal("customScript", optional_js.issues[1].field, "issue identifies the source field")

local named_webview = Scanner.scan({
    searchUrl = "https://example.test/search?key={{key}}",
    ruleSearch = ".result", ruleBookInfo = ".info", ruleToc = ".chapter", ruleContent = "#content",
    webView = true,
})
assertx.equal("partial", named_webview.status, "named optional WebView configuration is partial even when non-string")
assertx.equal("WEBVIEW", named_webview.issues[1].code, "named WebView configuration is detected")
assertx.equal("webView", named_webview.issues[1].field, "named WebView issue identifies its field")

local dangerous_cases = {
    { value = "@js: return 1", code = "EXECUTABLE_JS" },
    { value = "<js>return 1</js>", code = "EXECUTABLE_JS" },
    { value = "eval('x')", code = "DYNAMIC_EVAL" },
    { value = "java.lang.Runtime", code = "JAVA_API" },
    { value = "android.webkit.WebView", code = "ANDROID_API" },
    { value = "Packages.java.lang", code = "JAVA_API" },
    { value = "webView", code = "WEBVIEW" },
    { value = "loginUi", code = "LOGIN_UI" },
    { value = "loginCheckJs", code = "LOGIN_UI" },
}
for _, case in ipairs(dangerous_cases) do
    local result = Scanner.scan({
        searchUrl = "https://example.test/search?key={{key}}",
        ruleSearch = case.value, ruleBookInfo = ".info", ruleToc = ".chapter", ruleContent = "#content",
    })
    assertx.equal("unsupported", result.status, "dangerous required search rule is unsupported: " .. case.code)
    assertx.equal(case.code, result.issues[1].code, "dangerous construct code is stable: " .. case.code)
    assertx.equal("ruleSearch", result.issues[1].field, "dangerous required issue identifies its field")
end

local missing = Scanner.scan({ searchUrl = "https://example.test/search?key={{key}}", ruleSearch = ".result" })
assertx.equal("unsupported", missing.status, "missing core paths make source unsupported")
assertx.equal("MISSING_BOOK_INFO", missing.issues[1].code, "missing issues use core-field order")
assertx.equal("MISSING_TOC", missing.issues[2].code, "missing catalog issue follows book info")
assertx.equal("MISSING_CONTENT", missing.issues[3].code, "missing content issue follows catalog")

return 60
