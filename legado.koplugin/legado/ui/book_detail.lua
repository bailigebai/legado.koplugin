local BookDetail = {}
BookDetail.__index = BookDetail

local Catalog = require("legado.ui.catalog")
local unpack_values = table.unpack or unpack

local function pack_values(...)
    return { n = select("#", ...), ... }
end

local function cancel_handle(handle)
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
end

function BookDetail.new(options)
    options = options or {}
    return setmetatable({
        kind = "book_detail",
        book = options.book, alternatives = options.alternatives or {}, shelf = options.shelf,
        reading_hook = options.reading_hook, download_hook = options.download_hook,
        service = options.service, source_lookup = options.source_lookup,
        compatibility_provider = options.compatibility,
        cache_lookup = options.cache_lookup,
        alive = true, loading_info = false, loading_catalog = false,
        info = nil, info_error = nil, catalog = nil, catalog_error = nil,
        info_request = nil, catalog_request = nil, generation = 0,
        info_generation = 0, catalog_generation = 0,
        reading_request = nil, reading_generation = 0,
    }, BookDetail)
end

function BookDetail:_cancelReading()
    self.reading_generation = self.reading_generation + 1
    local request = self.reading_request
    self.reading_request = nil
    cancel_handle(request)
end

function BookDetail:_beginReading(chapters, index, callback, expected_book, on_progress)
    if not self.alive or (expected_book and self.book.id ~= expected_book.id) then
        return nil, { code = "CANCELLED", message = "阅读请求已失效" }
    end
    if not self.reading_hook then return "阅读功能将在下一阶段提供" end
    self:_cancelReading()
    local generation, book = self.reading_generation, self.book
    local request_complete, completion_delivered = false, false
    local function current()
        return self.alive and generation == self.reading_generation and self.book.id == book.id
    end
    local function complete(value, err)
        if completion_delivered or not current() then return false end
        completion_delivered = true
        self.reading_request = nil
        if type(callback) == "function" then return callback(value, err) end
        return true
    end
    local intent = {
        on_progress = on_progress,
        isCurrent = current,
        markRequestComplete = function()
            if request_complete then return false end
            request_complete = true
            if not current() then return false end
            self.reading_request = nil
            return true
        end,
        replaceDownstream = function(handle)
            if completion_delivered then return true end
            if not current() then return false end
            local previous = self.reading_request
            self.reading_request = nil
            if previous and previous ~= handle then cancel_handle(previous) end
            if handle and type(handle.cancel) == "function" then self.reading_request = handle end
            return true
        end,
    }
    local values = pack_values(self.reading_hook(book, chapters, index, complete, intent))
    local handle = values[1]
    local terminal = values[2] ~= nil or type(handle) == "string"
        or (type(handle) == "table" and type(handle.code) == "string")
    if terminal and not completion_delivered and current() then
        self.reading_generation = self.reading_generation + 1
        self.reading_request = nil
    end
    if current() and not request_complete and not completion_delivered
        and handle and type(handle.cancel) == "function" then self.reading_request = handle end
    return unpack_values(values, 1, values.n)
end

function BookDetail:addToShelf() return self.shelf and self.shelf:add(self.book) end
function BookDetail:removeFromShelf() return self.shelf and self.shelf:remove(self.book.id) end
function BookDetail:switchSource(index)
    local selected = self.alternatives[index]
    if selected then
        self:_cancelReading()
        self.generation = self.generation + 1
        cancel_handle(self.info_request)
        cancel_handle(self.catalog_request)
        self.info_request, self.catalog_request = nil, nil
        self.book, self.info, self.catalog = selected, nil, nil
        self.info_error, self.catalog_error = nil, nil
        self.loading_info, self.loading_catalog = false, false
    end
    return selected
end
function BookDetail:loadInfo(callback)
    callback = callback or function() end
    if not self.alive or not self.service or type(self.service.getBookInfo) ~= "function" then return nil end
    cancel_handle(self.info_request)
    self.info_generation = self.info_generation + 1
    local generation, request_generation, book = self.generation, self.info_generation, self.book
    local source = self.source_lookup and self.source_lookup(book.source_id) or nil
    if not source then return nil end
    self.loading_info, self.info_error = true, nil
    local completed = false
    local function done(info, err)
        completed = true
        if not self.alive or generation ~= self.generation or request_generation ~= self.info_generation or self.book.id ~= book.id then return end
        self.loading_info, self.info_error, self.info_request = false, err, nil
        if info then self.info, self.book = info, info end
        callback(info, err)
    end
    local ok, request = pcall(self.service.getBookInfo, self.service, source, book, done)
    if not ok then
        self.loading_info, self.info_error, self.info_request = false, { code = "REQUEST_ERROR", message = "详情请求启动失败" }, nil
        callback(nil, self.info_error)
        return nil
    end
    if completed then self.info_request = nil else self.info_request = request end
    return self.info_request
end
function BookDetail:loadCatalog(callback)
    callback = callback or function() end
    if not self.alive or not self.service or type(self.service.getChapters) ~= "function" then return nil end
    cancel_handle(self.catalog_request)
    self.catalog_generation = self.catalog_generation + 1
    local generation, request_generation, book = self.generation, self.catalog_generation, self.book
    local source = self.source_lookup and self.source_lookup(book.source_id) or nil
    if not source then return nil end
    self.loading_catalog, self.catalog_error = true, nil
    local completed = false
    local function done(chapters, err)
        completed = true
        if not self.alive or generation ~= self.generation or request_generation ~= self.catalog_generation or self.book.id ~= book.id then return end
        self.loading_catalog, self.catalog_request = false, nil
        self.catalog_error = err
        if chapters then self.catalog = Catalog.new(chapters,
            self.cache_lookup and function(chapter) return self.cache_lookup(chapter, book) end or nil,
            function(_, index, selected_callback)
                return self:_beginReading(chapters, index, selected_callback, book)
            end)
        end
        callback(self.catalog, err)
    end
    local ok, request = pcall(self.service.getChapters, self.service, source, book, done)
    if not ok then
        self.loading_catalog, self.catalog_error, self.catalog_request = false, { code = "REQUEST_ERROR", message = "目录请求启动失败" }, nil
        callback(nil, self.catalog_error)
        return nil
    end
    if completed then self.catalog_request = nil else self.catalog_request = request end
    return self.catalog_request
end
function BookDetail:close()
    if not self.alive then return false end
    self.alive = false
    self.generation = self.generation + 1
    self:_cancelReading()
    cancel_handle(self.info_request)
    cancel_handle(self.catalog_request)
    return true
end
function BookDetail:compatibility()
    if type(self.compatibility_provider) == "function" then return self.compatibility_provider(self.book) end
    return nil
end
function BookDetail:startReading(callback, on_progress)
    local chapters = self.catalog and self.catalog.items or nil
    if chapters then
        local values = {}
        for index, item in ipairs(chapters) do values[index] = item.chapter end
        chapters = values
    end
    return self:_beginReading(chapters, nil, callback, self.book, on_progress)
end
function BookDetail:startDownload() return self.download_hook and self.download_hook(self.book) or "下载功能将在下一阶段提供" end

return BookDetail
