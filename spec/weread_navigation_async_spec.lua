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
action("阅读评论").callback()
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
action("加入微信书架").callback()
shown[#shown].on_back()
local shown_before_add = #shown
add_reply({errCode = 0})
eq(shown_before_add, #shown, "late addition warning does not open a message over the shelf")
presenter:_wereadBook(view, Mapper.book({bookId = "remote-3", title = "第三本书"}, "account"))
action("加入微信书架").callback()
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
return count
