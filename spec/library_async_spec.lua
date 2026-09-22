require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local Shelf = require("legado.ui.bookshelf")

local shown, scheduled = {}, nil
local ui = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end,
    scheduleIn = function(_, _, callback) scheduled = callback end,
}
local presenter = Presenter.new({ ui_manager = ui })
local function last() return shown[#shown] end
local function action(label)
    for _, item in ipairs(last().actions or {}) do
        if item.text == label then return item.callback() end
    end
    for _,item in ipairs(last().items or {}) do if (item.text or item.title)==label then return item.callback() end end
    for _,item in ipairs(last().actions or {}) do if item.text=="更多" then item.callback(); return action(label) end end
    error("missing action: " .. label)
end

local search = {
    kind = "search", alive = true, loading = false,
    submit = function(self)
        self.loading = true
        self.errors = { { source_name = "坏书源", code = "HTTP_ERROR" } }
        self.progress = { completed = 1, total = 2 }
    end,
    cancel = function() end,
}
presenter:_runSearch(search, "书名", nil, 1)
search.onUpdate()
action("失败详情")
local diagnostics = last()
scheduled()
A.equal(diagnostics, last(), "search progress keeps the diagnostic subpage open")

local info_callback, catalog_callback
local detail = {
    kind = "book_detail", alive = true,
    book = { id = "book-1", name = "书名", intro = "短简介" },
    alternatives = { { id = "book-1", name = "书名", intro = "短简介" }, { id = "book-2", source_name = "备用源" } },
    addToShelf = function() return true end,
    removeFromShelf = function() return true end,
    startDownload = function() return {} end,
    startReading = function() return {} end,
    loadInfo = function(self, callback)
        info_callback = function(info, err)
            if info then self.info, self.book = info, info end
            return callback(info, err)
        end
    end,
    loadCatalog = function(_, callback) catalog_callback = callback end,
    switchSource = function() end,
}
detail._source_books = detail.alternatives
presenter:_detail(detail)
action("加入书架")
info_callback({ id = "book-1", name = "书名", intro = "完整简介" })
A.equal("完整简介", last().items[1].intro, "metadata refreshes a rebuilt active detail")
A.equal("完整简介", detail.alternatives[1].intro, "metadata is retained in source alternatives")

action("查看目录")
presenter.app={openReaderSourceSites=function(_,_,_,detail)
    return presenter:_library(detail,{title='切换站点书源',subpage='detail_sources',items={}})
end}
action("切换站点书源")
local choices = last()
catalog_callback({ kind = "catalog", items = {} })
A.equal(choices, last(), "catalog completion keeps source choices open")

local cover_calls = 0
presenter.app = {
    cover_loader = function() cover_calls = cover_calls + 1 end,
    settings = { get = function(_, key) if key == "covers_enabled" then return false end end },
}
presenter:_library({ kind = "bookshelf" }, { items = { { book = {}, cover_url = "cover.jpg" } } })
A.equal(nil, last().cover_loader, "disabled covers remove the shared loader")
A.equal(0, cover_calls, "disabled covers issue no shared loader request")

local books = {}
for index = 1, 7 do books[index] = { id = index, name = "Book " .. index } end
local shelf = Shelf.new({ storage = { listShelf = function() return books end } })
local second = shelf:page(2, "text", 3)
A.equal("Book 4", second.items[1].title, "shelf page-size override advances one card screen")
local requested_size
presenter:_shelf({
    kind = "bookshelf",
    page = function(_, _, _, size) requested_size = size; return { page = 1, page_count = 1, items = {} } end,
})
A.equal(12, requested_size, "presenter requests one twelve-book grid from shelf storage")

return 8
