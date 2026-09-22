require("library_screen_stub")
local A = require("assertions")
local Shelf = require("legado.ui.bookshelf")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(a,b,message) count=count+1; A.equal(a,b,message) end
local books = {}
for i=1,27 do books[i]={id="b"..i,name="书"..i,kind=i%2==1 and "玄幻" or "科幻",intro="完整简介"..i} end
local storage = {listShelf=function() return books end,
    getProgress=function(_,id) if tonumber(id:sub(2))<=5 then return {fraction=0.2} end end}
local shelf = Shelf.new{storage=storage}
local first = shelf:page(1,"cover")
eq(12,#first.items,"cover shelf holds twelve books")
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
eq("grid",last().mode,"shelf uses covers and titles")
eq(12,#last().items,"presenter sends twelve grid items")
eq(nil,last().items[1].intro,"grid omits intro while retaining book metadata")
eq(3,last().page_count,"screen sees true storage page count")
eq(4,#last().categories,"top controls expose reading state and genre selection")
eq(2,#last().actions,"secondary actions collapse behind More")
eq(3,#last().navigation,"only three main destinations occupy the footer")
last().on_next()
eq(2,last().page,"next page indicator advances")
eq("b13",last().items[1].book.id,"screen next page shows next twelve books")
last().items[1].callback()
eq("detail",last().mode,"grid tap opens independent book detail")
eq("完整简介13",last().items[1].intro,"detail receives full introduction")
last():onClose()
eq(2,last().page,"return restores shelf page")
action("分类","categories")
action("玄幻","items")
eq(1,last().page,"category switch resets to first page")
eq(2,last().page_count,"category page count reaches screen")
last().on_next()
eq("b25",last().items[1].book.id,"filtered second page retains book25")
action("更多")
eq("more",last().subpage,"secondary controls have their own page")
local has_sources=false
for _,item in ipairs(last().items) do if item.text=="书源管理" then has_sources=true end end
eq(true,has_sources,"source management remains reachable through More")
last():onClose()
eq("b25",last().items[1].book.id,"More return preserves filtered page")
books={}
app:openHome()
eq(0,#last().items,"empty shelf does not manufacture a book tile")
eq("搜索添加",last().actions[1].text,"empty shelf keeps search action")
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
    local saved_batches, batch_settings = {}, { shelf_categories = {"待读"} }
    local batch_storage = {
        listShelf=function() return batch_books end,
        getProgress=function() end,
        updateBooks=function(_, values)
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
    batch_action("更多")
    batch_action("批量选择", "items")
    eq(true, batch_last().batch_select, "batch mode is visible on the shelf")
    batch_last().items[1].callback()
    batch_last().items[2].callback()
    eq(true, batch_last().selected_books["batch-1"], "first book is selected")
    eq(true, batch_last().selected_books["batch-2"], "second book is selected")
    batch_action("更多")
    batch_action("批量分类", "items")
    batch_action("待读", "item_table")
    eq(2, #saved_batches, "batch category writes both selected books once")
    eq("待读", saved_batches[1].custom_categories[1], "first selected book receives category")
    eq("待读", saved_batches[2].custom_categories[1], "second selected book receives category")
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
