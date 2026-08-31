local Cleaner = require("legado.lib.content_cleaner")
local EpubBuilder = require("legado.lib.epub_builder")
local Errors = require("legado.lib.errors")
local Identity = require("legado.lib.identity")
local Models = require("legado.lib.models")

local DownloadManager = {}
DownloadManager.__index = DownloadManager

local terminal = { cancelled = true, failed = true, completed = true }

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    return result
end

local function timestamp(epoch)
    local ok, value = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ", tonumber(epoch) or 0)
    return ok and value or "1970-01-01T00:00:00Z"
end

local function error_value(value, fallback)
    if type(value) == "table" and value.code then return value end
    return Errors.new(Errors.STORAGE_ERROR, fallback or "download failed", value and { cause = tostring(value) } or nil)
end

function DownloadManager.new(options)
    options = options or {}
    assert(options.storage, "DownloadManager requires storage")
    assert(options.cache, "DownloadManager requires cache")
    assert(options.book_service, "DownloadManager requires book_service")
    assert(options.builder, "DownloadManager requires builder")
    assert(options.standby, "DownloadManager requires standby guard")
    local self = setmetatable({
        storage = options.storage, cache = options.cache, service = options.book_service,
        builder = options.builder, standby = options.standby, scheduler = options.scheduler,
        output_root = tostring(options.output_root or "downloads"):gsub("[/\\]+$", ""),
        now = options.now or os.time, open_final = options.open_final,
        tasks = {}, order = {}, callbacks = {}, callback_delivered = {}, active = nil,
        sequence = 0, pump_scheduled = false,
    }, DownloadManager)
    local recovered = false
    for _, task in ipairs(self.storage:listDownloadTasks() or {}) do
        if type(task) == "table" and type(task.id) == "string" then
            if task.status == "running" or task.status == "cancelling" then
                task.status, task.cancel_requested, task.current = "interrupted", false, nil
                task.updated_at = self.now(); self.storage:putDownloadTask(task); recovered = true
            end
            self.tasks[task.id] = task; self.order[#self.order + 1] = task.id
        end
    end
    if recovered and type(self.standby.releaseAll) == "function" then self.standby:releaseAll() end
    return self
end

function DownloadManager:_persist(task)
    task.updated_at = self.now()
    local saved, err = self.storage:putDownloadTask(task)
    if not saved then return nil, error_value(err, "cannot persist download task") end
    self.tasks[task.id] = task
    return true
end

function DownloadManager:_source(task)
    for _, source in ipairs(self.storage:listSources() or {}) do
        if Models.sourceId(source) == task.source_id then return source end
    end
end

function DownloadManager:_valid_callback(task, generation)
    return self.active == task.id and task.status == "running" and task.generation == generation and not task.cancel_requested
end

function DownloadManager:_notify_terminal(task, err)
    if self.callback_delivered[task.id] then return end
    self.callback_delivered[task.id] = true
    local callback = self.callbacks[task.id]
    if callback then pcall(callback, copy(task), err) end
end

function DownloadManager:_terminal(task, status, err)
    if terminal[task.status] and task.status == status then return true end
    task.status, task.current, task.handle = status, nil, nil
    task.cancel_requested = status == "cancelled"
    task.error = err and { code = err.code or Errors.STORAGE_ERROR, message = err.message or tostring(err) } or nil
    self:_persist(task)
    if self.active == task.id then self.active = nil; self.standby:release() end
    self:_notify_terminal(task, err)
    self:_schedulePump()
    return true
end

function DownloadManager:_fail(task, err, chapter_failed)
    if chapter_failed then task.failed = (task.failed or 0) + 1 end
    return self:_terminal(task, "failed", error_value(err, "download failed"))
end

function DownloadManager:_set_handle(task, generation, handle)
    if self:_valid_callback(task, generation) then task.handle = handle end
end

function DownloadManager:_build(task, source, chapters)
    local bodies = {}
    for _, chapter in ipairs(chapters) do
        local body, cache_error = self.cache:readBody(task.source_id, task.book_id, chapter)
        if type(body) ~= "string" or body == "" then return self:_fail(task, cache_error, true) end
        bodies[chapter.uid] = body
    end
    local cover = self.cache.readCover and self.cache:readCover(task.source_id, task.book_id) or nil
    local assets = { modified = timestamp(task.created_at), source = source }
    if type(cover) == "string" and cover ~= "" then assets.cover = { data = cover, media_type = "image/jpeg" } end
    local ok, path, build_error = pcall(self.builder.write, self.builder, task.final_path, task.book, chapters, bodies, assets)
    if not ok then return self:_fail(task, path) end
    if not path then return self:_fail(task, build_error) end
    task.final_path = path
    return self:_terminal(task, "completed")
end

function DownloadManager:_download(task, source, chapters, index)
    if self.active ~= task.id or task.status ~= "running" then return end
    if task.cancel_requested then return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled")) end
    if index > #chapters then return self:_build(task, source, chapters) end
    local chapter = chapters[index]
    task.current = chapter.uid; self:_persist(task)
    local cached = self.cache:readBody(task.source_id, task.book_id, chapter)
    if type(cached) == "string" and cached ~= "" then
        task.completed = (task.completed or 0) + 1
        return self:_download(task, source, chapters, index + 1)
    end
    local generation = task.generation
    local handle = self.service:getContent(source, task.book, chapter, function(result, err)
        if not self:_valid_callback(task, generation) then return end
        task.handle = nil
        if err or type(result) ~= "table" or type(result.content) ~= "string" then return self:_fail(task, err, true) end
        local cleaned, clean_error = Cleaner.normalize(result.content)
        if not cleaned then return self:_fail(task, clean_error, true) end
        local saved, save_error = self.cache:writeBody(task.source_id, task.book_id, chapter, cleaned)
        if not saved then return self:_fail(task, save_error, true) end
        task.completed = (task.completed or 0) + 1
        self:_download(task, source, chapters, index + 1)
    end)
    self:_set_handle(task, generation, handle)
end

function DownloadManager:_with_chapters(task, source, values)
    local chapters = {}
    for _, chapter in ipairs(values or {}) do if type(chapter) == "table" and chapter.vip ~= true then chapters[#chapters + 1] = chapter end end
    if #chapters == 0 then return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "download catalog has no non-VIP chapters")) end
    task.chapters, task.total, task.completed, task.failed = copy(values), #chapters, 0, 0
    self:_persist(task)
    return self:_download(task, source, chapters, 1)
end

function DownloadManager:_catalog(task, source)
    local values = type(task.chapters) == "table" and task.chapters or nil
    if not values or #values == 0 then
        values = self.storage:listChapters(task.book_id)
        if type(values) == "table" and #values == 0 then values = nil end
    end
    if values then return self:_with_chapters(task, source, values) end
    local generation = task.generation
    local handle = self.service:getChapters(source, task.book, function(chapters, err)
        if not self:_valid_callback(task, generation) then return end
        task.handle = nil
        if err or type(chapters) ~= "table" then return self:_fail(task, err) end
        local persisted, persist_error = self.storage:replaceChapters(task.book_id, chapters)
        if not persisted then return self:_fail(task, persist_error) end
        if self.cache.writeCatalog then
            local cached, cache_error = self.cache:writeCatalog(task.source_id, task.book_id, { chapters = chapters })
            if not cached then return self:_fail(task, cache_error) end
        end
        task.chapters = copy(chapters)
        self:_with_chapters(task, source, chapters)
    end)
    self:_set_handle(task, generation, handle)
end

function DownloadManager:_start(task)
    self.active = task.id
    task.status, task.cancel_requested = "running", false
    task.generation = (task.generation or 0) + 1
    task.current, task.completed, task.failed, task.error = nil, 0, 0, nil
    local persisted, persist_error = self:_persist(task)
    if not persisted then self.active = nil; self:_notify_terminal(task, persist_error); return self:_schedulePump() end
    self.standby:acquire()
    local source = self:_source(task)
    if not source then return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "download source is unavailable")) end
    return self:_catalog(task, source)
end

function DownloadManager:_pump()
    self.pump_scheduled = false
    if self.active then return end
    for _, id in ipairs(self.order) do
        local task = self.tasks[id]
        if task and task.status == "queued" then return self:_start(task) end
    end
end

function DownloadManager:_schedulePump()
    if self.active or self.pump_scheduled then return end
    if self.scheduler and type(self.scheduler.scheduleIn) == "function" then
        self.pump_scheduled = true
        self.scheduler:scheduleIn(0, function() self:_pump() end)
    else self:_pump() end
end

function DownloadManager:enqueue(book, chapters, callback)
    if type(chapters) == "function" then callback, chapters = chapters, nil end
    if type(book) ~= "table" or type(book.id) ~= "string" or type(book.source_id) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "download requires a normalized book")
    end
    if chapters ~= nil and type(chapters) ~= "table" then return nil, Errors.new(Errors.INVALID_INPUT, "chapters must be a table") end
    self.sequence = self.sequence + 1
    local created = self.now()
    local id = "download-" .. Identity.hash(book.id .. "\n" .. tostring(created) .. "\n" .. tostring(self.sequence))
    while self.tasks[id] do self.sequence = self.sequence + 1; id = "download-" .. Identity.hash(id .. self.sequence) end
    local task = { id = id, book_id = book.id, source_id = book.source_id, book = copy(book), chapters = copy(chapters),
        status = "queued", total = 0, completed = 0, failed = 0, current = nil, cancel_requested = false,
        created_at = created, updated_at = created,
        final_path = self.output_root .. "/" .. EpubBuilder.exportFilename(book),
    }
    local saved, save_error = self:_persist(task)
    if not saved then return nil, save_error end
    self.tasks[id], self.order[#self.order + 1] = task, id
    if type(callback) == "function" then self.callbacks[id] = callback end
    self:_schedulePump()
    return copy(task)
end

function DownloadManager:get(id)
    local task = self.tasks[id]
    return task and copy(task) or nil
end

function DownloadManager:list()
    local values = {}
    for _, id in ipairs(self.order) do if self.tasks[id] then values[#values + 1] = copy(self.tasks[id]) end end
    table.sort(values, function(a, b)
        if (a.created_at or 0) == (b.created_at or 0) then return a.id < b.id end
        return (a.created_at or 0) > (b.created_at or 0)
    end)
    return values
end

function DownloadManager:cancel(id)
    local task = self.tasks[id]
    if not task then return nil, Errors.new(Errors.INVALID_INPUT, "download task does not exist") end
    if task.status == "cancelled" or task.status == "cancelling" then return true end
    if terminal[task.status] then return false end
    if task.status == "queued" or task.status == "interrupted" then
        task.generation = (task.generation or 0) + 1
        return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled"))
    end
    task.status, task.cancel_requested = "cancelling", true
    task.generation = (task.generation or 0) + 1
    self:_persist(task)
    if task.handle and type(task.handle.cancel) == "function" then pcall(task.handle.cancel, task.handle) end
    return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled"))
end

function DownloadManager:_requeue(id, allowed)
    local task = self.tasks[id]
    if not task then return nil, Errors.new(Errors.INVALID_INPUT, "download task does not exist") end
    if not allowed[task.status] then return false end
    task.status, task.cancel_requested, task.current = "queued", false, nil
    task.completed, task.failed, task.error = 0, 0, nil
    self.callback_delivered[id] = nil
    local saved, save_error = self:_persist(task); if not saved then return nil, save_error end
    self:_schedulePump(); return true
end

function DownloadManager:retry(id) return self:_requeue(id, { failed = true, cancelled = true }) end
function DownloadManager:resume(id) return self:_requeue(id, { interrupted = true }) end

function DownloadManager:open(id)
    local task = self.tasks[id]
    if not task or task.status ~= "completed" or type(task.final_path) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "completed EPUB is unavailable")
    end
    if type(self.open_final) ~= "function" then return task.final_path end
    return self.open_final(task.final_path, copy(task))
end

return DownloadManager
