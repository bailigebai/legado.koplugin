require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

local shown, calls = {}, {}
local function batch(first, last)
    local books = {}
    for i = first, last do
        books[#books + 1] = {bookId = "book-" .. i, title = "书 " .. i, searchIdx = i}
    end
    return books
end
local client = {search = function(_, keyword, cursor, callback, sid)
    calls[#calls + 1] = {keyword = keyword, cursor = cursor, sid = sid, callback = callback}
    return {cancel = function() end}
end}
local auth = {hasSession = function() return true end,
    session = function() return {vid = "account"} end}
local view = View.new{auth = auth, client = client}
view.synced = true
local presenter = Presenter.new{ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end}}
presenter:show(view)
local store
for _, action in ipairs(shown[#shown].actions) do if action.text == "书城发现" then store = action end end
store.callback()
for _, item in ipairs(shown[#shown].items) do
    if item.text == "科幻" then item.callback(); break end
end
eq(1, #calls, "first store page starts one request")
calls[1].callback({books = batch(1, 20), hasMore = 1, sid = "session-1"})
eq(12, #shown[#shown].items, "first page shows 12 book covers")
shown[#shown].on_next()
eq(2, #calls, "an incomplete display page requests more books before it opens")
eq(20, calls[2].cursor, "next request uses the last search index")
eq("session-1", calls[2].sid, "next request preserves the search session")
calls[2].callback({books = batch(21, 35), hasMore = 0, sid = "session-1"})
eq(12, #shown[#shown].items, "second page keeps the 12-cover layout")
eq("书 13", shown[#shown].items[1].title, "second page continues the first remote batch")
shown[#shown].on_next()
eq(2, #calls, "remaining results use the final local page")
eq(11, #shown[#shown].items, "final page can contain fewer than 12 books")
eq("书 25", shown[#shown].items[1].title, "last display page begins at book 25")
eq(nil, shown[#shown].on_next, "no next button remains after the remote end")
local rerendered = 0
view:searchStore("文学", function() rerendered = rerendered + 1; presenter:_wereadStore(view) end)
presenter:_wereadStore(view)
shown[#shown].on_back()
eq("微信书城", shown[#shown].title, "back returns to store discovery")
calls[3].callback({books = batch(40, 41), hasMore = 0})
eq(0, rerendered, "late search response does not reopen results after back")
eq(nil, view.store_keyword, "leaving results clears the old keyword")
view:searchStore("历史", function() presenter:_wereadStore(view) end)
presenter:_wereadStore(view)
calls[4].callback({books = batch(1, 20), hasMore = 1, sid = "session-2"})
shown[#shown].on_next()
calls[5].callback(nil, "网络暂时不可用")
eq(20, #view.store_results, "failed next request preserves loaded books")
eq("网络暂时不可用", shown[#shown].subtitle, "load failure is visible")
eq("function", type(shown[#shown].on_next), "load failure keeps the retry action")
shown[#shown].on_next()
eq(6, #calls, "retry requests another remote page")
eq(20, calls[6].cursor, "retry does not skip the failed page")
calls[6].callback({books = batch(21, 25), hasMore = 0})
eq("书 13", shown[#shown].items[1].title, "retry opens the next display page")
view:searchStore("悬疑", function() presenter:_wereadStore(view) end)
presenter:_wereadStore(view)
calls[7].callback({books = batch(1, 20), hasMore = 1})
shown[#shown].on_next()
shown[#shown].items[1].callback()
eq("微信读书 · 书 1", shown[#shown].title, "opening a result shows the book detail")
calls[8].callback({books = batch(21, 30), hasMore = 0})
eq("微信读书 · 书 1", shown[#shown].title, "late next-page response does not replace the book detail")
shown[#shown].on_back()
eq("微信书城 · 悬疑", shown[#shown].title, "book detail returns to its store results")
view:searchStore("重复测试", function() presenter:_wereadStore(view) end)
presenter:_wereadStore(view)
calls[9].callback({books = batch(1, 20), hasMore = 1, sid = "session-dup"})
shown[#shown].on_next()
local repeated = batch(1, 20)
for index, row in ipairs(repeated) do row.searchIdx = 20 + index end
calls[10].callback({books = repeated, hasMore = 1, sid = "session-dup"})
eq(20, #view.store_results, "a duplicate remote batch does not repeat visible books")
eq("本批没有新书，点击下一页继续", shown[#shown].subtitle,
    "a duplicate batch explains why the display page did not change")
eq("function", type(shown[#shown].on_next), "an advancing remote cursor keeps later books reachable")
shown[#shown].on_next()
eq(40, calls[11].cursor, "the next request continues after the duplicate batch")
calls[11].callback({books = batch(41, 45), hasMore = 0})
eq("book-45", view.store_results[25].remote_id, "books after a duplicate batch can still load")
return count
