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

local shelf = {
    kind = "bookshelf",
    page = function(_, page, mode)
        return { page = page, page_count = 2, mode = mode, items = {
            { title = "Book", subtitle = "Author", cover_text = "无封面", book = { id = "b1" } },
        } }
    end,
}
local shelf_widget = presenter:show(shelf)
assertx.equal("menu", shelf_widget.widget_type, "shelf renders with a native KOReader menu")
assertx.equal("Book — Author", shelf_widget.item_table[1].text, "shelf text is e-ink friendly")
assertx.equal("上一页", shelf_widget.item_table[2].text, "shelf exposes touch pagination")
assertx.equal("下一页", shelf_widget.item_table[3].text, "shelf exposes next-page action")
shelf_widget.item_table[4].callback()
local cover_widget = shown[#shown]
assertx.equal("cover_grid", cover_widget.kind, "cover mode renders the dedicated three-column widget")
assertx.equal("cover", cover_widget.options.model.mode, "cover widget receives the paginated cover model")

local search_calls = {}
local search = {
    kind = "search",
    submit = function(_, keyword, ids, page) search_calls[#search_calls + 1] = { keyword, ids, page }; return true end,
}
local input = presenter:show(search)
assertx.equal("input", input.widget_type, "search opens a native input dialog")
assertx.equal("搜索书名", input.input_hint, "search input uses a concise Chinese hint")
input.buttons[1][2].callback("query")
assertx.equal("query", search_calls[1][1], "search dialog submits keyword")
assertx.equal(1, search_calls[1][3], "search starts at page one")
local progress_widget = shown[#shown]
assertx.equal("搜索中…", progress_widget.item_table[1].text, "search shows a real progress state")
assertx.equal("取消", progress_widget.item_table[2].text, "search progress exposes cancellation")

local selected_calls = {}
local selectable_search = {
    kind = "search",
    sourceChoices = function() return { { id = "s1", name = "Alpha" } } end,
    submit = function(_, keyword, ids, page) selected_calls[#selected_calls + 1] = { keyword, ids, page }; return true end,
}
local selectable_input = presenter:show(selectable_search)
selectable_input.buttons[1][2].callback("chosen")
local chooser = shown[#shown]
assertx.equal("全部已启用书源", chooser.item_table[1].text, "search can target every enabled source")
assertx.equal("Alpha", chooser.item_table[2].text, "search can target one enabled source")
chooser.item_table[2].callback()
assertx.equal("s1", selected_calls[1][2][1], "single-source selection reaches BookService")

local search_results_closed = 0
local search_results_widget = presenter:_search_results({
    results = {}, errors = {},
    close = function() search_results_closed = search_results_closed + 1 end,
})
assertx.equal("function", type(search_results_widget.close_callback), "native search results close through their controller")
search_results_widget.close_callback()
assertx.equal(1, search_results_closed, "search result close callback reaches the controller")

local settings = { kind = "settings", values = { timeout = 20, concurrency = 2, prefetch = 3, shelf_page = 20 }, actions = { { text = "阅读外观", callback = function() return true end } } }
local settings_widget = presenter:show(settings)
assertx.equal("menu", settings_widget.widget_type, "settings renders native action menu")
assertx.equal("请求超时：20 秒", settings_widget.item_table[1].text, "settings display the active timeout default")
assertx.equal("并发书源：2", settings_widget.item_table[2].text, "settings display concurrency")
assertx.equal("预取章节：3", settings_widget.item_table[3].text, "settings display prefetch")
assertx.equal("每页书籍：20", settings_widget.item_table[4].text, "settings display shelf page size")
assertx.equal("阅读外观", settings_widget.item_table[5].text, "native appearance action is visible")

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
assertx.equal("Alpha · 已启用 · G", sources_widget.item_table[1].text, "source list displays group and status")
assertx.equal("从本地 JSON 导入", sources_widget.item_table[2].text, "source manager exposes local import")
assertx.equal("从网址导入", sources_widget.item_table[3].text, "source manager exposes URL import")
sources_widget.item_table[1].callback()
local source_actions = shown[#shown]
assertx.equal("兼容性报告", source_actions.item_table[2].text, "source actions expose compatibility report")
assertx.equal("更新书源", source_actions.item_table[3].text, "source actions expose update")
assertx.equal("删除书源", source_actions.item_table[4].text, "source actions expose confirmed deletion")
sources_widget.item_table[3].callback()
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
assertx.equal("详情加载中…", detail_widget.item_table[1].text, "book detail displays loading state")
detail_view.info = { author = "Writer", intro = "Introduction", kind = "Novel", last_chapter = "Chapter 9" }
info_callback(detail_view.info, nil)
local loaded_detail = shown[#shown]
assertx.equal("作者：Writer", loaded_detail.item_table[1].text, "book detail displays author")
assertx.equal("简介：Introduction", loaded_detail.item_table[2].text, "book detail displays introduction")
assertx.equal("分类：Novel", loaded_detail.item_table[3].text, "book detail displays category")
assertx.equal("最新章：Chapter 9", loaded_detail.item_table[4].text, "book detail displays latest chapter")
assertx.equal("查看目录", loaded_detail.item_table[8].text, "book detail exposes catalog")
assertx.equal("切换书源", loaded_detail.item_table[9].text, "book detail exposes source switching")
assertx.equal("下载整本", loaded_detail.item_table[10].text, "book detail keeps the Task 8 download hook")
assertx.equal("function", type(loaded_detail.close_callback), "native detail closes through its controller")
loaded_detail.close_callback()
assertx.equal(1, detail_closed, "detail close callback reaches the controller")
loaded_detail.item_table[9].callback()
local source_chooser = shown[#shown]
source_chooser.item_table[2].callback()
assertx.equal(2, info_loads, "switching source starts a fresh book-info request")

local about = presenter:show({ kind = "about", title = "关于", text = "安全说明" })
assertx.equal("info", about.widget_type, "about renders native information message")
assertx.equal("安全说明", about.text, "about content is visible")
assertx.equal(18, #shown, "presented views and source actions use UIManager")

return 43
