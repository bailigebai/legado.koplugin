require("library_screen_stub")
local A = require("assertions")
local Shelf = require("legado.ui.bookshelf")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(a,b,message) count=count+1; A.equal(a,b,message) end
do
    local ordered_books = {}
    for index = 1, 14 do ordered_books[index] = { id = "recent" .. index, name = "书" .. index } end
    local progress = {
        recent2 = { updated_at = 200 },
        recent13 = { updated_at = 100 },
        recent14 = { fraction = 0.5 },
    }
    local recent_shelf = Shelf.new{storage = {
        listShelf = function() return ordered_books end,
        getProgress = function(_, id) return progress[id] end,
    }}
    eq("recent2", recent_shelf:page(1, "cover").items[1].book.id, "most recently read book leads the cover shelf")
    eq("recent13", recent_shelf:page(1, "text").items[2].book.id, "text shelf uses the same reading order")
    eq("recent14", recent_shelf:page(2, "cover").items[2].book.id, "reading order is applied before pagination")
    progress.recent13.updated_at = 300
    eq("recent13", recent_shelf:page(1, "cover").items[1].book.id, "returning to the shelf reflects the latest reading time")
    recent_shelf:setFilter("unread")
    eq("recent1", recent_shelf:page(1, "cover").items[1].book.id, "unread books retain their existing order")
    recent_shelf:setFilter("reading")
    eq("recent13", recent_shelf:page(1, "cover").items[1].book.id, "reading filter keeps the most recent book first")
end
do
    local progress_failed, batch_reads, single_reads, displayed = true, 0, 0, {}
    local progress_storage = {
        listShelf = function() return {
            { id = "first", name = "原书架首本" },
            { id = "recent", name = "最近阅读" },
        } end,
        listProgress = function()
            batch_reads = batch_reads + 1
            if progress_failed then return nil, { code = "STORAGE_ERROR" } end
            return { { book_id = "recent", updated_at = 300 } }
        end,
        getProgress = function() single_reads = single_reads + 1; return nil end,
    }
    local model = Shelf.new({ storage = progress_storage })
    local failed_page = model:page(1, "hero")
    eq("STORAGE_ERROR", failed_page.progress_error.code,
        "batch progress failure is kept separate from an unread book")
    eq(2, failed_page.counts.unknown, "progress failure leaves reading state unknown")
    eq(0, failed_page.counts.unread, "unknown progress is not counted as unread")
    eq("first", failed_page.items[1].book.id,
        "progress failure preserves the original shelf order")
    model:setFilter("unread")
    eq(2, model:page(1, "hero").total,
        "unread filter keeps books reachable when progress cannot be checked")
    model:setFilter("reading")
    eq(2, model:page(1, "hero").total,
        "reading filter also keeps books reachable when progress cannot be checked")
    eq(0, single_reads, "available batch progress API avoids per-book reads")

    local presenter = Presenter.new({ ui_manager = {
        show = function(_, widget) displayed[#displayed + 1] = widget end,
        close = function() end,
    } })
    local app = App.new({ storage = progress_storage,
        show = function(view) return presenter:show(view) end })
    presenter.app = app
    app:openHome()
    eq(true, displayed[#displayed].subtitle:find("阅读进度读取失败", 1, true) ~= nil,
        "shelf explains that recent reading order is temporarily unavailable")
    eq("打开阅读", displayed[#displayed].hero_action.text,
        "unknown progress is not presented as a new or continued book")
    eq("重新读取", displayed[#displayed].header_action.text,
        "progress failure offers a retry without hiding books")
    progress_failed = false
    displayed[#displayed].header_action.callback()
    eq("recent", displayed[#displayed].items[1].book.id,
        "retry restores the most recently read book to the front")
    eq("继续阅读", displayed[#displayed].hero_action.text,
        "retry restores the continued-reading action")
    eq(0, single_reads, "successful batch load still avoids per-book reads")
    eq(true, batch_reads >= 4, "opening and retrying the shelf use batch progress reads")

    local legacy_calls = 0
    local legacy = Shelf.new({ storage = {
        listShelf = progress_storage.listShelf,
        getProgress = function()
            legacy_calls = legacy_calls + 1
            return nil, { code = "STORAGE_ERROR" }
        end,
    } })
    local legacy_page = legacy:page(1, "hero")
    eq("STORAGE_ERROR", legacy_page.progress_error.code,
        "legacy per-book progress failure is also reported")
    eq(2, legacy_page.total, "legacy failure keeps source books accessible")
    eq(1, legacy_calls, "legacy progress reads stop after the first storage failure")
end
do
    local failed, displayed = true, {}
    local unreliable_storage = {
        listShelf = function()
            if failed then return nil, { code = "STORAGE_ERROR" } end
            return { { id = "restored", name = "恢复的书" } }
        end,
        getProgress = function() return nil end,
    }
    local failed_page = Shelf.new({ storage = unreliable_storage }):page(1, "hero")
    eq("STORAGE_ERROR", failed_page.load_error.code,
        "shelf read failure remains distinguishable from an empty shelf")
    eq("书架读取失败", failed_page.empty_text,
        "shelf model does not call a failed read an empty collection")
    local presenter = Presenter.new({ ui_manager = {
        show = function(_, widget) displayed[#displayed + 1] = widget end,
        close = function() end,
    } })
    local app = App.new({ storage = unreliable_storage,
        show = function(view) return presenter:show(view) end })
    presenter.app = app
    app:openHome()
    eq(true, displayed[#displayed].subtitle:find("书架读取失败", 1, true) ~= nil,
        "shelf screen reports the storage failure")
    eq("重新读取", displayed[#displayed].header_action.text,
        "failed shelf offers a direct retry without changing the four action groups")
    failed = false
    displayed[#displayed].header_action.callback()
    eq("restored", displayed[#displayed].items[1].book.id,
        "retry reads the recovered shelf without reopening the plugin")
end
local books = {}
for i=1,27 do books[i]={id="b"..i,name="书"..i,kind=i%2==1 and "玄幻" or "科幻",intro="完整简介"..i} end
local storage = {listShelf=function() return books end,
    getProgress=function(_,id) if tonumber(id:sub(2))<=5 then return {fraction=0.2} end end}
local shelf = Shelf.new{storage=storage}
local first = shelf:page(1,"cover")
eq(12,#first.items,"cover shelf holds twelve books")
local marked_shelf=Shelf.new{storage=storage,is_cached=function(book) return book.id=="b1" end}
local marked=marked_shelf:page(1,"cover")
eq(true,marked.items[1].downloaded,"completed offline book is marked on the shelf")
eq(false,marked.items[2].downloaded,"other source books do not inherit the marker")
eq(3,first.page_count,"all 27 books remain reachable")
eq("b13",shelf:page(2,"cover").items[1].book.id,"page two starts at book13")
eq(3,#shelf:page(3,"cover").items,"last page holds the remainder")
shelf:setFilter("all","玄幻")
local filtered=shelf:page(2,"cover")
eq(14,filtered.total,"category filters before pagination")
eq(2,#filtered.items,"category second page retains remaining two books")
eq("b25",filtered.items[1].book.id,"category paging does not skip books")
shelf:setFilter("reading",nil)
eq(5,shelf:page(1,"cover").total,"reading state uses plugin progress")
shelf:setFilter("unread",nil)
eq(22,shelf:page(1,"cover").total,"unread books remain available")
shelf:setFilter("all","不存在")
eq(0,#shelf:page(1,"cover").items,"empty category is actionable without falling back to all books")

local shown={}
local ui={show=function(_,w) shown[#shown+1]=w end,close=function() end}
local presenter=Presenter.new{ui_manager=ui}
local app=App.new{storage=storage,show=function(view) return presenter:show(view) end}
presenter.app=app
presenter.detail_factory=function(book)
    return {kind="book_detail",book=book,info=book,alternatives={book},alive=true}
end
local function last() return shown[#shown] end
local function action(name, field)
    for _,item in ipairs(last()[field or "actions"] or {}) do if (item.text or item.title)==name then return item.callback() end end
    error("missing action "..name)
end
local home=app:openHome()
eq("bookshelf",home.kind,"home opens the whole shelf including unread books")
eq("shelf_hero",last().mode,"first shelf page has a recent-reading hero")
eq(true,last().brand_logo,"the actual bookshelf page requests the plugin logo")
eq(5,#last().items,"first shelf page has one hero and four covers")
eq("完整简介1",last().items[1].intro,"recent-reading hero keeps the book summary")
eq("继续阅读",last().hero_action.text,"recent-reading hero has a direct continue-reading action")
eq(nil,last().items[2].intro,"smaller cover cards omit the summary")
eq(3,last().page_count,"screen sees true storage page count")
eq(0,#last().categories,"category controls live in shelf management")
eq(4,#last().actions,"shelf exposes four functional groups")
eq(0,#last().navigation,"the footer does not duplicate destinations")
last().on_next()
eq(2,last().page,"next page indicator advances")
eq(true,last().brand_logo,"later bookshelf pages retain the logo")
eq("grid",last().mode,"later shelf pages use a twelve-cover grid")
eq(12,#last().items,"later shelf pages contain twelve covers")
eq("b6",last().items[1].book.id,"second shelf page follows the four homepage covers")
last().items[1].callback()
eq("detail",last().mode,"grid tap opens independent book detail")
eq("完整简介6",last().items[1].intro,"detail receives full introduction")
last():onClose()
eq(2,last().page,"return restores shelf page")
action("整理书架")
action("分类","items")
action("玄幻","items")
eq(1,last().page,"category switch resets to first page")
eq(2,last().page_count,"category page count reaches screen")
last().on_next()
eq("b11",last().items[1].book.id,"filtered second page starts after the homepage covers")
action("书源与下载")
eq("shelf_sources",last().subpage,"source and download controls share a page")
eq(nil,last().brand_logo,"a shelf subpage does not inherit the main shelf logo")
local has_sources=false
for _,item in ipairs(last().items) do if item.text=="书源管理" then has_sources=true end end
eq(true,has_sources,"source management remains reachable through its group")
last():onClose()
eq("b11",last().items[1].book.id,"source group return preserves filtered page")
books={}
app:openHome()
eq(0,#last().items,"empty shelf does not manufacture a book tile")
eq("找书",last().actions[1].text,"empty shelf keeps the grouped search action")
last().header_action.callback()
eq("本地书架",last().title,"header switches to the local shelf")
eq(true,last().brand_logo,"the local bookshelf also carries the logo")
last().header_action.callback()
local failing_detail={kind="book_detail",book={id="failure",name="失败的书"},info={},alternatives={},
    startReading=function(_,callback)
        callback(nil,{code="STORAGE_ERROR",details={stage="reader_open",cause="https://user:secret@private.test"}})
        return {}
    end}
presenter:show(failing_detail)
action("开始阅读")
eq(true,last().subtitle:find("打开阅读器",1,true)~=nil,"reading failure identifies its real stage")
action("更多")
action("阅读诊断","items")
eq(true,last().text:find("打开阅读器",1,true)~=nil,"diagnostic explains reader entry failure")
eq(nil,last().text:find("secret",1,true),"reading diagnostic never exposes raw exception credentials")
for _,message in ipairs({"书源不存在","阅读功能尚未初始化"}) do
    failing_detail.startReading=function() return message end
    presenter:show(failing_detail)
    action("开始阅读")
    eq(true,last().subtitle:find(message,1,true)~=nil,"known reading failures retain their reason")
    action("更多")
    action("阅读诊断","items")
    eq(true,last().text:find(message,1,true)~=nil,"known failure provides actionable diagnostics")
end
failing_detail.startReading=function() return "https://user:secret@private.test" end
presenter:show(failing_detail)
action("开始阅读")
action("更多")
action("阅读诊断","items")
eq(nil,last().text:find("secret",1,true),"unknown string failures remain private")

-- Batch category editing applies one saved category to every selected book.
do
    local batch_books = {
        {id="batch-1", name="批量一", author="作者一"},
        {id="batch-2", name="批量二", author="作者二"},
    }
    local saved_batches, batch_fail = {}, true
    local batch_settings = { shelf_categories = {"待读"} }
    local batch_storage = {
        listShelf=function() return batch_books end,
        getProgress=function() end,
        updateBooks=function(_, values)
            if batch_fail then return nil, {code="STORAGE_ERROR"} end
            saved_batches = values
            for _, value in ipairs(values) do
                for _, book in ipairs(batch_books) do if book.id == value.id then for key, field in pairs(value) do book[key] = field end end end
            end
            return true
        end,
    }
    local batch_settings_api = {
        get=function(_, key) return batch_settings[key] end,
        set=function(_, key, value) batch_settings[key] = value; return true end,
    }
    local batch_shown = {}
    local batch_ui = {show=function(_, widget) batch_shown[#batch_shown+1] = widget end, close=function() end}
    local batch_presenter = Presenter.new{ui_manager=batch_ui}
    local batch_app = App.new{storage=batch_storage, settings=batch_settings_api, show=function(view) return batch_presenter:show(view) end}
    batch_presenter.app = batch_app
    local function batch_last() return batch_shown[#batch_shown] end
    local function batch_action(name, field)
        for _, item in ipairs(batch_last()[field or "actions"] or {}) do
            if (item.text or item.title) == name then return item.callback() end
        end
        error("missing batch action " .. name)
    end
    batch_app:openBookshelf()
    batch_action("整理书架")
    batch_action("批量选择", "items")
    eq(true, batch_last().batch_select, "batch mode is visible on the shelf")
    batch_last().items[1].callback()
    batch_last().items[2].callback()
    eq(true, batch_last().selected_books["batch-1"], "first book is selected")
    eq(true, batch_last().selected_books["batch-2"], "second book is selected")
    batch_action("整理书架")
    batch_action("批量分类", "items")
    eq("□ 待读", batch_last().item_table[2].text, "batch category shows unchecked state")
    local category_action = batch_last().item_table[2].callback
    category_action()
    eq(nil, batch_books[1].custom_categories, "failed batch save keeps first book unchanged")
    eq(nil, batch_books[2].custom_categories, "failed batch save keeps second book unchanged")
    batch_fail = false
    category_action()
    eq(2, #saved_batches, "batch category writes both selected books once")
    eq("待读", saved_batches[1].custom_categories[1], "first selected book receives category")
    eq("待读", saved_batches[2].custom_categories[1], "second selected book receives category")
    eq("✓ 待读", batch_last().item_table[2].text, "saved batch category shows checked state")
end
local receive
local updating={kind="book_detail",book={id="late",name="更新中的书",intro="旧简介"},alternatives={},alive=true,
    loadInfo=function(self,callback) receive=function() self.info={id="late",name="更新中的书",intro="新完整简介"}; callback(self.info) end end}
presenter:show(updating)
action("更多")
receive()
eq("more",last().subpage,"late metadata does not eject secondary menu")
last():onClose()
eq("新完整简介",last().items[1].intro,"return from secondary menu rebuilds latest detail metadata")
return count
