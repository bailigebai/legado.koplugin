require("library_screen_stub")
local assertx = require("assertions")
local Presenter = require("legado.ui.presenter")

local shown = {}
local ui = { show = function(_, widget) shown[#shown + 1] = widget end, close = function() end }
local Menu = { new = function(_, options) options.widget_type = "menu"; return options end }
local Info = { new = function(_, options) options.widget_type = "info"; return options end }
local Input = { new = function(_, options) options.widget_type = "input"; return options end }
local presenter = Presenter.new({
    ui_manager = ui, menu = Menu, info_message = Info, input_dialog = Input,
    cover_grid_factory = function(options) return { kind = "cover_grid", options = options } end,
})

local catalog_items = {}
for index = 1, 16 do catalog_items[index] = { index = index, title = "Chapter " .. index, position = index } end
local catalog_presenter = Presenter.new({
    ui_manager = ui,
    library_screen_factory = function(options) options.kind = "library_screen"; return options end,
})
local catalog_widget = catalog_presenter:show({
    kind = "catalog", items = catalog_items, current_index = 1, catalog_complete = true,
    setOrder = function() end,
})
assertx.equal(15, #catalog_widget.items, "catalog details show fifteen chapters per page")
assertx.equal(2, catalog_widget.page_count, "catalog details expose a second page after fifteen chapters")
assertx.equal("function", type(catalog_widget.on_next), "catalog details expose next-page navigation")
catalog_widget.on_next()
assertx.equal(1, #shown[#shown].items, "catalog second page contains the remaining chapter")

local home = {
    kind = "home",
    page = function() return {
        kind = "home", recent = { { name = "Recent", author = "Author", id = "recent" } },
        actions = { { text = "书架", callback = function() end } },
    } end,
}
local home_widget = presenter:show(home)
assertx.equal("library_screen",home_widget.kind,"home uses standalone fullscreen browser")
assertx.equal("Recent",home_widget.items[1].title,"home shows recent book cards")
assertx.equal("书架",home_widget.navigation[1].text,"home keeps primary navigation")
local shelf={kind="bookshelf",page=function(_,page)
    return {page=page,page_count=2,items={{title="Book",book={name="Book",author="Author"}}}}
end}
local shelf_widget=presenter:show(shelf)
assertx.equal("grid",shelf_widget.mode,"shelf uses a compact cover grid")
assertx.equal(nil,shelf_widget.items[1].subtitle,"shelf grid leaves author for book details")
assertx.equal("function",type(shelf_widget.on_next),"shelf exposes pagination")
shelf_widget.on_next()
assertx.equal("function",type(shown[#shown].on_prev),"second page can go back")
local calls={}
local search={kind="search",alive=true,loading=false,results={},errors={},
    sourceChoices=function() error("automatic search must not ask for a source") end,
    submit=function(self,keyword,ids,page) self.keyword=keyword; self.loading=true; calls={keyword,ids,page} end}
local input=presenter:show(search)
input.buttons[1][2].callback("query")
assertx.equal("query",calls[1],"search submits book name")
assertx.equal(nil,calls[2],"search uses all enabled sources automatically")
assertx.equal("library_screen",shown[#shown].kind,"search opens standalone results immediately")
assertx.truthy(shown[#shown].subtitle:find("搜索中",1,true),"loading progress is visible")

local settings = { kind = "settings", values = { timeout = 20, concurrency = 2, prefetch = 3, shelf_page = 20 }, actions = { { text = "阅读外观", callback = function() return true end } } }
local settings_widget = presenter:show(settings)
assertx.equal("menu", settings_widget.widget_type, "settings renders native action menu")
assertx.equal("请求超时：20 秒", settings_widget.item_table[1].text, "settings display the active timeout default")
assertx.equal("并发书源：2", settings_widget.item_table[2].text, "settings display concurrency")
assertx.equal("预取章节：3", settings_widget.item_table[3].text, "settings display prefetch")
assertx.equal("书架布局：每页 4 × 3 本", settings_widget.item_table[4].text, "settings describe the fixed grid")
assertx.equal("阅读外观", settings_widget.item_table[#settings_widget.item_table].text, "native appearance action remains visible after reading and shelf settings")

local source_view = {
    kind = "source_manager",
    list = function() return { { id = "s1", bookSourceName = "Alpha", bookSourceGroup = "G", enabled = true } } end,
    toggle = function() return false end,
    compatibility = function() return { status = "usable", issues = {} } end,
    update = function(_, _, callback) callback({ updated = 1 }, nil); return { cancel = function() return true end } end,
    delete = function() return true end,
    importLocal = function() return { imported = 1 } end,
    importUrl = function(_, _, callback) callback({ imported = 1, warnings = { { code = "INSECURE_ORIGIN" } } }, nil); return { cancel = function() return true end } end,
}
local sources_widget = presenter:show(source_view)
assertx.equal("Alpha",sources_widget.items[1].title,"source name has a dedicated label")
assertx.equal("收藏 0 · 已启用 · G",sources_widget.items[1].subtitle,"source list displays zero shelf count, group and status")
assertx.equal("从本地 JSON 导入", sources_widget.item_table[2].text, "source manager exposes local import")
assertx.equal("更多", sources_widget.item_table[3].text, "source manager groups secondary import actions")
local source_more = sources_widget.item_table[3].callback()
assertx.equal("从网址导入",source_more.items[1].text,"URL import is reachable through More")
sources_widget.item_table[1].callback()
local source_actions = shown[#shown]
assertx.equal("兼容性报告", source_actions.item_table[2].text, "source actions expose compatibility report")
assertx.equal("更新书源", source_actions.item_table[3].text, "source actions expose update")
assertx.equal("删除书源", source_actions.item_table[4].text, "source actions expose confirmed deletion")
source_more.items[1].callback()
local url_dialog = shown[#shown]
url_dialog.buttons[1][2].callback("http://sources.test/list.json")
local insecure_notice = shown[#shown]
assertx.truthy(insecure_notice.text:find("不安全", 1, true), "HTTP import warning is shown instead of a generic success")

local info_callback, info_loads = nil, 0
local detail_closed = 0
local detail_view = {
    kind = "book_detail", book = { name = "Book" }, alternatives = { { source_name = "A" }, { source_name = "B" } },
    startReading = function() return "阅读占位" end, startDownload = function() return "下载占位" end,
    addToShelf = function() return true end, removeFromShelf = function() return true end,
    loadCatalog = function(_, callback) callback({ kind = "catalog", items = {} }, nil); return { cancel = function() return true end } end,
    loadInfo = function(_, callback) info_loads = info_loads + 1; info_callback = callback; return { cancel = function() return true end } end,
    switchSource = function(self, index) self.info = nil; return index end,
    close = function() detail_closed = detail_closed + 1 end,
}
local detail_widget = presenter:show(detail_view)
assertx.equal(1, info_loads, "book detail starts the real getBookInfo flow")
assertx.equal("detail",detail_widget.mode,"book detail owns a full screen")
detail_view.info={author="Writer",intro="Introduction",kind="Novel",last_chapter="Chapter 9"}
info_callback(detail_view.info,nil)
local loaded_detail=shown[#shown]
assertx.equal("Writer · Novel · Chapter 9",loaded_detail.items[1].subtitle,"detail includes author, category and latest chapter")
assertx.equal("Introduction",loaded_detail.items[1].intro,"detail shows introduction")
local actions={}
loaded_detail.actions[2].callback()
for _,action in ipairs(shown[#shown].items) do actions[action.text]=action end
assertx.truthy(actions["查看目录"],"detail exposes catalog")
assertx.truthy(actions["下载整本"],"detail exposes download")
presenter.app={openReaderSourceSites=function(_,_,_,detail)
    assertx.equal(detail_view,detail,'site switch targets the current detail book')
    detail:switchSource(2);detail._presenter_info_started=nil
    return presenter:_detail(detail)
end,openBookshelf=function() end}
actions["切换站点书源"].callback()
assertx.equal(2,info_loads,"switching source starts fresh metadata request")
shown[#shown]:onClose()
assertx.equal(1,detail_closed,"closing detail reaches its controller")

local about = presenter:show({ kind = "about", title = "关于", text = "安全说明" })
assertx.equal("info", about.widget_type, "about renders native information message")
assertx.equal("安全说明", about.text, "about content is visible")
assertx.truthy(#shown>0,"presented views reach UIManager")

return 44
