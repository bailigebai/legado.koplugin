local BookDetail = {}
BookDetail.__index = BookDetail

local Catalog = require("legado.ui.catalog")

function BookDetail.new(options)
    options = options or {}
    return setmetatable({
        kind = "book_detail",
        book = options.book, alternatives = options.alternatives or {}, shelf = options.shelf,
        reading_hook = options.reading_hook, download_hook = options.download_hook,
        service = options.service, source_lookup = options.source_lookup,
        alive = true, loading_catalog = false, catalog = nil, catalog_error = nil, request = nil,
    }, BookDetail)
end

function BookDetail:addToShelf() return self.shelf and self.shelf:add(self.book) end
function BookDetail:removeFromShelf() return self.shelf and self.shelf:remove(self.book.id) end
function BookDetail:switchSource(index)
    local selected = self.alternatives[index]
    if selected then self.book = selected end
    return selected
end
function BookDetail:loadCatalog(callback)
    callback = callback or function() end
    if not self.alive or not self.service or type(self.service.getChapters) ~= "function" then return nil end
    local source = self.source_lookup and self.source_lookup(self.book.source_ref) or nil
    if not source then return nil end
    self.loading_catalog, self.catalog_error = true, nil
    self.request = self.service:getChapters(source, self.book, function(chapters, err)
        if not self.alive then return end
        self.loading_catalog = false
        self.catalog_error = err
        if chapters then self.catalog = Catalog.new(chapters) end
        callback(self.catalog, err)
    end)
    return self.request
end
function BookDetail:close()
    if not self.alive then return false end
    self.alive = false
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    return true
end
function BookDetail:startReading() return self.reading_hook and self.reading_hook(self.book) or "阅读功能将在下一阶段提供" end
function BookDetail:startDownload() return self.download_hook and self.download_hook(self.book) or "下载功能将在下一阶段提供" end

return BookDetail
