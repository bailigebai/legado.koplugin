require("library_screen_stub")
local assertx = require("assertions")
local Catalog = require("legado.ui.catalog")
local BookDetail = require("legado.ui.book_detail")
local Presenter = require("legado.ui.presenter")
local Settings = require("legado.lib.settings")
local SettingsView = require("legado.ui.settings")
local App = require("legado.ui.app")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end

local selected, async_callback
local catalog = Catalog.new({ { uid = "one", title = "One" }, { uid = "two", title = "Two" } },
    function(chapter) return chapter.uid == "one" end,
    function(chapter, position, callback)
        selected = { chapter = chapter, position = position }
        async_callback = callback
        return { cancel = function() return true end }
    end)
local handle = catalog:select(2, function() end)
equal("two", selected.chapter.uid, "catalog selection passes the selected chapter")
equal(2, selected.position, "catalog selection passes the stable chapter position")
equal("table", type(handle), "catalog selection returns the asynchronous reader handle")

local reading_index
local detail = BookDetail.new({
    book = { id = "b1", source_id = "s1", name = "Book" },
    service = { getChapters = function(_, _, _, callback)
        callback({ { uid = "one", title = "One" }, { uid = "two", title = "Two" } }, nil)
        return { cancel = function() end }
    end },
    source_lookup = function() return { id = "s1" } end,
    reading_hook = function(_, chapters, index, callback)
        reading_index = index
        return { cancel = function() end }
    end,
})
local loaded_catalog
detail:loadCatalog(function(value) loaded_catalog = value end)
loaded_catalog:select(2, function() end)
equal(2, reading_index, "BookDetail binds catalog selection to the requested reader-session chapter")

local shown = {}
local function class(kind) return { new = function(_, options) options.kind = kind; return options end } end
local presenter = Presenter.new({
    ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end, close = function() end },
    menu = class("menu"), info_message = class("info"), input_dialog = class("input"),
})
local menu = presenter:show(catalog)
local before = #shown
local returned = menu.item_table[2].callback()
if menu.close_callback then menu.close_callback() end
equal("table", type(returned), "touch or key selection starts reading instead of returning a chapter table")
equal(before + 1, #shown, "successful reader handle keeps a loading surface until ready")
async_callback(nil, { code = "NETWORK_ERROR", message = "failed" })
equal("info", shown[#shown].kind, "asynchronous chapter failure is visible")

local synchronous_error = { code = "STORAGE_ERROR" }
local failing_catalog = Catalog.new({ { uid = "bad", title = "Bad" } }, nil,
    function(_, _, callback)
        callback(nil, synchronous_error)
        return nil, synchronous_error
    end)
local failing_menu = presenter:show(failing_catalog)
before = #shown
failing_menu.item_table[1].callback()
equal(before + 1, #shown, "synchronous chapter failure replaces the loading surface once")

-- Detail's start-reading action follows the same result policy.
local success_detail = {
    kind = "book_detail", book = { name = "Book" }, alternatives = {}, info = { author = "A" },
    addToShelf = function() end, removeFromShelf = function() end,
    startDownload = function() return { id = "d1" } end,
    startReading = function(_, callback) async_callback = callback; return { cancel = function() end } end,
}
local detail_menu = presenter:show(success_detail)
local reading_action
for _, item in ipairs(detail_menu.item_table) do if item.text == "开始阅读" then reading_action = item end end
before = #shown
reading_action.callback()
equal(before + 1, #shown, "detail reader handle keeps a loading surface")

-- Settings validate, persist and remain reachable through focused menu actions.
local persisted = {}
local adapter = {
    read = function() return persisted end,
    write = function(value) persisted = value; return true end,
}
local settings = Settings.new(adapter)
local view = SettingsView.new({ settings = settings })
equal(0, view:set("prefetch", -3), "prefetch clamps to zero")
equal(10, view:set("prefetch", 99), "prefetch clamps to ten")
equal(2, view:set("concurrency", 1), "request concurrency clamps to two")
equal(3, view:set("concurrency", 9), "request concurrency clamps to three")
equal(1, view:set("timeout", 0), "network timeout clamps to a usable minimum")
equal(20, view:set("timeout", 99), "network timeout clamps to the hard maximum")
equal(5, view:set("shelf_page", 1), "bookshelf page size clamps to five")
equal(50, view:set("shelf_page", 500), "bookshelf page size clamps to fifty")
local restarted = Settings.new(adapter)
equal(10, restarted:get("prefetch"), "prefetch survives restart")
equal(3, restarted:get("concurrency"), "concurrency survives restart")
equal(20, restarted:get("timeout"), "timeout survives restart")
equal(50, restarted:get("shelf_page"), "shelf page size survives restart")

local settings_menu = presenter:show(view)
equal(true, type(settings_menu.item_table[1].callback) == "function", "timeout row is focusable and actionable")
equal(true, type(settings_menu.item_table[2].callback) == "function", "concurrency row is focusable and actionable")
equal(true, type(settings_menu.item_table[3].callback) == "function", "prefetch row is focusable and actionable")
equal("书架布局：每页 4 × 3 本", settings_menu.item_table[4].text, "fixed shelf layout is described without an ineffective page-size setting")
settings_menu.item_table[3].callback()
if settings_menu.close_callback then settings_menu.close_callback() end
local prefetch_dialog = shown[#shown]
prefetch_dialog.buttons[1][2].callback("0")
equal(0, settings:get("prefetch"), "settings dialog persists the boundary value zero")
equal(true, tostring(shown[#shown].item_table[#shown[#shown].item_table].text):find("KOReader", 1, true) ~= nil,
    "appearance entry explicitly delegates styling to KOReader")

-- Falling back from a failed online catalog to a failed offline open must not
-- deliver the same terminal error twice.
local app_completions = 0
local app_source = { id = "s1" }
local app = App.new({
    storage = { listSources = function() return { app_source } end },
    book_service = { getChapters = function(_, _, _, callback)
        callback(nil, { code = "NETWORK_ERROR" })
        return { cancel = function() end }
    end },
    reader_session = { openOffline = function(_, _, _, _, callback)
        local err = { code = "STORAGE_ERROR" }
        callback(nil, err)
        return nil, err
    end },
})
app:startReading({ id = "b1", source_id = Models.sourceId(app_source) }, nil, nil, function()
    app_completions = app_completions + 1
end)
equal(1, app_completions, "online-to-offline terminal failure is delivered exactly once")

return count
