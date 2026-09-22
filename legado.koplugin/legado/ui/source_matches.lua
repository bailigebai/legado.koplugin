local Models = require("legado.lib.models")
local BookService = require("legado.lib.book_service")

local SourceMatches = {}
SourceMatches.__index = SourceMatches

local function normalized(value)
    if type(value) ~= "string" then return "" end
    return value:gsub("　", " "):gsub("\194\160", " "):gsub("%s+", " "):match("^%s*(.-)%s*$"):lower()
end

local function cancel(request)
    if request and type(request.cancel) == "function" then pcall(request.cancel, request) end
end

function SourceMatches.new(options)
    options = options or {}
    assert(options.service, "SourceMatches requires service")
    assert(options.storage or options.service.storage, "SourceMatches requires storage")
    return setmetatable({ kind = "reader_sources", title = "切换站点书源", book = options.book,
        service = options.service, storage = options.storage or options.service.storage,
        scheduler = options.scheduler or options.service.scheduler, onUpdate = options.onUpdate,
        alive = true, loading = false, generation = 0, results = {}, errors = {}, progress = {},
        queue = {}, by_source = {}, sources = {}, requests = {}, search_errors = {}, catalog_errors = {},
        next_catalog = 1, active_catalogs = 0, completed_catalogs = 0 }, SourceMatches)
end

function SourceMatches:_changed()
    if not self.alive or self.pumping then return end
    self.loading = not self.search_done or self.active_catalogs > 0 or self.next_catalog <= #self.queue
    if not self.loading then self:_restoreConcurrency() end
    self.progress.catalog_total, self.progress.catalog_completed = #self.queue, self.completed_catalogs
    self.errors = {}
    for _, err in ipairs(self.search_errors) do self.errors[#self.errors + 1] = err end
    for _, row in ipairs(self.queue) do
        local err = self.catalog_errors[row.book.source_id]
        if err then self.errors[#self.errors + 1] = err end
    end
    table.sort(self.results, function(a, b)
        local ac, bc = a.chapter_count or -1, b.chapter_count or -1
        if ac ~= bc then return ac > bc end
        return a.order < b.order
    end)
    if self.refresh_action or type(self.onUpdate) ~= "function" then return end
    if not self.scheduler or type(self.scheduler.scheduleIn) ~= "function" then
        self.onUpdate(self)
        return
    end
    local generation, action = self.generation
    action = function()
        if not self.alive or generation ~= self.generation or self.refresh_action ~= action then return end
        self.refresh_action, self.refresh_token = nil, nil
        if type(self.onUpdate) == "function" then self.onUpdate(self) end
    end
    self.refresh_action = action
    local ok, token = pcall(self.scheduler.scheduleIn, self.scheduler, 6, action)
    if self.refresh_action == action then
        if ok then self.refresh_token = token or action else self.refresh_action = nil end
    end
end

function SourceMatches:_pumpCatalogs()
    -- Keep catalog probes out of the search burst. Kindle has a small process
    -- budget; overlapping both queues can terminate KOReader.
    if not self.alive or self.pumping then return end
    if not self.search_done then self:_changed(); return end
    self.pumping = true
    local generation = self.generation
    while self.alive and self.active_catalogs < BookService.DEFAULT_CONCURRENCY and self.next_catalog <= #self.queue do
        local row = self.queue[self.next_catalog]
        local source_id, settled = row.book.source_id, false
        self.next_catalog, self.active_catalogs = self.next_catalog + 1, self.active_catalogs + 1
        local function complete(chapters, err, metadata)
            if not self.alive or generation ~= self.generation or settled then return end
            settled = true
            self.requests[source_id] = nil
            self.active_catalogs, self.completed_catalogs = self.active_catalogs - 1, self.completed_catalogs + 1
            if not err and type(chapters) == "table" then
                row.chapters, row.chapter_count = chapters, #chapters
                row.catalog_complete = metadata and metadata.catalog_complete == true or false
            else
                row.catalog_error = type(err) == "table" and err.code or "REQUEST_ERROR"
                self.catalog_errors[source_id] = { source_id = source_id, source_name = row.source_name,
                    code = row.catalog_error, message = "目录获取失败，章节数暂时未知" }
            end
            self:_pumpCatalogs()
        end
        local ok, request = pcall(self.service.getChapters, self.service, self.sources[source_id], row.book, complete,
            { max_pages = BookService.MAX_CATALOG_PAGES, on_progress = function(_, count)
                if not self.alive or generation ~= self.generation or settled then return end
                row.chapter_count = tonumber(count)
                self:_changed()
            end })
        if not ok or (not request and not settled) then complete(nil, { code = "REQUEST_ERROR" })
        elseif not self.alive or generation ~= self.generation then cancel(request)
        elseif not settled then self.requests[source_id] = request end
    end
    self.pumping = false
    self:_changed()
end

function SourceMatches:start()
    if not self.alive or self.started then return false end
    self.started, self.loading = true, true
    self.generation = self.generation + 1
    local generation = self.generation
    -- Source matching is an explicit burst operation. Keep the wider queue
    -- scoped to this screen so ordinary reading requests are unaffected.
    self._service_fast_search = self.service.fast_search_concurrency
    self._burst_active = true
    self.service.fast_search_concurrency = BookService.FAST_SEARCH_CONCURRENCY
    if self.service.requests and self.service.requests.concurrency then
        self._request_concurrency = self.service.requests.concurrency
        self.service.requests.concurrency = math.max(self._request_concurrency, BookService.FAST_SEARCH_CONCURRENCY)
    end
    local name, author = normalized(self.book and self.book.name), normalized(self.book and self.book.author)
    if name == "" or author == "" then
        self.search_done = true
        self.error = { code = "INVALID_INPUT", message = "当前书籍缺少书名或作者，无法确认同名同作者的站点。" }
        self:_changed()
        return false
    end
    for order, source in ipairs(self.storage:listSources() or {}) do
        if source.enabled ~= false then
            local id = Models.sourceId(source)
            self.sources[id] = source
            self.by_source[id] = { order = order }
        end
    end
    local function update(result, err, finished)
        if not self.alive or generation ~= self.generation or self.search_done then return end
        if finished then self.search_done, self.request = true, nil; self:_restoreConcurrency() end
        self.error = err
        self.search_errors = result and result.errors or {}
        for _, key in ipairs({ "total", "completed", "succeeded", "failed" }) do
            self.progress[key] = result and result[key] or 0
        end
        for _, group in ipairs(result and result.groups or {}) do
            for _, candidate in ipairs(group.alternatives or { group.book }) do
                local entry = type(candidate) == "table" and self.by_source[candidate.source_id]
                if entry and not entry.book and normalized(candidate.name) == name and normalized(candidate.author) == author then
                    local source = self.sources[candidate.source_id]
                    entry.book, entry.alternatives = candidate, { candidate }
                    entry.source_name = source.bookSourceName or source.name or candidate.source_name or "书源"
                    entry.catalog_complete = false
                    self.results[#self.results + 1], self.queue[#self.queue + 1] = entry, entry
                end
            end
        end
        self:_pumpCatalogs()
    end
    local ok, request = pcall(self.service.search, self.service, self.book.name, nil, 1,
        function(result, err) update(result, err, true) end, function(result) update(result, nil, false) end)
    if not ok or (not request and not self.search_done) then update(nil, { code = "REQUEST_ERROR", message = "书源搜索启动失败，请稍后重试。" }, true)
    elseif not self.alive or generation ~= self.generation then cancel(request)
    elseif not self.search_done then self.request = request end
    return true
end

function SourceMatches:_restoreConcurrency()
    if not self._burst_active then return end
    self._burst_active = false
    self.service.fast_search_concurrency = self._service_fast_search
    if self._request_concurrency and self.service.requests then self.service.requests.concurrency = self._request_concurrency end
    self._service_fast_search, self._request_concurrency = nil, nil
end

function SourceMatches:close()
    if not self.alive then return false end
    self.alive, self.loading = false, false
    self.generation = self.generation + 1
    cancel(self.request)
    for _, request in pairs(self.requests) do cancel(request) end
    if self.refresh_action and self.scheduler and type(self.scheduler.unschedule) == "function" then
        pcall(self.scheduler.unschedule, self.scheduler, self.refresh_token or self.refresh_action)
    end
    self.request, self.refresh_action, self.refresh_token, self.onUpdate = nil, nil, nil, nil
    self:_restoreConcurrency()
    self.requests = {}
    return true
end

return SourceMatches
