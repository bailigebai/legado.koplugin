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
local presenter = Presenter.new{ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end},
    screen = {getHeight = function() return 800 end}}
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

local html_view = View.new{auth = auth, client = client}
html_view.synced = true
html_view.books = view.books
presenter:show(html_view)
shown[#shown].items[1].callback()
action("阅读评论").callback()
local long_review = ("这是一段完整评论。"):rep(100)
requests[#requests].callback({reviews = {{review = {review = {book = {bookId = "remote-1"},
    htmlContent = "<p>完整&nbsp;评论</p><p>第二段</p>"}}},
    {review = {review = {book = {bookId = "remote-1"}, htmlContent = "<p> </p>"}}},
    {review = {review = {book = {bookId = "remote-1"},
        htmlContent = "<script>忽略</script><p>正文</p>"}}},
    {review = {review = {book = {bookId = "remote-1"},
        content = "摘要", htmlContent = "<p>可阅读的完整点评</p>"}}},
    {review = {review = {book = {bookId = "remote-1"}, content = long_review}}}}, has_more = false})
eq("完整 评论\n第二段", shown[#shown].items[1].text,
    "a rich-text-only review appears as readable plain text")
eq("无文字评论", shown[#shown].items[2].text,
    "empty rich text does not create a blank review row")
eq("正文", shown[#shown].items[3].text,
    "non-review markup is omitted from the displayed review")
eq("可阅读的完整点评", shown[#shown].items[4].text,
    "rich text takes precedence when it contains more than the summary")
local review_screen = shown[#shown]
review_screen.items[1].callback()
eq("完整 评论\n第二段", shown[#shown].text,
    "opening a rich-text-only review shows its full plain text")
eq(nil, shown[#shown].height, "short reviews keep their adaptive dialog height")
review_screen.items[4].callback()
eq("可阅读的完整点评", shown[#shown].text,
    "opening a review with both fields shows the complete rich text")
review_screen.items[5].callback()
eq(long_review, shown[#shown].text, "opening a long review preserves its entire text")
eq(560, shown[#shown].height, "long reviews request a bounded scrollable text area")
eq("weread_reviews:remote-1", presenter.library_subpage,
    "opening a review keeps the review list as the return page")

return count
