local assertx = require("assertions")
local Presenter = require("legado.ui.presenter")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local shown = {}
local ui = { show = function(_, widget) shown[#shown + 1] = widget end }
local function widget(kind)
    return { new = function(_, options) options.widget_type = kind; return options end }
end
local presenter = Presenter.new({
    ui_manager = ui,
    menu = widget("menu"),
    info_message = widget("info"),
    input_dialog = widget("input"),
})

local closed = 0
local probe_keyword
local report = {
    kind = "compatibility_report",
    status = "partial",
    capabilities = {
        { name = "search", supported = true },
        { name = "catalog", supported = false },
    },
    issues = {
        { field = "ruleToc", code = "EXECUTABLE_JS" },
        { field = "ruleContent", code = "ANDROID_API" },
    },
    diagnostics = {},
    run = function(_, keyword, callback)
        probe_keyword = keyword
        callback({ status = "failed", steps = {
            { name = "search", status = "success", duration_ms = 10, http_status = 200, charset = "utf-8", field_counts = { results = 1 } },
            { name = "catalog", status = "failed", duration_ms = 20, error = { code = "PARSE_ERROR", message = "must-not-render" } },
        } })
        return { cancel = function() return true end }
    end,
    close = function() closed = closed + 1; return true end,
}

local menu = presenter:show(report)
equal("状态：partial", menu.item_table[1].text, "compatibility status is visible")
equal("search：支持", menu.item_table[2].text, "supported capability is visible")
equal("catalog：不支持", menu.item_table[3].text, "unsupported capability is visible")
equal("ruleToc：EXECUTABLE_JS", menu.item_table[4].text, "first issue remains first")
equal("ruleContent：ANDROID_API", menu.item_table[5].text, "second issue remains second")
equal("运行诊断", menu.item_table[6].text, "report exposes the diagnostic action")
menu.item_table[6].callback()
local dialog = shown[#shown]
equal("input", dialog.widget_type, "diagnostic action asks for a probe title")
dialog.buttons[1][2].callback("probe")
equal("probe", probe_keyword, "probe title is passed to diagnostics")
local result = shown[#shown]
truthy(result.text:find("search：success · HTTP 200 · utf%-8") ~= nil, "safe request metadata is displayed")
truthy(result.text:find("catalog：failed · PARSE_ERROR", 1, true) ~= nil, "structured failure is displayed")
equal(nil, result.text:find("must%-not%-render"), "raw error message is not displayed")
menu.close_callback()
equal(1, closed, "closing the menu closes and cancels the report controller")

return count
