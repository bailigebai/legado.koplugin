local assertx = require("assertions")
local Presenter = require("legado.ui.presenter")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local shown = {}
local closed_widgets = {}
local ui = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function(_, widget) closed_widgets[#closed_widgets + 1] = widget end,
}
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
menu.close_callback() -- KOReader Menu:onMenuSelect follows item.callback with this call.
local dialog = shown[#shown]
equal("input", dialog.widget_type, "diagnostic action asks for a probe title")
dialog.buttons[1][2].callback("probe")
equal("probe", probe_keyword, "probe title is passed to diagnostics")
local result = shown[#shown]
truthy(result.text:find("search：success", 1, true) ~= nil and result.text:find("HTTP 200", 1, true) ~= nil
    and result.text:find("utf%-8") ~= nil, "safe request metadata is displayed")
truthy(result.text:find("catalog：failed", 1, true) ~= nil and result.text:find("PARSE_ERROR", 1, true) ~= nil,
    "structured failure is displayed")
truthy(result.text:find("10 ms", 1, true) ~= nil, "step duration is displayed")
truthy(result.text:find("results=1", 1, true) ~= nil, "safe field counts are displayed")
equal(nil, result.text:find("must%-not%-render"), "raw error message is not displayed")
menu.close_callback()
equal(1, closed, "closing the menu closes and cancels the report controller")

local async_callback, cancel_count = nil, 0
local async_view = {
    kind = "compatibility_report", status = "usable", capabilities = {}, issues = {}, diagnostics = {},
    run = function(_, _, callback)
        async_callback = callback
        return { cancel = function() cancel_count = cancel_count + 1; return true end }
    end,
    close = function() return true end,
}
local async_menu = presenter:show(async_view)
async_menu.item_table[#async_menu.item_table].callback()
async_menu.close_callback()
local async_dialog = shown[#shown]
async_dialog.buttons[1][2].callback("probe")
local progress = shown[#shown]
equal("诊断中", progress.title, "asynchronous diagnostics show a progress menu")
equal("search：等待中", progress.item_table[1].text, "progress lists search")
equal("result：等待中", progress.item_table[2].text, "progress lists result selection")
equal("catalog：等待中", progress.item_table[3].text, "progress lists catalog")
equal("content：等待中", progress.item_table[4].text, "progress lists content")
equal("取消诊断", progress.item_table[5].text, "progress provides an explicit cancel action")
progress.item_table[5].callback()
progress.close_callback()
equal(1, cancel_count, "touch cancel and close/back paths cancel the handle exactly once")
local shown_after_cancel = #shown
async_callback({ status = "completed", steps = {} })
equal(shown_after_cancel, #shown, "late callback after progress close is ignored")

local back_cancel_count = 0
local back_view = {
    kind = "compatibility_report", status = "usable", capabilities = {}, issues = {}, diagnostics = {},
    run = function(_, _, callback)
        return { cancel = function() back_cancel_count = back_cancel_count + 1; return true end }
    end,
    close = function() return true end,
}
local back_menu = presenter:show(back_view)
back_menu.item_table[#back_menu.item_table].callback()
back_menu.close_callback()
shown[#shown].buttons[1][2].callback("probe")
local back_progress = shown[#shown]
local closed_before_back = #closed_widgets
ui:close(back_progress) -- KOReader closes the widget before invoking close_callback on physical Back.
back_progress.close_callback()
equal(closed_before_back + 1, #closed_widgets, "physical Back does not close diagnostic progress a second time")
equal(1, back_cancel_count, "physical Back cancels diagnostics exactly once")

return count
