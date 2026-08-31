local Cleaner = require("legado.lib.content_cleaner")
local EpubBuilder = require("legado.lib.epub_builder")
local Errors = require("legado.lib.errors")
local Identity = require("legado.lib.identity")
local Models = require("legado.lib.models")

local DownloadManager = {}
DownloadManager.__index = DownloadManager

local terminal = { cancelled = true, failed = true, completed = true }
local CLEAR = {}

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

local function durable_task(task)
    local value = copy(task)
    value.handle, value.request_slot = nil, nil
    return value
end

local function published_diagnostic(value)
    if type(value) ~= "table" then return nil end
    return {
        code = value.code or Errors.STORAGE_ERROR,
        message = "EPUB published with a cleanup warning",
        published = true,
    }
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
        tasks = {}, order = {}, queue = {}, callbacks = {}, callback_delivered = {}, active = nil,
        sequence = 0, queue_sequence = 0, pump_scheduled = false,
        persistence_blocked = false, init_error = nil,
    }, DownloadManager)
    local recovered = false
    for _, task in ipairs(self.storage:listDownloadTasks() or {}) do
        if type(task) == "table" and type(task.id) == "string" then
            self.tasks[task.id] = task; self.order[#self.order + 1] = task.id
            if task.status == "running" or task.status == "cancelling" then
                local persisted, persist_error = self:_transition(task, {
                    status = "interrupted", cancel_requested = false, current = CLEAR,
                    error = { code = Errors.STORAGE_ERROR, message = "download interrupted by restart" },
                })
                if not persisted then
                    local fallback_saved, fallback_error = self:_transition(task, { status = "failed", cancel_requested = false, current = CLEAR,
                        error = { code = persist_error.code, message = persist_error.message } })
                    if not fallback_saved then
                        self.persistence_blocked = true
                        self.init_error = error_value(fallback_error or persist_error, "startup persistence recovery failed")
                    end
                end
                recovered = true
            end
        end
    end
    if recovered and type(self.standby.releaseAll) == "function" then self.standby:releaseAll() end
    local queued = {}
    for _, task in pairs(self.tasks) do
        self.queue_sequence = math.max(self.queue_sequence, tonumber(task.queue_sequence) or 0)
        if task.status == "queued" then queued[#queued + 1] = task end
    end
    table.sort(queued, function(a, b)
        local aq, bq = tonumber(a.queue_sequence), tonumber(b.queue_sequence)
        if aq and bq and aq ~= bq then return aq < bq end
        if (a.created_at or 0) ~= (b.created_at or 0) then return (a.created_at or 0) < (b.created_at or 0) end
        return a.id < b.id
    end)
    for _, task in ipairs(queued) do self.queue[#self.queue + 1] = task.id end
    if #self.queue > 0 and not self.persistence_blocked then self:_schedulePump() end
    return self
end

function DownloadManager:_persist(task)
    local saved, err = self.storage:putDownloadTask(durable_task(task))
    if not saved then return nil, error_value(err, "cannot persist download task") end
    self.tasks[task.id] = task
    return true
end

function DownloadManager:_transition(task, changes)
    local previous = { updated_at = task.updated_at }
    for key, value in pairs(changes or {}) do
        previous[key] = task[key]
        if value == CLEAR then task[key] = nil else task[key] = value end
    end
    task.updated_at = self.now()
    local saved, err = self:_persist(task)
    if saved then return true end
    task.updated_at = previous.updated_at
    for key in pairs(changes or {}) do task[key] = previous[key] end
    return nil, err
end

function DownloadManager:_release_active(task)
    if self.active == task.id then
        self.active = nil
        self.standby:release()
    end
end

function DownloadManager:_block_persistence(task, err)
    err = error_value(err, "download persistence is unavailable")
    self.persistence_blocked, self.init_error = true, err
    self:_cancel_request(task)
    self:_release_active(task)
    self.pump_scheduled = false
    return nil, err
end

function DownloadManager:_interrupt_for_persistence(task, persist_error)
    persist_error = error_value(persist_error, "cannot persist download transition")
    self:_cancel_request(task)
    local error_record = { code = persist_error.code, message = persist_error.message }
    local saved, fallback_error = self:_transition(task, {
        status = "interrupted", current = CLEAR, cancel_requested = false, error = error_record,
    })
    if not saved then
        saved, fallback_error = self:_transition(task, {
            status = "failed", current = CLEAR, cancel_requested = false,
            error = { code = fallback_error.code, message = fallback_error.message },
        })
    end
    if saved then
        self:_release_active(task)
        self:_notify_terminal(task, persist_error)
        self:_schedulePump()
    else
        self:_block_persistence(task, fallback_error or persist_error)
    end
    return nil, persist_error
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

function DownloadManager:_terminal(task, status, err, changes)
    if terminal[task.status] and task.status == status then return true end
    changes = changes or {}
    changes.status, changes.current = status, CLEAR
    changes.cancel_requested = status == "cancelled"
    changes.error = err and { code = err.code or Errors.STORAGE_ERROR, message = err.message or tostring(err) } or CLEAR
    local persisted, persist_error = self:_transition(task, changes)
    if not persisted then return self:_interrupt_for_persistence(task, persist_error) end
    task.handle, task.request_slot = nil, nil
    self:_release_active(task)
    self:_notify_terminal(task, err)
    self:_schedulePump()
    return true
end

function DownloadManager:_fail(task, err, chapter_failed)
    return self:_terminal(task, "failed", error_value(err, "download failed"),
        chapter_failed and { failed = (task.failed or 0) + 1 } or nil)
end

function DownloadManager:_cancel_request(task)
    local slot = task.request_slot
    local handle = slot and slot.handle or task.handle
    if slot then slot.active = false end
    task.request_slot, task.handle = nil, nil
    if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
end

function DownloadManager:_request(task, generation, start, callback)
    local slot = { generation = generation, active = true, completed = false }
    task.request_slot, task.handle = slot, nil
    local function deliver(...)
        if task.request_slot ~= slot or not slot.active or not self:_valid_callback(task, generation) then return end
        slot.active, slot.completed = false, true
        task.request_slot, task.handle = nil, nil
        return callback(...)
    end
    local ok, handle = pcall(start, deliver)
    if not ok then
        deliver(nil, error_value(handle, "download request failed"))
        return nil
    end
    if task.request_slot == slot and slot.active and self:_valid_callback(task, generation) then
        slot.handle, task.handle = handle, handle
    elseif not slot.completed and handle and type(handle.cancel) == "function" then
        pcall(handle.cancel, handle)
    end
    return handle
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
    if type(cover) == "string" and cover ~= "" then assets.cover = { data = cover } end
    local ok, path, build_error = pcall(self.builder.write, self.builder, task.final_path, task.book, chapters, bodies, assets)
    if not ok then return self:_fail(task, path) end
    if not path then return self:_fail(task, build_error) end
    task.final_path = path
    local warning = published_diagnostic(build_error)
    return self:_terminal(task, "completed", nil, warning and {
        warning = warning, published_diagnostic = warning,
    } or nil)
end

function DownloadManager:_download(task, source, chapters, index)
    if self.active ~= task.id or task.status ~= "running" then return end
    if task.cancel_requested then return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled")) end
    if index > #chapters then return self:_build(task, source, chapters) end
    local chapter = chapters[index]
    local current_saved, current_error = self:_transition(task, { current = chapter.uid })
    if not current_saved then return self:_interrupt_for_persistence(task, current_error) end
    local cached = self.cache:readBody(task.source_id, task.book_id, chapter)
    if type(cached) == "string" and cached ~= "" then
        local counter_saved, counter_error = self:_transition(task, { completed = (task.completed or 0) + 1 })
        if not counter_saved then return self:_interrupt_for_persistence(task, counter_error) end
        return self:_download(task, source, chapters, index + 1)
    end
    local generation = task.generation
    return self:_request(task, generation, function(callback)
        return self.service:getContent(source, task.book, chapter, callback)
    end, function(result, err)
        if err or type(result) ~= "table" or type(result.content) ~= "string" then return self:_fail(task, err, true) end
        local cleaned, clean_error = Cleaner.normalize(result.content)
        if not cleaned then return self:_fail(task, clean_error, true) end
        local saved, save_error = self.cache:writeBody(task.source_id, task.book_id, chapter, cleaned)
        if not saved then return self:_fail(task, save_error, true) end
        local counter_saved, counter_error = self:_transition(task, { completed = (task.completed or 0) + 1 })
        if not counter_saved then return self:_interrupt_for_persistence(task, counter_error) end
        self:_download(task, source, chapters, index + 1)
    end)
end

function DownloadManager:_with_chapters(task, source, values)
    local chapters = {}
    for _, chapter in ipairs(values or {}) do if type(chapter) == "table" and chapter.vip ~= true then chapters[#chapters + 1] = chapter end end
    if #chapters == 0 then return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "download catalog has no non-VIP chapters")) end
    local catalog_saved, catalog_error = self:_transition(task, {
        chapters = copy(values), total = #chapters, completed = 0, failed = 0,
    })
    if not catalog_saved then return self:_interrupt_for_persistence(task, catalog_error) end
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
    return self:_request(task, generation, function(callback)
        return self.service:getChapters(source, task.book, callback)
    end, function(chapters, err)
        if err or type(chapters) ~= "table" then return self:_fail(task, err) end
        local persisted, persist_error = self.storage:replaceChapters(task.book_id, chapters)
        if not persisted then return self:_fail(task, persist_error) end
        if self.cache.writeCatalog then
            local cached, cache_error = self.cache:writeCatalog(task.source_id, task.book_id, { chapters = chapters })
            if not cached then return self:_fail(task, cache_error) end
        end
        self:_with_chapters(task, source, chapters)
    end)
end

function DownloadManager:_start(task)
    self.active = task.id
    local persisted, persist_error = self:_transition(task, {
        status = "running", cancel_requested = false, generation = (task.generation or 0) + 1,
        current = CLEAR, completed = 0, failed = 0, error = CLEAR,
        warning = CLEAR, published_diagnostic = CLEAR,
    })
    if not persisted then return self:_interrupt_for_persistence(task, persist_error) end
    self.standby:acquire()
    local source = self:_source(task)
    if not source then return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "download source is unavailable")) end
    return self:_catalog(task, source)
end

function DownloadManager:_pump()
    self.pump_scheduled = false
    if self.persistence_blocked then return end
    if self.active then return end
    while #self.queue > 0 do
        local id = table.remove(self.queue, 1)
        local task = self.tasks[id]
        if task and task.status == "queued" then return self:_start(task) end
    end
end

function DownloadManager:_schedulePump()
    if self.persistence_blocked or self.active or self.pump_scheduled then return end
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
    self.queue_sequence = self.queue_sequence + 1
    local task = { id = id, book_id = book.id, source_id = book.source_id, book = copy(book), chapters = copy(chapters),
        status = "queued", total = 0, completed = 0, failed = 0, current = nil, cancel_requested = false,
        created_at = created, updated_at = created, queue_sequence = self.queue_sequence,
        final_path = self.output_root .. "/" .. EpubBuilder.exportFilename(book),
    }
    local saved, save_error = self:_persist(task)
    if not saved then return nil, save_error end
    self.tasks[id], self.order[#self.order + 1], self.queue[#self.queue + 1] = task, id, id
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
    if self.persistence_blocked then return nil, self.init_error end
    if task.status == "cancelled" or task.status == "cancelling" then return true end
    if terminal[task.status] then return false end
    if task.status == "queued" or task.status == "interrupted" then
        task.generation = (task.generation or 0) + 1
        return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled"))
    end
    local persisted, persist_error = self:_transition(task, {
        status = "cancelling", cancel_requested = true, generation = (task.generation or 0) + 1,
    })
    if not persisted then return self:_interrupt_for_persistence(task, persist_error) end
    self:_cancel_request(task)
    return self:_terminal(task, "cancelled", Errors.new(Errors.CANCELLED, "download cancelled"))
end

function DownloadManager:_requeue(id, allowed)
    local task = self.tasks[id]
    if not task then return nil, Errors.new(Errors.INVALID_INPUT, "download task does not exist") end
    if self.persistence_blocked then return nil, self.init_error end
    if not allowed[task.status] then return false end
    self.queue_sequence = self.queue_sequence + 1
    local saved, save_error = self:_transition(task, {
        status = "queued", cancel_requested = false, current = CLEAR, completed = 0, failed = 0,
        error = CLEAR, warning = CLEAR, published_diagnostic = CLEAR, queue_sequence = self.queue_sequence,
    })
    if not saved then return nil, save_error end
    self.callback_delivered[id] = nil
    self.queue[#self.queue + 1] = id
    self:_schedulePump(); return true
end

function DownloadManager:retry(id) return self:_requeue(id, { failed = true, cancelled = true }) end
function DownloadManager:resume(id) return self:_requeue(id, { interrupted = true }) end

function DownloadManager:recoverPersistence()
    if not self.persistence_blocked then return true end
    for _, id in ipairs(self.order) do
        local task = self.tasks[id]
        if task and (task.status == "running" or task.status == "cancelling") then
            local saved, err = self:_transition(task, {
                status = "interrupted", current = CLEAR, cancel_requested = false,
                error = { code = Errors.STORAGE_ERROR, message = "download interrupted while persistence was unavailable" },
            })
            if not saved then
                self.init_error = error_value(err, "download persistence is unavailable")
                return nil, self.init_error
            end
        end
    end
    self.persistence_blocked, self.init_error = false, nil
    self:_schedulePump()
    return true
end

DownloadManager.retryPersistence = DownloadManager.recoverPersistence

function DownloadManager:open(id)
    local task = self.tasks[id]
    if not task or task.status ~= "completed" or type(task.final_path) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "completed EPUB is unavailable")
    end
    if type(self.open_final) ~= "function" then return task.final_path end
    return self.open_final(task.final_path, copy(task))
end

return DownloadManager
