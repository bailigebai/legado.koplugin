local A = require("assertions")
local shown = {}
local ui = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end,
}
local progress = {}
local storage = {
    getProgress = function(_, id) return progress[id] end,
}
local app = { storage = storage }
local Presenter = require("legado.ui.presenter")
local presenter = Presenter.new{
    ui_manager = ui,
    app = app,
    library_screen_factory = function(options)
        options.kind = "library_screen"
        return options
    end,
}

local function detail(book)
    local view = {
        kind = "book_detail", book = book, info = book, alternatives = { book }, alive = true,
        addToShelf = function() return true end,
        removeFromShelf = function() return true end,
        loadCatalog = function() return true end,
        startReading = function() return true end,
        startDownload = function() return true end,
    }
    presenter:show(view)
    return presenter.library_widget
end

local fresh = detail({ id = "fresh", name = "新书", author = "作者" })
A.equal("书籍详情", fresh.title, "detail uses the stable page title")
A.equal("更多", fresh.header_action.text, "detail exposes More in the top bar")
A.equal("开始阅读", fresh.actions[1].text, "unread books keep the start-reading label")

progress.resume = { fraction = 0.25, chapter_index = 2 }
local resumed = detail({ id = "resume", name = "继续读", author = "作者" })
A.equal("继续阅读", resumed.actions[1].text, "books with saved progress use the resume label")

return 4
