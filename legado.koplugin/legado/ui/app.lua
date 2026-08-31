local Shelf = require("legado.ui.bookshelf")
local SearchView = require("legado.ui.search")
local SettingsView = require("legado.ui.settings")
local About = require("legado.ui.about")
local BookDetail = require("legado.ui.book_detail")
local Models = require("legado.lib.models")

local App = {}
App.__index = App

function App.new(options)
    options = options or {}
    return setmetatable({
        storage = options.storage, service = options.book_service, source_manager = options.source_manager,
        settings = options.settings, appearance = options.appearance,
        reading_hook = options.reading_hook, download_hook = options.download_hook,
        reader_session = options.reader_session,
        cover_loader = options.cover_loader,
        show = options.show,
    }, App)
end

function App:_present(view)
    if type(self.show) == "function" then self.show(view) end
    return view
end

function App:openBookshelf()
    if not self.storage then return self:_present({ title = "书架", empty_text = "书架尚未初始化" }) end
    local page_size = self.settings and self.settings:get("shelf_page") or 20
    local covers_enabled = not self.settings or self.settings:get("covers_enabled") ~= false
    return self:_present(Shelf.new({ storage = self.storage, page_size = page_size, covers_enabled = covers_enabled, cover_loader = self.cover_loader }))
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
function App:startReading(book, chapters)
    if self.reading_hook then return self.reading_hook(book, chapters) end
    if not self.reader_session or not self.storage then return "阅读功能尚未初始化" end
    local source
    for _, candidate in ipairs(self.storage:listSources() or {}) do if Models.sourceId(candidate) == book.source_id then source = candidate; break end end
    if not source then return "书源不存在" end
    local function offline()
        return self.reader_session:openOffline(source, book)
    end
    if not self.service then return offline() end
    if type(chapters) == "table" and #chapters > 0 then return self.reader_session:resume(source, book, chapters) end
    return self.service:getChapters(source, book, function(values, err)
        if err or not values then offline(); return end
        if type(self.storage.replaceChapters) == "function" then self.storage:replaceChapters(book.id, values) end
        self.reader_session.cache:writeCatalog(book.source_id, book.id, { chapters = values })
        self.reader_session:resume(source, book, values)
    end)
end
function App:startDownload(book) return self.download_hook and self.download_hook(book) or "下载功能将在下一阶段提供" end
function App:createBookDetail(book, alternatives)
    local page_size = self.settings and self.settings:get("shelf_page") or 20
    local covers_enabled = not self.settings or self.settings:get("covers_enabled") ~= false
    local shelf = self.storage and Shelf.new({ storage = self.storage, page_size = page_size, covers_enabled = covers_enabled, cover_loader = self.cover_loader }) or nil
    return BookDetail.new({
        book = book, alternatives = alternatives or { book }, shelf = shelf,
        service = self.service,
        source_lookup = self.storage and function(opaque_id)
            for _, source in ipairs(self.storage:listSources() or {}) do if Models.sourceId(source) == opaque_id then return source end end
        end or nil,
        compatibility = function(selected)
            if not selected or not self.source_manager or type(self.source_manager.compatibility) ~= "function" then return nil end
            local source = self.storage and (function()
                for _, candidate in ipairs(self.storage:listSources() or {}) do
                    if Models.sourceId(candidate) == selected.source_id then return candidate end
                end
            end)()
            return source and self.source_manager:compatibility(source.id) or nil
        end,
        cache_lookup = self.reader_session and function(chapter, current_book)
            return self.reader_session.cache:readBody(current_book.source_id, current_book.id, chapter) ~= nil
        end or nil,
        reading_hook = function(selected, selected_chapters) return self:startReading(selected, selected_chapters) end,
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
