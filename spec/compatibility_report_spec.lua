local assertx = require("assertions")
local CompatibilityReport = require("legado.ui.compatibility_report")

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
equal(1, active_cancelled, "closing report cancels any retained handle")
equal(false, view:close(), "closing report is idempotent")

return count
