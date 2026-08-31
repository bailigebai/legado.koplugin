local Shelf = require("legado.ui.bookshelf")
local SearchView = require("legado.ui.search")
local SettingsView = require("legado.ui.settings")
local About = require("legado.ui.about")
local BookDetail = require("legado.ui.book_detail")

local App = {}
App.__index = App

function App.new(options)
    options = options or {}
    return setmetatable({
        storage = options.storage, service = options.book_service, source_manager = options.source_manager,
        settings = options.settings, appearance = options.appearance,
        reading_hook = options.reading_hook, download_hook = options.download_hook,
        show = options.show,
    }, App)
end

function App:_present(view)
    if type(self.show) == "function" then self.show(view) end
    return view
end

function App:openBookshelf()
    if not self.storage then return self:_present({ title = "书架", empty_text = "书架尚未初始化" }) end
    return self:_present(Shelf.new({ storage = self.storage, page_size = 20, covers_enabled = true }))
end
function App:openSearch()
    if not self.service then return self:_present({ title = "搜索", error = "搜索服务尚未初始化" }) end
    return self:_present(SearchView.new({
        service = self.service,
        source_provider = self.storage and function() return self.storage:listSources() end or nil,
    }))
end
function App:openSources() return self:_present(self.source_manager or { title = "书源管理", empty_text = "暂无书源" }) end
function App:openDownloads() return self:_present({ title = "下载管理", empty_text = "下载功能将在下一阶段提供" }) end
function App:openSettings() return self:_present(SettingsView.new({ settings = self.settings, appearance = self.appearance })) end
function App:openAbout() return self:_present(About) end
function App:startReading(book) return self.reading_hook and self.reading_hook(book) or "阅读功能将在下一阶段提供" end
function App:startDownload(book) return self.download_hook and self.download_hook(book) or "下载功能将在下一阶段提供" end
function App:createBookDetail(book, alternatives)
    local shelf = self.storage and Shelf.new({ storage = self.storage, page_size = 20, covers_enabled = true }) or nil
    return BookDetail.new({
        book = book, alternatives = alternatives or { book }, shelf = shelf,
        service = self.service,
        source_lookup = self.storage and function(id) return self.storage:getSource(id) end or nil,
        reading_hook = function(selected) return self:startReading(selected) end,
        download_hook = function(selected) return self:startDownload(selected) end,
    })
end

function App:menuItems()
    return {
        { text = "书架", callback = function() return self:openBookshelf() end },
        { text = "搜索", callback = function() return self:openSearch() end },
        { text = "书源管理", callback = function() return self:openSources() end },
        { text = "下载管理", callback = function() return self:openDownloads() end },
        { text = "设置", callback = function() return self:openSettings() end },
        { text = "关于", callback = function() return self:openAbout() end },
    }
end

return App
