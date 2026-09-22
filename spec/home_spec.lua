local assertx = require("assertions")
local Home = require("legado.ui.home")

local state = {
    books = {
        { id = "old", name = "Old", author = "A" },
        { id = "new", name = "New", author = "B", cover_url = "https://covers.test/new.jpg" },
    },
    progress = {
        old = { updated_at = 10, fraction = 0.2 },
        new = { updated_at = 20, fraction = 0.5 },
    },
}
local storage = {
    listShelf = function() return state.books end,
    getProgress = function(_, id) return state.progress[id] end,
}

local opened = {}
local home = Home.new({
    storage = storage,
    actions = { bookshelf = function() opened[#opened + 1] = "bookshelf" end },
})
local model = home:page()
assertx.equal("home", model.kind, "home model has a stable kind")
assertx.equal("New", model.recent[1].name, "home sorts recent books by reading time")
assertx.equal("书架", model.actions[1].text, "home exposes bookshelf action")
model.actions[1].callback()
assertx.equal("bookshelf", opened[1], "home action delegates to app")

local loaded
local cover_home = Home.new({ storage = storage, cover_loader = function(_, callback)
    loaded = callback
    return { cancel = function() end }
end }):page()
cover_home.recent[1].on_update = function(item) item.updated = true end
loaded("new-cover.jpg")
assertx.equal("new-cover.jpg", cover_home.recent[1].cover, "home reuses asynchronous cover loading")
assertx.equal(true, cover_home.recent[1].updated, "home notifies the cover widget")

state.books = {}
local empty = Home.new({ storage = storage }):page()
assertx.equal("暂无最近阅读", empty.empty_text, "home has a concise empty state")
assertx.equal("去书架添加", empty.empty_actions[1].text, "home empty state points to bookshelf")

return 8
