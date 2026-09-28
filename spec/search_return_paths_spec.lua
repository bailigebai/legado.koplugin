require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local SourceManager = require("legado.ui.source_manager")
local count = 0
local function eq(expected, actual, reason) count = count + 1; A.equal(expected, actual, reason) end
local function item(items, label)
    for _, entry in ipairs(items or {}) do if entry.text == label then return entry end end
    error("missing action: " .. label)
end
local books = {}
for index = 1, 18 do books[index] = {id = "b" .. index, name = "书" .. index} end
local storage = {listShelf = function() return books end, listSources = function() return {} end,
    getProgress = function() return nil end}
local searches, shown = {}, {}
local service = {search = function(_, keyword, _, _, callback)
    searches[#searches + 1] = keyword
    callback({groups = {}, errors = {}, completed = 1, total = 1, has_more = false})
    return {cancel = function() end}
end}
local presenter = Presenter.new{menu = {new = function(_, options) return options end},
    input_dialog = {new = function(_, options) return options end},
    ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end,
        close = function() end}}
local app = App.new{storage = storage, book_service = service,
    source_manager = SourceManager.new{storage = storage},
    show = function(view) return presenter:show(view) end}
presenter.app = app
local function last() return shown[#shown] end
local function open_group(label) return item(last().actions, label).callback() end
local function search_again()
    item(last().actions, "更多").callback()
    return item(last().items, "搜索书名").callback()
end

app:openHome()
last().on_next()
eq(2, last().page, "navigation starts on shelf page two")
open_group("找书")
item(last().items, "搜索").callback()
last().buttons[1][1].callback()
eq(2, last().page, "cancelling search restores the shelf page")

open_group("书源与下载")
item(last().items, "书源管理").callback()
eq("书源管理", last().title, "source management opens from its shelf group")
item(last().items, "搜索添加").callback()
last().buttons[1][1].callback()
eq("书源管理", last().title, "cancelling search from sources restores source management")
last().on_back()
eq(2, last().page, "source management returns to the original shelf page")

open_group("找书")
item(last().items, "搜索").callback()
last().buttons[1][2].callback("甲")
eq("搜索 · 甲", last().title, "search results show the first query")
local original_view = presenter.library_view
search_again()
last().buttons[1][1].callback()
eq("搜索 · 甲", last().title, "cancelling a new query restores prior results")
eq(original_view, presenter.library_view, "new query uses the existing search controller")
search_again()
last().buttons[1][2].callback("乙")
eq("搜索 · 乙", last().title, "searching again replaces the visible query")
eq(original_view, presenter.library_view, "searching again does not leak a second controller")
eq("甲", searches[1], "the first query reached the service")
eq("乙", searches[2], "the second query reached the service")
local pending = {}
service.search = function(_, keyword, _, _, callback)
    local request = {keyword = keyword, callback = callback, cancelled = false}
    pending[#pending + 1] = request
    return {cancel = function() request.cancelled = true end}
end
search_again()
last().buttons[1][2].callback("丙")
eq("搜索 · 丙", last().title, "a new query can remain in flight")
search_again()
local new_query_dialog = last()
eq(true, pending[1].cancelled, "opening a new search stops the old in-flight query")
pending[1].callback({groups = {}, completed = 1, total = 1})
eq(new_query_dialog, last(), "a late old result cannot cover the new search dialog")
last().buttons[1][2].callback("丁")
eq("搜索 · 丁", last().title, "a late result cannot replace the newer query")
pending[2].callback({groups = {}, completed = 1, total = 1})
eq(original_view, presenter.library_view, "queries during loading still reuse the same controller")
return count
