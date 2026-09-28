require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, reason)
    count = count + 1
    A.equal(expected, actual, reason)
end
local books = {}
for index = 1, 15 do books[index] = { id = "b" .. index, name = "书" .. index } end
local storage = {
    listShelf = function() return books end,
    getProgress = function(_, id) if id == "b1" then return {updated_at = 1} end end,
    listSources = function() return {} end,
}
local shown = {}
local ui = { show = function(_, widget) shown[#shown + 1] = widget end, close = function() end }
local presenter = Presenter.new{ui_manager = ui}
local app = App.new{storage = storage, show = function(view) return presenter:show(view) end}
presenter.app = app
local function last() return shown[#shown] end
local function item(items, label)
    for _, entry in ipairs(items or {}) do if entry.text == label then return entry end end
    error("missing action " .. label)
end
local function open_group(label)
    item(last().actions, label).callback()
    return last()
end

app:openHome()
eq(4, #last().actions, "shelf has four functional groups")
eq(0, #last().navigation, "shelf does not repeat groups in global navigation")
eq(0, #last().categories, "category and batch controls are together in management")
last().on_next()
eq(2, last().page, "test starts from the second shelf page")

open_group("找书")
eq("shelf_find", last().subpage, "search and discovery have one group")
eq("function", type(item(last().items, "搜索").callback), "search remains actionable")
eq("function", type(item(last().items, "发现").callback), "discovery remains actionable")
last():onClose()
eq(2, last().page, "find group returns to the same shelf page")

open_group("整理书架")
eq("shelf_manage", last().subpage, "category and batch controls have one group")
eq("function", type(item(last().items, "分类").callback), "category filter is reachable")
eq("function", type(item(last().items, "编辑分类").callback), "category editing is reachable")
eq("function", type(item(last().items, "批量选择").callback), "batch selection is reachable")
item(last().items, "在读").callback()
eq(1, last().page, "filter resets the shelf page")
eq(1, #last().items, "reading filter is applied")
open_group("整理书架")
item(last().items, "全部").callback()

open_group("书源与下载")
eq("shelf_sources", last().subpage, "source and cache download share one group")
eq("function", type(item(last().items, "书源管理").callback), "source management is reachable")
eq("function", type(item(last().items, "缓存书籍").callback), "cache creation is reachable beside source management")
eq("function", type(item(last().items, "下载管理").callback), "downloads are reachable")
last():onClose()

open_group("更多")
local review_count = 0
for _, entry in ipairs(last().items) do if entry.text == "阅读回顾" then review_count = review_count + 1 end end
eq(1, review_count, "reading review appears exactly once")
eq('function',type(item(last().items,'AI 服务').callback),'AI service has a direct more-page entry')
eq('function',type(item(last().items,'插件缓存').callback),'plugin cache has a direct more-page entry')
eq("function", type(item(last().items, "设置").callback), "settings remain reachable")

local cancelled_updates = 0
app.service = {checkUpdates = function()
    return {cancel = function() cancelled_updates = cancelled_updates + 1 end}
end}
app:openHome()
open_group("整理书架")
item(last().items, "未读").callback()
last().on_next()
eq(2, last().page, "unread shelf is on its second page before update check")
open_group("更多")
item(last().items, "检查更新").callback()
eq("正在检查更新", last().title, "update progress opens from the shelf group")
last().close_callback()
eq(2, last().page, "closing update progress restores the previous shelf page")
eq("b7", last().items[1].book.id, "the unread filter remains applied after update check")
eq(1, cancelled_updates, "leaving update progress cancels its pending request")
local detail = {kind = "book_detail", book = books[1], info = books[1], alternatives = {books[1]}, alive = true}
presenter:show(detail)
item(last().actions, "更多").callback()
local detail_review_count = 0
for _, action in ipairs(last().actions or {}) do if action.text == "阅读回顾" then detail_review_count = detail_review_count + 1 end end
for _, action in ipairs(last().items or {}) do if action.text == "阅读回顾" then detail_review_count = detail_review_count + 1 end end
eq(0, detail_review_count, "book detail does not repeat the global reading review")

app.settings = {all=function() return {} end, get=function() return nil end}
app.ai_service = {setKeyFile=function() return true end,testConnection=function() end}
app.cache_management = {usage=function() return {bytes=0,files=0} end}
app:openHome()
last().on_next()
open_group("更多")
item(last().items,"AI 服务").callback()
eq("AI 服务",last().title,"More opens AI settings directly")
last().close_callback()
eq("shelf_more",last().subpage,"AI settings return to the More group")
item(last().items,"插件缓存").callback()
eq("插件缓存",last().title,"More opens plugin cache directly")
last().close_callback()
eq("shelf_more",last().subpage,"plugin cache returns to the More group")
item(last().items,"设置").callback()
eq("设置",last().title,"More opens general settings")
item(last().item_table,"AI 服务设置").callback()
eq("AI 服务",last().title,"general settings can still open AI settings")
last().close_callback()
eq("设置",last().title,"AI settings opened from general settings return there")
item(last().item_table,"插件缓存管理").callback()
eq("插件缓存",last().title,"general settings can still open plugin cache")
last().close_callback()
eq("设置",last().title,"plugin cache opened from general settings returns there")
last().close_callback()
eq("shelf_more",last().subpage,"general settings return to the More group")
item(last().items,"关于").callback()
eq("关于不亦阅乎",last().title,"More opens the About page")
eq("function",type(last().on_back),"About has a return action")
last().on_back()
eq("shelf_more",last().subpage,"About returns to the More group")
storage.listProgress=function() return {} end
app.license={isAuthorized=function() return true end}
item(last().items,"阅读回顾").callback()
eq("阅读回顾",last().title,"More opens reading review")
last().on_back()
eq("shelf_more",last().subpage,"reading review returns to the More group")
last().on_close()
eq(2,last().page,"leaving More restores the original shelf page")
return count
