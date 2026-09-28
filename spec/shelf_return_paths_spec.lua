local A = require("assertions")
local App = require("legado.ui.app")
local ShelfMenu = require("legado.ui.shelf_menu")
local count = 0
local function eq(expected, actual, reason)
    count = count + 1
    A.equal(expected, actual, reason)
end
local books = {{id = "b1", name = "书一", kind = "玄幻"}}
local shown = {}
local app = App.new{storage = {
    listShelf = function() return books end,
    getProgress = function() return {updated_at = 1} end,
}, show = function(view) shown[#shown + 1] = view; return view end}
local old = app:openBookshelf()
old:setFilter("reading", "玄幻")
local stale_rendered = false
local presenter = {app = app,
    _library = function(_, _, options) return options end,
    _shelf = function() stale_rendered = true end,
}
local menu = ShelfMenu.open(presenter, old, 2, "find")
old:close()
local restored = menu.on_back()
eq(false, stale_rendered, "return from another controller does not render a closed shelf")
eq(false, old == restored, "return creates a live shelf controller")
eq(2, restored.start_page, "return retains the shelf page")
eq("reading", restored.reading_state, "return retains the reading filter")
eq("玄幻", restored.category, "return retains the category filter")
eq(2, #shown, "restored shelf is presented")
return count
