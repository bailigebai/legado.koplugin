local assertx = require("assertions")
local Presenter = require("legado.ui.presenter")
local SourceManager = require("legado.ui.source_manager")
local App = require("legado.ui.app")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end

local shown, closed, events = {}, {}, {}
local ui = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function(_, widget) closed[#closed + 1] = widget; events[#events + 1] = "close:" .. tostring(widget.title) end,
}
local function widget(kind)
    return { new = function(_, options)
        options.widget_type = kind
        if kind == "input" then
            options.keyboard_calls = 0
            options.onShowKeyboard = function(self) self.keyboard_calls = self.keyboard_calls + 1; events[#events + 1] = "keyboard:" .. tostring(self.title) end
        end
        return options
    end }
end
local presenter = Presenter.new({ ui_manager = ui, menu = widget("menu"), info_message = widget("info"), input_dialog = widget("input") })

local function choose(menu, item)
    item.callback()
    menu.close_callback()
end

local shelf_closes = 0
local shelf = {
    kind = "bookshelf",
    page = function() return { page = 1, page_count = 1, mode = "text", items = { { title = "Book", book = { id = "b1" } } } } end,
    close = function() shelf_closes = shelf_closes + 1 end,
}
local shelf_menu = presenter:show(shelf)
choose(shelf_menu, shelf_menu.item_table[1])
equal(0, shelf_closes, "selecting a shelf book preserves its reusable model")
shelf_menu.close_callback()
equal(1, shelf_closes, "physical shelf close destroys its model")

local results_closes = 0
local results = presenter:_search_results({
    results = { { book = { name = "Book", author = "A" }, alternatives = { { id = "b1" } } } }, errors = {},
    close = function() results_closes = results_closes + 1 end,
})
choose(results, results.item_table[1])
equal(0, results_closes, "selecting a search result preserves its model")
results.close_callback()
equal(1, results_closes, "physical search-results close destroys its model")

-- KOReader Menu:onMenuSelect calls callback and then close_callback. Selection must not destroy the model.
local source_closes, url_calls = 0, 0
local source_view = {
    kind = "source_manager", list = function() return {} end,
    close = function() source_closes = source_closes + 1; return true end,
    importLocal = function() return { imported = 1 } end,
    importUrl = function(_, url, callback)
        events[#events + 1] = "import:" .. url
        url_calls = url_calls + 1
        callback({ imported = 1, warnings = {} }, nil)
        return { cancel = function() return true end }
    end,
}
local sources = presenter:show(source_view)
choose(sources, sources.item_table[3])
equal(0, source_closes, "selecting URL import does not close the source model")
local url_dialog = shown[#shown]
equal(1, url_dialog.keyboard_calls, "URL import shows the input keyboard exactly once")
url_dialog.buttons[1][2].callback("https://sources.test/list.json")
equal("close:导入书源", events[#events - 1], "valid URL closes its dialog before import starts")
equal("import:https://sources.test/list.json", events[#events], "URL import starts after dialog close")
equal(1, url_calls, "URL import callback remains usable after menu selection")
equal(1, #closed, "valid URL closes its input widget exactly once")
sources.close_callback()
equal(1, source_closes, "physical source-menu close destroys the model once")
sources.close_callback()
equal(1, source_closes, "repeated physical close is idempotent")

local diagnostic_closes, diagnostic_runs = 0, 0
local diagnostic_view = {
    kind = "compatibility_report", status = "usable", capabilities = {}, issues = {}, diagnostics = {},
    close = function() diagnostic_closes = diagnostic_closes + 1; return true end,
    run = function(_, _, callback) diagnostic_runs = diagnostic_runs + 1; callback({ status = "completed", steps = {} }); return { cancel = function() end } end,
}
local compatibility = presenter:show(diagnostic_view)
choose(compatibility, compatibility.item_table[#compatibility.item_table])
equal(0, diagnostic_closes, "selecting diagnostics does not close the report model")
local diagnostic_dialog = shown[#shown]
equal(1, diagnostic_dialog.keyboard_calls, "diagnostics shows the keyboard exactly once")
diagnostic_dialog.buttons[1][2].callback("probe")
equal(1, diagnostic_runs, "diagnostics starts after a valid input")

local catalog_cancelled, detail_closes = 0, 0
local detail_view = {
    kind = "book_detail", book = { name = "Book" }, alternatives = {}, info = { author = "A" },
    startReading = function() return "ok" end, startDownload = function() return "ok" end,
    addToShelf = function() return true end, removeFromShelf = function() return true end,
    loadCatalog = function(_, callback)
        return { cancel = function() catalog_cancelled = catalog_cancelled + 1 end }
    end,
    close = function() detail_closes = detail_closes + 1; catalog_cancelled = catalog_cancelled + 1; return true end,
}
local detail = presenter:show(detail_view)
local catalog_item
for _, item in ipairs(detail.item_table) do if item.text == "查看目录" then catalog_item = item end end
choose(detail, catalog_item)
equal(0, detail_closes, "selecting catalog does not close the detail model")
equal(0, catalog_cancelled, "catalog request survives the selection close callback")
detail.close_callback()
equal(1, detail_closes, "physical detail close reaches the model")

local download_closes, opened = 0, 0
local download_view = {
    kind = "downloads", alive = true,
    items = { { text = "Book · 完成", task = { id = "d1", status = "completed" } } },
    refresh = function(self) return self.items end,
    open = function(_, id) opened = opened + 1; return id == "d1" end,
    close = function() download_closes = download_closes + 1; return true end,
}
local downloads = presenter:show(download_view)
choose(downloads, downloads.item_table[1])
equal(0, download_closes, "selecting a download row does not close the downloads model")
local download_actions = shown[#shown]
download_actions.item_table[1].callback()
equal(1, opened, "download action still reaches the manager-backed view")
download_view.items = { { text = "Book 2 · 完成", task = { id = "d2", status = "completed" } } }
download_view.on_refresh(download_view)
choose(downloads, downloads.item_table[1])
equal(0, download_closes, "refreshed download rows retain selection lifecycle protection")
downloads.close_callback()
equal(1, download_closes, "physical downloads close reaches the model")

-- InputDialog contract: show first, keyboard once, and close exactly once on cancel/valid submit.
local search_closes, submits = 0, 0
local search = {
    kind = "search", alive = true, loading = false,
    close = function() search_closes = search_closes + 1; return true end,
    submit = function(_, keyword) events[#events + 1] = "submit:" .. keyword; submits = submits + 1; return true end,
}
local search_dialog = presenter:show(search)
equal(1, search_dialog.keyboard_calls, "search shows the keyboard exactly once")
search_dialog.buttons[1][1].callback()
equal(1, search_closes, "search cancel closes its model")
equal(search_dialog, closed[#closed], "search cancel closes the input widget")
search_dialog.buttons[1][1].callback()
equal(1, search_closes, "search cancel is idempotent")

local valid_search = { kind = "search", alive = true, loading = false, submit = function(_, keyword) events[#events + 1] = "submit:" .. keyword; submits = submits + 1 end, close = function() end }
local valid_dialog = presenter:show(valid_search)
valid_dialog.buttons[1][2].callback("query")
equal("close:搜索", events[#events - 1], "valid search closes its dialog before submit")
equal("submit:query", events[#events], "search begins after dialog close")
local closed_before_invalid = #closed
local invalid_search = presenter:show({ kind = "search", close = function() end, submit = function() error("must not submit") end })
invalid_search.buttons[1][2].callback("   ")
equal(closed_before_invalid, #closed, "invalid search keeps its dialog open")

-- The singleton source manager can be safely reopened; old generations remain ignored.
local callbacks, cancelled, delivered = {}, 0, 0
local manager = SourceManager.new({
    storage = { listSources = function() return {} end },
    importer = { importJson = function() return { imported = 1 } end },
    request_engine = { execute = function(_, _, callback)
        callbacks[#callbacks + 1] = callback
        return { cancel = function() cancelled = cancelled + 1; return true end }
    end },
})
manager:importUrl("https://sources.test/old.json", function() delivered = delivered + 100 end)
manager:close()
local app = App.new({ source_manager = manager })
equal(manager, app:openSources(), "App reuses the configured source manager")
manager:importUrl("https://sources.test/new.json", function() delivered = delivered + 1 end)
callbacks[1]({ body = "[]", final_url = "https://sources.test/old.json" }, nil)
callbacks[2]({ body = "[]", final_url = "https://sources.test/new.json" }, nil)
equal(1, delivered, "reopen rejects old callbacks and delivers the new generation")
equal(1, cancelled, "closing before reopen cancels the old request once")

return count
