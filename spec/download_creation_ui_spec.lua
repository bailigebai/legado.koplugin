require("library_screen_stub")
local A = require("assertions")
local Catalog = require("legado.ui.catalog")
local Downloads = require("legado.ui.downloads")
local Presenter = require("legado.ui.presenter")
local App = require("legado.ui.app")

local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local function truthy(actual, message) count = count + 1; A.truthy(actual, message) end
local function item(items, label)
    for _, entry in ipairs(items or {}) do if entry.text == label then return entry end end
end

local source_book = { id = "source-book", source_id = "source-1", name = "在线书" }
local tasks, calls, shown = {}, {}, {}
local detail
local app = {
    storage = { listShelf = function() return { source_book,
        { id = "local-book", source_id = "local", name = "本地书", is_local = true },
        { id = "local-legacy", source_id = "local", name = "旧本地书" },
        { id = "wechat-book", source_id = "weread", name = "微信书" } } end },
    createBookDetail = function(_, book)
        detail = { kind = "book_detail", book = book, alive = true,
            startCache = function(_, ending)
                calls[#calls + 1] = ending or "whole"
                local task = { id = "task-" .. #calls, kind = "cache", book = book,
                    status = "queued", end_index = ending }
                tasks[#tasks + 1] = task
                return task
            end,
            startDownload = function() return { id = "export", status = "queued" } end,
            loadCatalog = function(_, callback)
                local chapters = {}
                for index = 1, 45 do chapters[index] = { index = index, title = "第" .. index .. "章" } end
                callback(Catalog.new(chapters), nil)
                return true
            end,
            close = function(self) self.alive = false end,
        }
        return detail
    end,
}
local presenter = Presenter.new({ app = app,
    menu = { new = function(_, options) return options end },
    input_dialog = { new = function(_, options) return options end },
    ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end,
        close = function() end } })
local view = Downloads.new({ manager = { list = function() return tasks end } })
presenter:show(view)
truthy(item(shown[#shown].item_table, "新建缓存任务"), "download management can create a cache task")
item(shown[#shown].item_table, "新建缓存任务").callback()
eq("选择要缓存的书籍", shown[#shown].title, "cache creation starts with a book picker")
eq(1, #shown[#shown].item_table, "picker excludes local files and WeRead books")
shown[#shown].item_table[1].callback()
truthy(item(shown[#shown].item_table, "缓存整本（离线阅读）"), "selected source book offers full cache")
truthy(item(shown[#shown].item_table, "缓存部分章节"), "selected source book offers partial cache")
item(shown[#shown].item_table, "缓存整本（离线阅读）").callback()
eq("whole", calls[1], "full cache queues the entire source book")
eq("下载管理", shown[#shown].title, "queued full cache returns to live downloads")

item(shown[#shown].item_table, "新建缓存任务").callback()
shown[#shown].item_table[1].callback()
item(shown[#shown].item_table, "缓存部分章节").callback()
eq("选择缓存截至章节", shown[#shown].title, "partial cache opens the existing chapter selector")
local jump = item(shown[#shown].actions, "跳转章节")
truthy(jump, "partial cache can jump directly to an ending chapter")
jump.callback()
shown[#shown].buttons[1][2].callback("37")
shown[#shown].items[7].callback()
eq(37, calls[2], "partial cache queues chapters 1 through the selected ending")
eq("下载管理", shown[#shown].title, "queued partial cache returns to live downloads")
eq(2, #tasks, "both cache tasks remain visible in one download manager")

item(shown[#shown].item_table, "新建缓存任务").callback()
shown[#shown].item_table[1].callback()
item(shown[#shown].item_table, "缓存部分章节").callback()
local stale_catalog_menu = shown[#shown]
stale_catalog_menu.on_back()
eq("选择要缓存的书籍", shown[#shown].title, "back from the catalog returns to the book picker")
eq(nil, presenter.library_view, "leaving the catalog clears the old library page")
stale_catalog_menu.items[1].callback()
eq(2, #calls, "a stale chapter tap after back cannot queue another cache task")

shown[#shown].item_table[1].callback()
local late_catalog
detail.loadCatalog = function(_, callback) late_catalog = callback; return { cancel = function() end } end
item(shown[#shown].item_table, "缓存部分章节").callback()
eq("正在加载目录…", shown[#shown].empty_text, "asynchronous catalog shows loading state")
shown[#shown].on_back()
late_catalog(Catalog.new({ { index = 1, title = "迟到章节" } }), nil)
eq("选择要缓存的书籍", shown[#shown].title, "late catalog response cannot reopen selection after back")
eq(nil, presenter.library_view, "late catalog response leaves the picker context clean")

shown[#shown].item_table[1].callback()
detail.loadCatalog = function() return nil end
item(shown[#shown].item_table, "缓存部分章节").callback()
eq("下载管理", shown[#shown].title, "unavailable catalog shows a download error")
eq(true, view.alive, "unavailable catalog keeps the task manager usable")

do
    local direct_shown, returned = {}, 0
    local direct_presenter
    local direct_app = App.new({ storage = app.storage,
        download_manager = { list = function() return {} end },
        show = function(page) return direct_presenter:show(page) end })
    direct_presenter = Presenter.new({ app = direct_app,
        menu = { new = function(_, options) return options end },
        ui_manager = { show = function(_, widget) direct_shown[#direct_shown + 1] = widget end,
            close = function() end } })
    local direct_view = direct_app:openDownloads(function() returned = returned + 1 end, true)
    eq(true, direct_view.start_picker, "shelf cache shortcut opens directly in the book picker")
    eq("选择要缓存的书籍", direct_shown[#direct_shown].title, "direct cache entry skips the task list")
    direct_shown[#direct_shown].close_callback()
    eq(1, returned, "back from the direct picker restores the originating shelf")
    eq(false, direct_view.alive, "back from the direct picker closes download refresh state")
end

return count
