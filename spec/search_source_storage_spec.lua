require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local BookService = require("legado.lib.book_service")
local Models = require("legado.lib.models")
local Presenter = require("legado.ui.presenter")

local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

local source = { id = "source-1", bookSourceUrl = "https://example.test/",
    bookSourceName = "原有书源", enabled = true }
local book = Models.book(source, { name = "目标书", author = "作者", url = "/book" })
local state = "error"
local storage = { listSources = function()
    if state == "error" then return nil, { code = "STORAGE_ERROR" } end
    if state == "empty" then return {} end
    return { source }
end }
local service = BookService.new({ storage = storage, rule_engine = {},
    request_engine = {}, url_template = {} })
function service:_search_source(_, _, _, callback)
    callback({ book })
    return { cancel = function() return true end }
end

local direct_result, direct_error
service:search("目标书", nil, 1, function(result, err)
    direct_result, direct_error = result, err
end)
eq(nil, direct_result, "failed source listing cannot complete search as an empty success")
eq("STORAGE_ERROR", direct_error and direct_error.code,
    "aggregate search returns the storage error to its caller")

local shown, returned = {}, 0
local presenter = Presenter.new({ ui_manager = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end,
} })
local app = App.new({ storage = storage, book_service = service,
    show = function(view) return presenter:show(view) end })
presenter.app = app
local function last() return shown[#shown] end
local function action(items, title)
    for _, item in ipairs(items or {}) do if item.text == title then return item end end
end

app:openSearch("目标书", function() returned = returned + 1 end)
eq(true, last().empty_text:find("错误代码：STORAGE_ERROR", 1, true) ~= nil,
    "search page explains why sources could not be read")
eq(true, last().subtitle:find("STORAGE_ERROR", 1, true) ~= nil,
    "search status does not claim there were simply no matches")
local stale_retry = action(last().actions, "重试").callback
state = "ready"
stale_retry()
eq("目标书", last().items[1].title, "retry finds the book after storage recovers")
last().on_back()
eq(1, returned, "search returns to its original shelf")
local shown_after_exit = #shown
stale_retry()
eq(shown_after_exit, #shown, "retry from a closed search cannot reopen results")

state = "empty"
app:openSearch("目标书")
eq("暂无已启用的书源，请先在“书源与下载 → 书源管理”导入或启用书源。", last().empty_text,
    "a genuinely empty source list gives a source setup hint")
eq(nil, last().items[1], "an empty source list does not show a fake book result")

return count
