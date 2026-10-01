require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local Mapper = require("legado.lib.weread_mapper")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, shelf_reply, review_reply, review_cancelled = {}, nil, nil, false
local client = {
    shelfSync = function(_, callback)
        shelf_reply = callback
        return {cancel = function() end}
    end,
    bookReviews = function(_, _, callback)
        review_reply = callback
        return {cancel = function() review_cancelled = true end}
    end,
}
local auth = {hasSession = function() return true end,
    session = function() return {vid = "account"} end}
local view = View.new{auth = auth, client = client}
view.synced = true
local presenter = Presenter.new{ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end}}
local function action(label)
    for _, item in ipairs(shown[#shown].actions or {}) do
        if item.text == label then return item end
    end
end
presenter:show(view)
action("同步书架").callback()
action("书城发现").callback()
eq("微信书城", shown[#shown].title, "store opens while shelf sync is pending")
shelf_reply({books = {{bookId = "remote-1", title = "测试书"}}})
eq("微信书城", shown[#shown].title, "late shelf sync does not pull the reader out of the store")
shown[#shown].on_back()
eq("微信读书", shown[#shown].title, "back shows the newly synchronized shelf")
shown[#shown].items[1].callback()
eq("微信读书 · 测试书", shown[#shown].title, "synchronized book opens its detail")
shown[#shown].header_action.callback()
shown[#shown].items[2].callback()
eq("阅读评论 · 测试书", shown[#shown].title, "reviews start loading")
shown[#shown].on_back()
eq("微信读书 · 测试书", shown[#shown].title, "back leaves review loading")
eq(true, review_cancelled, "leaving reviews cancels the pending request")
review_reply({reviews = {{review = {review = {bookId = "remote-1", content = "迟到评论"}}}}})
eq("微信读书 · 测试书", shown[#shown].title, "late reviews do not reopen the review page")
local add_reply
client.addToShelf = function(_, _, callback)
    add_reply = callback
    return {cancel = function() end}
end
client.shelfSync = function(_, callback)
    callback(nil, "network offline")
    return {cancel = function() end}
end
presenter:_wereadBook(view, Mapper.book({bookId = "remote-2", title = "另一本书"}, "account"))
shown[#shown].header_action.callback()
shown[#shown].items[1].callback()
shown[#shown].on_back()
local shown_before_add = #shown
add_reply({errCode = 0})
eq(shown_before_add, #shown, "late addition warning does not open a message over the shelf")
presenter:_wereadBook(view, Mapper.book({bookId = "remote-3", title = "第三本书"}, "account"))
shown[#shown].header_action.callback()
shown[#shown].items[1].callback()
shown[#shown].on_back()
shown_before_add = #shown
add_reply(nil, "network offline")
eq(shown_before_add, #shown, "late addition failure does not open a message over the shelf")

local reading_reply, reading_cancellations = nil, 0
presenter.app = {startWeReadReading = function(_, _, callback)
    reading_reply = callback
    return {cancel = function() reading_cancellations = reading_cancellations + 1 end}
end}
local reading_view = View.new{auth = auth, client = {}}
reading_view.synced = true
reading_view.books = {{id = "local-1", remote_id = "remote-1", source_id = "weread", name = "阅读中"}}
presenter:show(reading_view)
shown[#shown].hero_action.callback()
action("书城发现").callback()
eq(1, reading_cancellations, "leaving the shelf cancels its pending reading request")
local before_late_error = #shown
reading_reply(nil, {message = "late reading error"})
eq(before_late_error, #shown, "late reading error cannot cover the store")

shown[#shown].on_back()
shown[#shown].items[1].callback()
action("开始阅读").callback()
shown[#shown].on_back()
eq(2, reading_cancellations, "leaving book detail cancels its pending reading request")
before_late_error = #shown
reading_reply(nil, {message = "late detail error"})
eq(before_late_error, #shown, "late detail error cannot cover the shelf")

shown[#shown].hero_action.callback()
reading_reply(nil, {message = "current reading error"})
eq("current reading error", shown[#shown].text, "current reading failure remains visible")

local current_account, switched_reads = "account-a", 0
local switched_auth = {hasSession = function() return true end,
    session = function() return {vid = current_account} end}
local switched_client = {shelfSync = function(_, callback)
    callback({books = {}})
    return {cancel = function() end}
end}
local function switched_view()
    local next_view = View.new{auth = switched_auth, client = switched_client}
    next_view.synced = true
    next_view.books = {Mapper.book({bookId = "old-book", title = "旧账号书"}, "account-a")}
    return next_view
end
presenter.app = {startWeReadReading = function()
    switched_reads = switched_reads + 1
end}
local stale_shelf = switched_view()
presenter:show(stale_shelf)
local stale_hero = shown[#shown].hero_action.callback
current_account = "account-b"
stale_hero()
eq(0, switched_reads, "a stale hero cannot open the old account book under a new login")
eq("微信读书", shown[#shown].title, "stale hero returns to the new account shelf")

current_account = "account-a"
local refreshed_shelf = switched_view()
presenter:show(refreshed_shelf)
local old_hero = shown[#shown].hero_action.callback
current_account = "account-b"
refreshed_shelf:page(1)
old_hero()
eq(0, switched_reads, "a stale hero remains blocked after another operation refreshes the account")

current_account = "account-a"
local old_store = switched_view()
old_store.store_keyword = "旧搜索"
old_store.store_results = {Mapper.book({bookId = "store-book", title = "旧书城书"}, "account-a")}
presenter:_wereadStore(old_store)
local old_store_book = shown[#shown].items[1].callback
current_account = "account-b"
old_store:page(1)
old_store_book()
eq("微信读书", shown[#shown].title,
    "a stale store cover cannot open old account detail after account refresh")

current_account = "account-a"
local stale_detail = switched_view()
presenter:show(stale_detail)
shown[#shown].items[1].callback()
eq("微信读书 · 旧账号书", shown[#shown].title, "old account book detail is open")
current_account = "account-b"
action("开始阅读").callback()
eq(0, switched_reads, "a stale book detail cannot start reading after account switch")
eq("微信读书", shown[#shown].title, "stale book detail returns to the new account shelf")

current_account = "account-a"
local switched_cancellations = 0
presenter.app = {startWeReadReading = function()
    switched_reads = switched_reads + 1
    return {cancel = function() switched_cancellations = switched_cancellations + 1 end}
end}
local pending_account_read = switched_view()
presenter:show(pending_account_read)
shown[#shown].hero_action.callback()
eq(1, switched_reads, "the old account may begin reading before the login changes")
current_account = "account-b"
pending_account_read:page(1)
eq(1, switched_cancellations, "switching accounts cancels an in-flight old-account read")
return count
