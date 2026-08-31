local assertx = require("assertions")
local Shelf = require("legado.ui.bookshelf")
local Navigation = require("legado.ui.navigation")
local SearchView = require("legado.ui.search")
local SourceManager = require("legado.ui.source_manager")
local App = require("legado.ui.app")
local BookDetail = require("legado.ui.book_detail")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local state = { books = {}, sources = {} }
local storage = {}
function storage:listShelf() local result = {}; for _, value in pairs(state.books) do result[#result + 1] = value end; table.sort(result, function(a,b) return a.name < b.name end); return result end
function storage:createBook(book) state.books[book.id] = book; return book end
function storage:deleteBook(id) state.books[id] = nil; return true end
function storage:getBook(id) return state.books[id] end
function storage:listSources() return state.sources end
function storage:getSource(id) for _, source in ipairs(state.sources) do if source.id == id then return source end end end
function storage:updateSource(id, patch) local source = self:getSource(id); for k,v in pairs(patch) do source[k]=v end; return source end
function storage:deleteSource(id) for i, source in ipairs(state.sources) do if source.id == id then table.remove(state.sources, i); return true end end end

do
    local shelf = Shelf.new({ storage = storage, page_size = 20, covers_enabled = true })
    local empty = shelf:page(1, "text")
    equal("书架为空", empty.empty_text, "empty shelf has useful Chinese state")
    for index = 1, 41 do shelf:add({ id = string.format("b%02d", index), name = string.format("Book %02d", index), author = "A", cover_url = index == 2 and "https://covers.test/2.jpg" or nil }) end
    local first = shelf:page(1, "text")
    local third = shelf:page(3, "text")
    equal(20, #first.items, "text shelf defaults to twenty items")
    equal(3, third.page_count, "shelf computes page count")
    equal(1, #third.items, "last shelf page contains remainder")
    equal("Book 41", third.items[1].title, "text shelf preserves deterministic order")
    local cover = shelf:page(1, "cover")
    equal("无封面", cover.items[1].cover_text, "missing cover has nonblocking text fallback")
    truthy(cover.items[1].cover_pending == false, "missing URL does not schedule cover loading")
    equal("封面不可用", cover.items[2].cover_text, "unavailable cover loader falls back without blocking")
    truthy(cover.items[2].cover_pending == false, "cover URL cannot remain pending without a loader")
    equal(true, shelf:remove("b01"), "shelf removal delegates to storage")
    equal(nil, storage:getBook("b01"), "removed book leaves shelf")
end

do
    local catalog_callback
    local alternatives = { { id = "a-book", source_ref = "s1", name = "Book" }, { id = "b-book", source_ref = "s2", name = "Book" } }
    local detail = BookDetail.new({
        book = alternatives[1], alternatives = alternatives,
        source_lookup = function(id) return { id = id } end,
        service = { getChapters = function(_, source, book, callback) catalog_callback = callback; return { cancel = function() return true end } end },
    })
    equal("b-book", detail:switchSource(2).id, "detail source switch selects the alternative identity")
    detail:loadCatalog(function() end)
    equal(true, detail.loading_catalog, "catalog exposes a nonblocking loading state")
    detail:close()
    catalog_callback({ { index = 1, title = "Late" } }, nil)
    equal(nil, detail.catalog, "closed detail ignores a late catalog callback")
end

do
    local nav = Navigation.new({ count = 4, columns = 2 })
    equal(1, nav:index(), "focus starts at first item")
    equal(true, nav:onKey("Right"), "right key is handled")
    equal(2, nav:index(), "right advances focus")
    nav:onKey("Down"); equal(4, nav:index(), "down advances by columns")
    nav:onKey("Left"); equal(3, nav:index(), "left moves focus")
    nav:onKey("Up"); equal(1, nav:index(), "up moves focus by columns")
    equal(true, nav:onKey("LPgFwd"), "Kindle page-forward key is supported")
    equal(2, nav:index(), "page-forward advances focus")
end

do
    local pending_callback
    local view = SearchView.new({ service = { search = function(_, _, _, _, callback) pending_callback = callback; return { cancel = function() return true end } end } })
    view:submit("query", nil, 1)
    equal(true, view.loading, "search view exposes progress state")
    view:close()
    pending_callback({ groups = { { book = { name = "Late" } } }, errors = {} }, nil)
    equal(0, #view.results, "closed view ignores late callback")
end


do
    state.sources = {
        { id = "s1", bookSourceName = "Alpha", bookSourceGroup = "G", enabled = true },
        { id = "s2", bookSourceName = "Beta", bookSourceGroup = "G", enabled = false },
    }
    local importer_calls = {}
    local manager = SourceManager.new({
        storage = storage,
        importer = { importJson = function(_, text, origin) importer_calls[#importer_calls + 1] = { text, origin }; return { imported = 1, rejected = 0 } end },
        fs = { read = function(_, path) return path == "sources.json" and "{}" or nil end },
        scanner = { scan = function() return { status = "usable", issues = {} } end },
        confirm = function() return true end,
    })
    equal(2, #manager:list(), "source manager lists sources")
    equal(false, manager:toggle("s1"), "source manager disables enabled source")
    equal(true, assert(manager:toggle("s1")), "source manager enables disabled source")
    equal(1, manager:importLocal("sources.json").imported, "local JSON import is supported")
    equal("sources.json", importer_calls[1][2], "local import origin is retained")
    equal("usable", manager:compatibility("s1").status, "compatibility report is exposed")
    equal(true, manager:delete("s2"), "confirmed source deletion succeeds")

    state.sources[#state.sources + 1] = { id = "s3", bookSourceName = "Async", enabled = true }
    local confirm_action
    local async_manager = SourceManager.new({
        storage = storage, importer = manager.importer, fs = manager.fs, scanner = manager.scanner,
        confirm = function(_, accepted) confirm_action = accepted; return "pending" end,
    })
    equal("pending", async_manager:delete("s3"), "native asynchronous confirmation remains pending")
    truthy(storage:getSource("s3"), "pending confirmation does not delete early")
    confirm_action()
    equal(nil, storage:getSource("s3"), "confirmation callback performs deletion")

    state.sources[#state.sources + 1] = { id = "s4", bookSourceName = "Local", enabled = true, import_origin = "sources.json" }
    local local_update
    async_manager:update("s4", function(result, err) assert(not err); local_update = result end)
    equal(1, local_update.imported, "locally imported sources update from their retained file origin")
end

do
    local appearance_opened = 0
    local app = App.new({
        storage = storage,
        appearance = function() appearance_opened = appearance_opened + 1; return true end,
        download_hook = function() return "下载功能将在下一阶段提供" end,
        reading_hook = function() return "阅读功能将在下一阶段提供" end,
    })
    local menu = app:menuItems()
    local labels = {}; for _, item in ipairs(menu) do labels[#labels + 1] = item.text end
    equal("书架", labels[1], "main menu starts with shelf")
    equal("搜索", labels[2], "main menu includes search")
    equal("书源管理", labels[3], "main menu includes source manager")
    equal("下载管理", labels[4], "main menu includes download manager")
    equal("设置", labels[5], "main menu includes settings")
    equal("关于", labels[6], "main menu includes about")
    local settings = app:openSettings()
    equal("阅读外观", settings.actions[1].text, "settings expose KOReader native appearance action")
    settings.actions[1].callback()
    equal(1, appearance_opened, "appearance action delegates to KOReader")
    equal("阅读功能将在下一阶段提供", app:startReading({}), "reading is an explicit Task 7 hook")
    equal("下载功能将在下一阶段提供", app:startDownload({}), "download is an explicit Task 8 hook")
end

return count
