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

local account, account_requests = "account-a", {}
local switching_auth = {hasSession = function() return true end,
    session = function() return {vid = account} end}
local switching_client = {search = function(_, keyword, cursor, callback)
    local request = {keyword = keyword, cursor = cursor, callback = callback, cancelled = false}
    account_requests[#account_requests + 1] = request
    return {cancel = function() request.cancelled = true end}
end}
local switching_view = View.new{auth = switching_auth, client = switching_client}
switching_view:searchStore("旧结果")
account_requests[1].callback({books = batch(1, 1), hasMore = 0})
eq(1, #switching_view.store_results, "first account receives its store result")
account = "account-b"
switching_view:page(1)
eq(nil, switching_view.store_keyword, "switching accounts clears the old search keyword")
eq(nil, switching_view.store_results, "switching accounts clears loaded store books")

account = "account-a"
switching_view:page(1)
local switch_error
switching_view:searchStore("待返回", function(_, err) switch_error = err end)
account = "account-b"
account_requests[2].callback({books = batch(2, 2), hasMore = 0})
eq("account-b", switching_view.account_id, "a late first page refreshes the current account")
eq(true, account_requests[2].cancelled, "account switch cancels the old first-page request")
eq(nil, switching_view.store_results, "late first-page books do not enter the new account")
eq("微信读书账号已切换", switch_error, "the page can rerender after a switched-account reply")

switching_view:searchStore("新结果")
account_requests[3].callback({books = batch(3, 3), hasMore = 1})
eq(1, #switching_view.store_results, "the new account can search normally")
switching_view:loadMoreStore(function(_, err) switch_error = err end)
account = "account-c"
account_requests[4].callback({books = batch(4, 4), hasMore = 0})
eq(true, account_requests[4].cancelled, "account switch cancels the old next-page request")
eq(nil, switching_view.store_results, "late next-page books do not enter another account")
eq("微信读书账号已切换", switch_error, "next-page reply reports the account change")
switching_view:searchStore("第三个账号")
account_requests[5].callback({books = batch(5, 5), hasMore = 0})
eq("account-c", switching_view.account_id, "new searches use the current account")
eq("book-5", switching_view.store_results[1].remote_id,
    "new account results still load after the old requests are discarded")
local switching_shown = {}
local switching_presenter = Presenter.new{ui_manager = {
    show = function(_, widget) switching_shown[#switching_shown + 1] = widget end}}
switching_view.synced = true
switching_presenter:show(switching_view)
for _, action in ipairs(switching_shown[#switching_shown].actions or {}) do
    if action.text == "书城发现" then action.callback(); break end
end
for _, item in ipairs(switching_shown[#switching_shown].items or {}) do
    if item.text == "科幻" then item.callback(); break end
end
eq("微信书城 · 科幻", switching_shown[#switching_shown].title,
    "a pending search displays the current account's store page")
account = "account-d"
account_requests[6].callback({books = batch(6, 6), hasMore = 0})
eq("微信书城", switching_shown[#switching_shown].title,
    "a late old-account reply returns to empty store discovery")
eq(nil, switching_view.store_results, "the old response leaves no books on the new store page")
return count
