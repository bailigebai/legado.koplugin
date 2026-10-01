require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown = {}
local opened = {}
local presenter = Presenter.new{app = {startWeReadReading = function(_, book, callback)
    opened[#opened + 1] = book.remote_id
    callback({backend = "native"})
end}, ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end }}
local client = { bookReviews = function(_, _, callback) callback({ reviews = {
    { review = { review = { bookId = "remote-1", content = "评论正文", reviewId = "r1" } } },
} }); return { cancel = function() end } end }
local auth = { hasSession = function() return true end,
    session = function() return { vid = "account" } end }
local view = View.new{auth = auth, client = client}
view.synced = true
for index = 1, 6 do view.books[index] = {
    id = "local-" .. index, remote_id = "remote-" .. index, source_id = "weread",
    name = "书" .. index, intro = "简介" .. index, progress_percent = index * 10,
} end
presenter:show(view)
local first_shelf = shown[#shown]
eq("shelf_hero", shown[#shown].mode, "WeRead shelf shares the homepage hero layout")
eq(5, #shown[#shown].items, "WeRead first page has one hero and four covers")
eq("简介1", shown[#shown].items[1].intro, "remote hero shows its summary")
eq("继续阅读", shown[#shown].hero_action.text, "WeRead hero offers direct reading")
shown[#shown].hero_action.callback()
eq("remote-1", opened[1], "WeRead hero opens the most recently read book directly")
presenter:_weread(view)
local refreshed_shelf = shown[#shown]
first_shelf.hero_action.callback()
eq(1, #opened, "earlier render of the same shelf page cannot start reading")
eq(refreshed_shelf, shown[#shown], "earlier render cannot replace the refreshed shelf")
first_shelf = refreshed_shelf
shown[#shown].items[1].callback()
eq("微信读书 · 书1", shown[#shown].title, "remote book opens its own detail page")
eq("detail", shown[#shown].mode, "remote detail shows cover and summary")
eq("简介1", shown[#shown].items[1].intro, "remote detail keeps the full summary")
eq(1, #shown[#shown].actions, "remote detail reserves its primary action for reading")
eq("更多", shown[#shown].header_action.text, "remote detail places secondary actions in its header")
local before_stale = #shown
first_shelf.hero_action.callback()
eq(1, #opened, "closed shelf hero cannot start another reading request")
eq(before_stale, #shown, "closed shelf hero leaves the current book detail visible")
first_shelf.items[2].callback()
eq(before_stale, #shown, "closed shelf cover cannot reopen another book detail")
for _, stale_action in ipairs(first_shelf.actions) do
    if stale_action.text == "书城发现" or stale_action.text == "同步书架"
        or stale_action.text == "微信扫码登录" then stale_action.callback() end
end
eq(before_stale, #shown, "closed shelf navigation and account actions cannot replace the book detail")
for _, action in ipairs(shown[#shown].actions) do
    if action.text == "开始阅读" then action.callback(); break end
end
eq("remote-1", opened[2], "book detail shares the same reading entry")
local review_action
shown[#shown].header_action.callback()
for _, item in ipairs(shown[#shown].items) do if item.text == "整本书评" then review_action = item end end
eq("function", type(review_action and review_action.callback), "remote book exposes clickable reviews")
review_action.callback()
eq("评论正文", shown[#shown].items[1].text, "review list shows content")
shown[#shown].items[1].callback()
eq("评论正文", shown[#shown].text, "review opens a detail message")
local warning = "微信书架已更新，但本地保存失败；重启后可能恢复上次书架"
local unsaved_view = View.new{auth = auth, path = "weread-shelf.json",
    fs = {readBounded = function() return nil end, atomicWrite = function() return nil end},
    client = {shelfSync = function(_, done)
        done({books = {{bookId = "recent", title = "本次同步"}}})
        return {cancel = function() end}
    end}}
presenter:show(unsaved_view)
eq(warning, shown[#shown].subtitle, "the shelf page shows that remote books were not saved")
local unreadable_history=View.new{auth=auth,storage={listProgress=function()
    return nil,{code='STORAGE_ERROR'}
end}}
unreadable_history.books={{id='local-1',remote_id='remote-1',source_id='weread',name='离线封面'}}
unreadable_history.synced=true
presenter:show(unreadable_history)
eq('已登录 · 本地阅读记录不可用',shown[#shown].subtitle,
    'local progress failure is visible while remote covers remain usable')
eq('离线封面',shown[#shown].items[1].title,'history failure does not hide the remote shelf')
local notice_shown={}
local notice_presenter=Presenter.new{app={startWeReadReading=function(_,_,callback)
    callback({backend='native',reading_state={image_mode_switched=true}})
end},ui_manager={show=function(_,widget) notice_shown[#notice_shown+1]=widget end}}
local notice_view=View.new{auth=auth}
notice_view.synced=true
notice_view.books={{id='notice-book',remote_id='notice-remote',source_id='weread',name='图文书'}}
notice_presenter:show(notice_view)
notice_shown[#notice_shown].hero_action.callback()
eq('本书含图片，已自动切换原生阅读模式。',notice_shown[#notice_shown].text,
    'first image chapter explains the automatic reader mode change')
return count
