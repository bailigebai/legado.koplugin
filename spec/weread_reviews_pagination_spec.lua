require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

local shown, requests = {}, {}
local client = {bookReviews = function(_, book_id, callback, cursor)
    local row = {book_id = book_id, callback = callback, cursor = cursor}
    requests[#requests + 1] = row
    return {cancel = function() row.cancelled = true end}
end}
local auth = {hasSession = function() return true end,
    session = function() return {vid = "account"} end}
local view = View.new{auth = auth, client = client}
view.synced = true
view.books = {{id = "local-1", remote_id = "remote-1", source_id = "weread",
    name = "测试书", intro = "简介"}}
local presenter = Presenter.new{ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end}}
local function action(label)
    for _, item in ipairs(shown[#shown].actions or {}) do
        if item.text == label then return item end
    end
end

presenter:show(view)
shown[#shown].items[1].callback()
action("阅读评论").callback()
eq(1, #requests, "review page fetches only the first batch on open")
eq(nil, requests[1].cursor, "first review batch has no cursor")
requests[1].callback({reviews = {{review = {review = {book = {bookId = "remote-1"}, content = "第一页"}}}},
    has_more = true, next_cursor = {max_idx = 20, synckey = 123}})
eq("第一页", shown[#shown].items[1].text, "first review batch appears")
eq(1, shown[#shown].page, "first batch is page one")
shown[#shown].on_next()
eq(2, #requests, "next page fetches only after navigation")
eq(20, requests[2].cursor.max_idx, "next page reuses the review cursor")
eq("正在加载评论…", shown[#shown].items[1].text, "loading is visible without blocking the old page")
requests[2].callback({reviews = {{review = {review = {book = {bookId = "remote-1"}, content = "第二页"}}}},
    has_more = true, next_cursor = {max_idx = 40, synckey = 123}})
eq("第二页", shown[#shown].items[1].text, "second review batch appears")
eq(2, shown[#shown].page, "second batch is page two")
shown[#shown].on_prev()
eq("第一页", shown[#shown].items[1].text, "previous batch is available locally")
shown[#shown].on_next()
eq("第二页", shown[#shown].items[1].text, "returning to a loaded batch uses the local copy")
eq(2, #requests, "local page navigation does not repeat the request")
shown[#shown].on_next()
eq(3, #requests, "a third batch starts only when requested")
shown[#shown].on_back()
eq(true, requests[3].cancelled, "leaving reviews cancels the next batch")
eq("微信读书 · 测试书", shown[#shown].title, "back returns to book detail")
requests[3].callback({reviews = {{review = {review = {book = {bookId = "remote-1"}, content = "迟到页"}}}}})
eq("微信读书 · 测试书", shown[#shown].title, "late review page cannot reopen the review screen")

action("阅读评论").callback()
shown[#shown].on_next()
shown[#shown].on_next()
eq(4, #requests, "reopening reviews reuses loaded pages before requesting the next one")
requests[4].callback(nil, "暂时失败")
eq("加载失败，点击重试", shown[#shown].items[1].text, "failed page offers an in-place retry")
shown[#shown].items[1].callback()
eq(5, #requests, "retry requests the failed review page again")
eq(40, requests[5].cursor.max_idx, "retry does not skip the failed cursor")
requests[5].callback({reviews = {{review = {review = {book = {bookId = "remote-1"}, content = "第三页"}}}},
    has_more = false})
eq("第三页", shown[#shown].items[1].text, "retry result appears on the requested page")
eq(nil, shown[#shown].on_next, "last review page has no further navigation")

return count
