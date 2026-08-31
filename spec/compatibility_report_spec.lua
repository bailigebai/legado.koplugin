local assertx = require("assertions")
local CompatibilityReport = require("legado.ui.compatibility_report")
local SourceManager = require("legado.ui.source_manager")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end

local source = { id = "s1", bookSourceName = "Alpha" }
local scan = {
    status = "partial",
    capabilities = { search = true, book_info = false, catalog = true, content = false },
    issues = {
        { field = "ruleBookInfo", code = "EXECUTABLE_JS" },
        { field = "ruleContent", code = "ANDROID_API" },
    },
}
local active_cancelled = 0
local diagnostic_callback
local view = CompatibilityReport.new({
    source = source,
    scanner = { scan = function() return scan end },
    diagnostics = { run = function(_, selected, keyword, callback)
        equal(source, selected, "diagnostics use the report source")
        equal("keyword", keyword, "diagnostics use the supplied probe keyword")
        diagnostic_callback = callback
        return { cancel = function() active_cancelled = active_cancelled + 1; return true end }
    end },
})

equal("compatibility_report", view.kind, "report has a presenter kind")
equal("partial", view.status, "compatibility status is exposed")
equal(4, #view.capabilities, "all core capabilities are exposed")
equal("search", view.capabilities[1].name, "capabilities use stable core order")
equal(true, view.capabilities[1].supported, "supported capability is explicit")
equal("content", view.capabilities[4].name, "content remains last")
equal(false, view.capabilities[4].supported, "unsupported capability is explicit")
equal("ruleBookInfo", view.issues[1].field, "scanner issue order is preserved")
equal("ruleContent", view.issues[2].field, "later issue remains later")

local completed
local handle = view:run("keyword", function(report) completed = report end)
equal("table", type(handle), "report can run diagnostics")
diagnostic_callback({ status = "completed", steps = {} })
equal("completed", completed.status, "diagnostic result is delivered")
equal("completed", view.diagnostic.status, "diagnostic result remains visible")
equal(true, view:close(), "report can be closed")
equal(0, active_cancelled, "closing a completed report does not cancel a stale handle")
equal(false, view:close(), "closing report is idempotent")

local active_cancel_count = 0
local active_view = CompatibilityReport.new({
    source = source,
    scanner = { scan = function() return scan end },
    diagnostics = { run = function()
        return { cancel = function() active_cancel_count = active_cancel_count + 1; return true end }
    end },
})
active_view:run("keyword", function() end)
equal(true, active_view:cancel(), "active report exposes explicit cancellation")
equal(false, active_view:cancel(), "explicit cancellation is idempotent")
active_view:close()
equal(1, active_cancel_count, "cancel followed by close reaches the active handle exactly once")

local hostile = CompatibilityReport.new({
    source = source,
    scanner = { scan = function() return {
        status = "partial",
        capabilities = { search = true, SECRET = true },
        issues = {
            { field = "extra.https://reader:password@x/?token=SECRET\n", code = "EXECUTABLE_JS", message = "SECRET" },
            { field = "ruleContent.%53%45%43%52%45%54", code = "UNKNOWN_SECRET", message = "SECRET" },
        },
    } end },
})
local rendered = ""
for _, issue in ipairs(hostile.issues) do rendered = rendered .. tostring(issue.field) .. tostring(issue.code) .. tostring(issue.message) end
for _, capability in ipairs(hostile.capabilities) do rendered = rendered .. tostring(capability.name) end
equal(nil, rendered:find("SECRET", 1, true), "compatibility UI model drops unknown capabilities and secret issue data")
equal(nil, rendered:find("password", 1, true), "compatibility UI model redacts URL userinfo")
equal("EXECUTABLE_JS", hostile.issues[1].code, "known issue code remains useful")
equal("UNSUPPORTED_RULE", hostile.issues[2].code, "unknown issue code maps to a safe constant")

local manager = SourceManager.new({
    storage = { getSource = function() return source end, listSources = function() return { source } end },
    scanner = { scan = function() return {
        status = "partial", capabilities = { search = true },
        issues = { { field = "extra.https://x/?token=SECRET", code = "EXECUTABLE_JS", message = "SECRET" } },
    } end },
})
local manager_report = manager:compatibility("s1")
local manager_text = manager_report.issues[1].field .. manager_report.issues[1].message
equal(nil, manager_text:find("SECRET", 1, true), "source manager never exposes the scanner's raw issue object")

return count
