local Cleaner = require("legado.lib.content_cleaner")
local EpubBuilder = require("legado.lib.epub_builder")
local Errors = require("legado.lib.errors")
local Identity = require("legado.lib.identity")
local Models = require("legado.lib.models")
local DownloadWorker = require('legado.lib.download_worker')

local DownloadManager = {}
DownloadManager.__index = DownloadManager

local terminal = { cancelled = true, failed = true, completed = true }
local CLEAR = {}
local MAX_SAFE_QUEUE_SEQUENCE = 9007199254740991
local MAX_SAFE_QUEUE_SEQUENCE_TEXT = "9007199254740991"
local RESTORABLE_STATUS = {
    queued = true, running = true, cancelling = true, interrupted = true,
    failed = true, cancelled = true, completed = true,
}
local KNOWN_ERROR_CODE = {
    [Errors.INVALID_INPUT] = true, [Errors.STORAGE_ERROR] = true,
    [Errors.MIGRATION_ERROR] = true, [Errors.NETWORK_ERROR] = true,
    [Errors.TIMEOUT] = true, [Errors.CANCELLED] = true,
    [Errors.RESPONSE_TOO_LARGE] = true, [Errors.ENCODING_ERROR] = true,
    [Errors.PARSE_ERROR] = true, [Errors.UNSUPPORTED_RULE] = true,
    [Errors.SITE_REJECTED] = true,
}

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
    local code, sequence_exhausted = Errors.STORAGE_ERROR, false
    if type(value) == "table" then
        local candidate = rawget(value, "code")
        if type(candidate) == "string" and KNOWN_ERROR_CODE[candidate] then code = candidate end
        local details = rawget(value, "details")
        if type(details) == "table" then
            sequence_exhausted = rawget(details, "sequence_exhausted") == true
        end
    end
    return Errors.new(code, fallback or "download failed",
        sequence_exhausted and { sequence_exhausted = true } or nil)
end

local function durable_task(task)
    local value = {}
    for key,child in pairs(task) do
        if key~='handle' and key~='request_slot' then value[key]=copy(child) end
    end
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

local function valid_queue_sequence(value)
    local numeric
    if type(value) == "number" then
        numeric = value
    elseif type(value) == "string" then
        if not value:match("^%d+$") then return nil end
        local digits = value:gsub("^0+", "")
        if digits == "" or #digits > #MAX_SAFE_QUEUE_SEQUENCE_TEXT
            or (#digits == #MAX_SAFE_QUEUE_SEQUENCE_TEXT and digits > MAX_SAFE_QUEUE_SEQUENCE_TEXT) then
            return nil
        end
        numeric = tonumber(digits)
    else
        return nil
    end
    if not numeric or numeric ~= numeric or numeric == math.huge or numeric == -math.huge
        or numeric <= 0 or numeric > MAX_SAFE_QUEUE_SEQUENCE or numeric % 1 ~= 0
        or numeric + 1 <= numeric then return nil end
    return numeric
end

local function sequence_error()
    return Errors.new(Errors.STORAGE_ERROR, "download queue sequence space is exhausted", {
        sequence_exhausted = true,
    })
end

local function is_sequence_error(value)
    return type(value) == "table" and type(value.details) == "table"
        and value.details.sequence_exhausted == true
end

local function queued_before(a, b)
    local aq, bq = valid_queue_sequence(a.queue_sequence), valid_queue_sequence(b.queue_sequence)
    if aq ~= nil or bq ~= nil then
        if aq == nil then return false end
        if bq == nil then return true end
        if aq ~= bq then return aq < bq end
    end
    local created_a, created_b = tonumber(a.created_at) or 0, tonumber(b.created_at) or 0
    if created_a ~= created_a then created_a = 0 end
    if created_b ~= created_b then created_b = 0 end
    if created_a ~= created_b then return created_a < created_b end
    return tostring(a.id or "") < tostring(b.id or "")
end

local function sorted_queued_tasks(tasks)
    local queued = {}
    for _, task in pairs(tasks) do if task.status == "queued" then queued[#queued + 1] = task end end
    table.sort(queued, queued_before)
    return queued
end

local function sorted_tasks(tasks)
    local values = {}
    for _, task in pairs(tasks) do values[#values + 1] = task end
    table.sort(values, function(a, b) return a.id < b.id end)
    return values
end

function DownloadManager:_migrateAndRebuildQueue()
    local maximum = valid_queue_sequence(self.queue_sequence) or 0
    for _, task in pairs(self.tasks) do
        maximum = math.max(maximum, valid_queue_sequence(task.queue_sequence) or 0)
    end
    self.queue_sequence = maximum
    local seen, legacy, normalize = {}, {}, {}
    for _, task in ipairs(sorted_tasks(self.tasks)) do
        local raw_sequence = task.queue_sequence
        local sequence = valid_queue_sequence(raw_sequence)
        if task.status ~= "queued" and raw_sequence ~= nil then
            if sequence ~= nil and type(raw_sequence) == "string" then
                normalize[task] = sequence
            elseif sequence == nil then
                normalize[task] = CLEAR
            end
        end
    end
    for _, task in ipairs(sorted_queued_tasks(self.tasks)) do
        local sequence = valid_queue_sequence(task.queue_sequence)
        if sequence == nil or seen[sequence] then
            legacy[task] = true
        else
            seen[sequence] = true
            if type(task.queue_sequence) == "string" then normalize[task] = sequence end
        end
    end
    for _, task in ipairs(sorted_tasks(self.tasks)) do
        local normalized_sequence = normalize[task]
        if normalized_sequence then
            local saved, err = self:_transition(task, { queue_sequence = normalized_sequence })
            if not saved then return nil, err end
        end
    end
    for _, task in ipairs(sorted_queued_tasks(self.tasks)) do
        if legacy[task] then
            if maximum >= MAX_SAFE_QUEUE_SEQUENCE then return nil, sequence_error() end
            local next_sequence = maximum + 1
            if next_sequence <= maximum or valid_queue_sequence(next_sequence) == nil then
                return nil, sequence_error()
            end
            local saved, err = self:_transition(task, { queue_sequence = next_sequence })
            if not saved then return nil, err end
            maximum = next_sequence
            self.queue_sequence = maximum
        end
    end
    self.queue_sequence = maximum
    self.queue = {}
    for _, task in ipairs(sorted_queued_tasks(self.tasks)) do self.queue[#self.queue + 1] = task.id end
    return true
end


local function plain_persisted_copy(value, seen, depth, budget)
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "string" then return value end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil, "non-finite persisted number"
        end
        return value
    end
    if value_type ~= "table" then return nil, "unsupported persisted value" end
    depth = (depth or 0) + 1
    if depth > 64 then return nil, "persisted value nesting is too deep" end
    seen, budget = seen or {}, budget or { count = 0 }
    if seen[value] then return nil, "cyclic persisted value" end
    seen[value] = true
    local result, key = {}, nil
    while true do
        local next_key, child = next(value, key)
        if next_key == nil then break end
        key = next_key
        budget.count = budget.count + 1
        if budget.count > 100000 then seen[value] = nil; return nil, "persisted value is too large" end
        local key_type = type(next_key)
        if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
            seen[value] = nil
            return nil, "unsupported persisted key"
        end
        if key_type == "number" and (next_key ~= next_key or next_key == math.huge or next_key == -math.huge) then
            seen[value] = nil
            return nil, "non-finite persisted key"
        end
        local copied, copy_error = plain_persisted_copy(child, seen, depth, budget)
        if copy_error then seen[value] = nil; return nil, copy_error end
        rawset(result, next_key, copied)
    end
    seen[value] = nil
    return result
end

local function valid_plain_array(value, table_items)
    if type(value) ~= "table" then return false end
    local count, highest, key = 0, 0, nil
    while true do
        local next_key, child = next(value, key)
        if next_key == nil then break end
        key = next_key
        if type(next_key) ~= "number" or next_key < 1 or next_key % 1 ~= 0
            or (table_items and type(child) ~= "table") then return false end
        count, highest = count + 1, math.max(highest, next_key)
    end
    return count == highest
end

local function valid_restored_book(value, book_id, source_id)
    if type(value) ~= "table" then return false end
    local id, source = rawget(value, "id"), rawget(value, "source_id")
    if type(id) ~= "string" or id == "" or type(source) ~= "string" or source == ""
        or (book_id ~= nil and id ~= book_id) or (source_id ~= nil and source ~= source_id) then return false end
    for _, field in ipairs({
        "source_name", "name", "author", "url", "cover_url", "intro",
        "kind", "last_chapter", "toc_url",
    }) do
        local child = rawget(value, field)
        if child ~= nil and type(child) ~= "string" then return false end
    end
    local word_count = rawget(value, "word_count")
    if word_count ~= nil and (type(word_count) ~= "number" or word_count ~= word_count or word_count < 0) then
        return false
    end
    return true
end

local function valid_restored_chapters(value)
    if not valid_plain_array(value, true) then return false end
    local index = 1
    while rawget(value, index) ~= nil do
        local chapter = rawget(value, index)
        local uid, chapter_index = rawget(chapter, "uid"), rawget(chapter, "index")
        if type(uid) ~= "string" or uid == "" or type(chapter_index) ~= "number"
            or chapter_index < 1 or chapter_index % 1 ~= 0 or chapter_index >= MAX_SAFE_QUEUE_SEQUENCE then
            return false
        end
        for _, field in ipairs({ "book_id", "source_id", "title", "url" }) do
            local child = rawget(chapter, field)
            if child ~= nil and type(child) ~= "string" then return false end
        end
        local vip = rawget(chapter, "vip")
        if vip ~= nil and type(vip) ~= "boolean" then return false end
        index = index + 1
    end
    return true
end

local function valid_restored_diagnostic(value)
    if type(value) ~= "table" then return false end
    local code, message = rawget(value, "code"), rawget(value, "message")
    return type(code) == "string" and code ~= "" and type(message) == "string"
end

local function normalized_counter(value, default)
    if value == nil then return default end
    if type(value) ~= "number" or value ~= value or value < 0 or value % 1 ~= 0
        or value >= MAX_SAFE_QUEUE_SEQUENCE then return nil end
    return value
end

local function validate_download_listing(value)
    if type(value) ~= "table" then
        return nil, Errors.new(Errors.STORAGE_ERROR, "invalid persisted download collection")
    end
    local normalized = plain_persisted_copy(value)
    if not normalized then
        return nil, Errors.new(Errors.STORAGE_ERROR, "invalid persisted download collection")
    end
    value = normalized
    local count, highest = 0, 0
    local collection_key = nil
    while true do
        local key = next(value, collection_key)
        if key == nil then break end
        collection_key = key
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return nil, Errors.new(Errors.STORAGE_ERROR, "invalid persisted download collection")
        end
        count, highest = count + 1, math.max(highest, key)
    end
    if highest ~= count then
        return nil, Errors.new(Errors.STORAGE_ERROR, "invalid persisted download collection")
    end
    local tasks, order, ids = {}, {}, {}
    for index = 1, count do
        local task = rawget(value, index)
        local id = type(task) == "table" and rawget(task, "id") or nil
        local status = type(task) == "table" and rawget(task, "status") or nil
        local queue_sequence = type(task) == "table" and rawget(task, "queue_sequence") or nil
        local queue_type = type(queue_sequence)
        local created_at = type(task) == "table" and normalized_counter(rawget(task, "created_at"), 0) or nil
        local updated_at = type(task) == "table" and normalized_counter(rawget(task, "updated_at"), 0) or nil
        local generation = type(task) == "table" and normalized_counter(rawget(task, "generation"), 0) or nil
        local total = type(task) == "table" and normalized_counter(rawget(task, "total"), 0) or nil
        local completed = type(task) == "table" and normalized_counter(rawget(task, "completed"), 0) or nil
        local failed = type(task) == "table" and normalized_counter(rawget(task, "failed"), 0) or nil
        local cancel_requested = type(task) == "table" and rawget(task, "cancel_requested") or nil
        local current = type(task) == "table" and rawget(task, "current") or nil
        local book = type(task) == "table" and rawget(task, "book") or nil
        local chapters = type(task) == "table" and rawget(task, "chapters") or nil
        local error_record = type(task) == "table" and rawget(task, "error") or nil
        local warning = type(task) == "table" and rawget(task, "warning") or nil
        local diagnostic = type(task) == "table" and rawget(task, "published_diagnostic") or nil
        local final_path = type(task) == "table" and rawget(task, "final_path") or nil
        local kind = type(task) == "table" and rawget(task, "kind") or nil
        local end_index = type(task) == "table" and rawget(task, "end_index") or nil
        local book_id = type(task) == "table" and rawget(task, "book_id") or nil
        local source_id = type(task) == "table" and rawget(task, "source_id") or nil
        local requires_book = status ~= "completed"
        if type(task) ~= "table" or type(id) ~= "string" or id == ""
            or type(status) ~= "string" or not RESTORABLE_STATUS[status] or ids[id]
            or (queue_type ~= "nil" and queue_type ~= "number" and queue_type ~= "string")
            or created_at == nil or updated_at == nil or generation == nil
            or total == nil or completed == nil or failed == nil
            or completed > total or failed > total or completed > total - failed
            or (cancel_requested ~= nil and type(cancel_requested) ~= "boolean")
            or (current ~= nil and type(current) ~= "string")
            or (book_id ~= nil and (type(book_id) ~= "string" or book_id == ""))
            or (source_id ~= nil and (type(source_id) ~= "string" or source_id == ""))
            or (requires_book and (book_id == nil or source_id == nil or book == nil))
            or (book ~= nil and not valid_restored_book(book, book_id, source_id))
            or (chapters ~= nil and not valid_restored_chapters(chapters))
            or (error_record ~= nil and not valid_restored_diagnostic(error_record))
            or (warning ~= nil and not valid_restored_diagnostic(warning))
            or (diagnostic ~= nil and not valid_restored_diagnostic(diagnostic))
            or (final_path ~= nil and type(final_path) ~= "string")
            or (kind ~= nil and kind ~= "cache" and kind ~= "epub")
            or (end_index ~= nil and (kind ~= "cache" or type(end_index) ~= "number"
                or end_index < 1 or end_index % 1 ~= 0 or end_index >= MAX_SAFE_QUEUE_SEQUENCE)) then
            return nil, Errors.new(Errors.STORAGE_ERROR, "invalid persisted download task", { index = index })
        end
        rawset(task, "created_at", created_at)
        rawset(task, "updated_at", updated_at)
        rawset(task, "generation", generation)
        rawset(task, "total", total)
        rawset(task, "completed", completed)
        rawset(task, "failed", failed)
        rawset(task, "cancel_requested", cancel_requested == true)
        ids[id] = true
        tasks[id], order[#order + 1] = task, id
    end
    return tasks, order
end

function DownloadManager:_readPersistedTasks()
    local ok, value = pcall(function() return self.storage:listDownloadTasks() end)
    if not ok then
        return nil, error_value(value, "cannot load persisted download tasks")
    end
    local validated, tasks, order_or_error = pcall(validate_download_listing, value)
    if not validated then
        return nil, error_value(tasks, "cannot validate persisted download tasks")
    end
    return tasks, order_or_error
end

function DownloadManager:_restoreFromStorage(require_sequence_capacity)
    local tasks, order_or_error = self:_readPersistedTasks()
    if not tasks then return nil, order_or_error, true end
    self.tasks, self.order, self.queue = tasks, order_or_error, {}
    self.active, self.pump_scheduled, self.queue_sequence = nil, false, 0
    local recovered = false
    for _, id in ipairs(self.order) do
        local task = self.tasks[id]
        self:_cleanInterruptedExport(task)
        if task.status == "running" or task.status == "cancelling" then
            local persisted, persist_error = self:_transition(task, {
                status = "interrupted", cancel_requested = false, current = CLEAR,
                error = { code = Errors.STORAGE_ERROR, message = "download interrupted by restart" },
            })
            if not persisted then
                local fallback_saved, fallback_error = self:_transition(task, {
                    status = "failed", cancel_requested = false, current = CLEAR,
                    error = { code = persist_error.code, message = persist_error.message },
                })
                if not fallback_saved then
                    if type(self.standby.releaseAll) == "function" then self.standby:releaseAll() end
                    return nil, error_value(fallback_error or persist_error, "startup persistence recovery failed")
                end
            end
            recovered = true
        end
    end
    if recovered and type(self.standby.releaseAll) == "function" then self.standby:releaseAll() end
    local migrated, migration_error = self:_migrateAndRebuildQueue()
    if not migrated then
        return nil, error_value(migration_error, "legacy download queue migration failed"),
            is_sequence_error(migration_error)
    end
    if require_sequence_capacity then
        local _, capacity_error = self:_nextQueueSequence()
        if capacity_error then return nil, capacity_error, true end
    end
    return true
end

function DownloadManager.new(options)
    options = options or {}
    assert(options.storage, "DownloadManager requires storage")
    assert(options.cache, "DownloadManager requires cache")
    assert(options.book_service, "DownloadManager requires book_service")
    assert(options.builder, "DownloadManager requires builder")
    assert(options.standby, "DownloadManager requires standby guard")
    local self = setmetatable({
        storage = options.storage, cache = options.cache, offline_cache = options.offline_cache,
        service = options.book_service,
        builder = options.builder, standby = options.standby, scheduler = options.scheduler,
        output_root = tostring(options.output_root or "downloads"):gsub("[/\\]+$", ""),
        now = options.now or os.time, open_final = options.open_final,
        tasks = {}, order = {}, queue = {}, callbacks = {}, callback_delivered = {}, active = nil,
        sequence = 0, queue_sequence = 0, pump_scheduled = false,
        persistence_blocked = false, init_error = nil, reload_required = false,
        sequence_allocation_blocked = false,
        workers={},checkpoints={},chapter_concurrency=options.chapter_concurrency or 1,
        checkpoint_chapters=math.max(1,math.min(50,tonumber(options.checkpoint_chapters) or 10)),
        export_subprocess=options.export_subprocess,
    }, DownloadManager)
    local restored, restore_error, reload_required = self:_restoreFromStorage()
    if not restored then
        self.persistence_blocked = true
        self.init_error = error_value(restore_error, "download persistence initialization failed")
        self.reload_required = reload_required == true
        self.sequence_allocation_blocked = is_sequence_error(restore_error)
        self.queue = {}
    end
    if #self.queue > 0 and not self.persistence_blocked then self:_schedulePump() end
    return self
end

function DownloadManager:_persist(task)
    local called, saved, err = pcall(function()
        return self.storage:putDownloadTask(durable_task(task))
    end)
    if not called then return nil, error_value(saved, "cannot persist download task") end
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
    if task then self.workers[task.id],self.checkpoints[task.id]=nil,nil end
    if task and self.active == task.id then
        self.active = nil
        self.standby:release()
    end
end

function DownloadManager:_block_persistence(task, err)
    err = error_value(err, "download persistence is unavailable")
    self.persistence_blocked, self.init_error = true, err
    task = task or (self.active and self.tasks[self.active])
    if task then self:_cancel_request(task); self:_release_active(task) end
    self.pump_scheduled = false
    return nil, err
end

function DownloadManager:_nextQueueSequence()
    local current = self.queue_sequence
    if current == 0 then return 1 end
    if valid_queue_sequence(current) == nil or current >= MAX_SAFE_QUEUE_SEQUENCE then
        return nil, sequence_error()
    end
    local next_sequence = current + 1
    if next_sequence <= current or valid_queue_sequence(next_sequence) == nil then
        return nil, sequence_error()
    end
    return next_sequence
end

function DownloadManager:_blockSequenceAllocation(err)
    self.reload_required, self.sequence_allocation_blocked = true, true
    return self:_block_persistence(nil, err or sequence_error())
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
    return self.tasks[task.id] == task and self.active == task.id and task.status == "running"
        and task.generation == generation and not task.cancel_requested
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
    self:_cancel_request(task)
    self:_release_active(task)
    self:_notify_terminal(task, err)
    self:_schedulePump()
    return true
end

function DownloadManager:_fail(task, err, chapter_failed)
    return self:_terminal(task, "failed", error_value(err, "download failed"),
        chapter_failed and (task.completed or 0)+(task.failed or 0)<(task.total or 0)
            and { failed = (task.failed or 0) + 1 } or nil)
end

function DownloadManager:_cancel_request(task)
    local worker=self.workers[task.id];self.workers[task.id]=nil
    if worker then worker:cancel() end
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

function DownloadManager:_assemble(task, source, chapters, prepared_path)
    local bodies = {}
    for _, chapter in ipairs(chapters) do
        local body, cache_error = self.cache:readBody(task.source_id, task.book_id, chapter)
        if (type(body) ~= "string" or body == "") and self.offline_cache then
            body, cache_error = self.offline_cache:readBody(task.source_id, task.book_id, chapter)
        end
        if type(body) ~= "string" or body == "" then return {error=error_value(cache_error,'EPUB chapter is unavailable')} end
        bodies[chapter.uid] = body
    end
    local cover = self.cache.readCover and self.cache:readCover(task.source_id, task.book_id) or nil
    local assets = { modified = timestamp(task.created_at), source = source }
    if type(cover) == "string" and cover ~= "" then assets.cover = { data = cover } end
    local build=prepared_path and self.builder.prepare or self.builder.write
    local ok, path, build_error = pcall(build, self.builder, prepared_path or task.final_path,
        task.book,chapters,bodies,assets,prepared_path and task.final_path or nil)
    if not ok then return {error=error_value(path,'EPUB assembly failed')} end
    if not path then return {error=error_value(build_error,'EPUB assembly failed')} end
    if prepared_path then return path end
    return {path=path,warning=published_diagnostic(build_error)}
end

function DownloadManager:_exportStage(task)
    if task.kind=='cache' or type(task.book)~='table' or task.final_path~=
        self.output_root..'/'..EpubBuilder.exportFilename(task.book) then return nil end
    return task.final_path..'.'..Identity.hash(task.id..':'..tostring(task.generation))..'.part'
end

function DownloadManager:_cleanInterruptedExport(task)
    local fs=self.builder.fs
    local stage=fs and fs.removeFile and self:_exportStage(task)
    if not stage then return end
    pcall(fs.removeFile,fs,stage)
    if not task.preserve_export_backup then pcall(fs.removeFile,fs,stage..'.backup') end
end

local function complete_catalog(catalog,chapters)
    if type(catalog)~='table' or catalog.complete~=true or type(catalog.chapters)~='table'
        or #catalog.chapters~=#chapters then return false end
    for index,chapter in ipairs(chapters) do if chapter.uid~=catalog.chapters[index].uid then return false end end
    return true
end

function DownloadManager:_completeCache(catalog,book,chapters)
    if type(book)~='table' then return false end
    if not complete_catalog(catalog,chapters) then return false end
    if catalog.cached_chapters~=nil then return catalog.cached_chapters==#chapters end
    -- Older releases marked the directory complete even for a range download.
    -- A matching completed full task is the only cheap proof of legacy coverage.
    for _,task in pairs(self.tasks) do
        if task.kind=='cache' and task.status=='completed' and task.book_id==book.id
            and task.source_id==book.source_id and task.total==#chapters
            and task.completed==task.total and (task.failed or 0)==0
            and type(task.chapters)=='table' and complete_catalog(catalog,task.chapters) then return true end
    end
    return false
end

function DownloadManager:readingCatalog(book,catalog)
    if type(book)~='table' then return catalog end
    if type(catalog)~='table' or type(catalog.complete)=='boolean' or type(catalog.chapters)~='table' then return catalog end
    for _,task in pairs(self.tasks) do
        -- Cache tasks persist chapters only after validating the whole website
        -- directory. EPUB tasks may have received a partial startup catalog.
        if task.kind=='cache' and task.total>0 and task.book_id==book.id and task.source_id==book.source_id
            and type(task.chapters)=='table' and complete_catalog({complete=true,chapters=catalog.chapters},task.chapters) then
            return {chapters=catalog.chapters,complete=true,cached_chapters=catalog.cached_chapters}
        end
    end
    return catalog
end

function DownloadManager:_build(task,source,chapters)
    local prepared_path=self.export_subprocess and self.scheduler and self:_exportStage(task) or nil
    if self.export_subprocess and self.scheduler and not prepared_path then
        return self:_fail(task,Errors.new(Errors.INVALID_INPUT,'导出目录或书名已变化，请重新创建导出任务'))
    end
    local preserve_backup=false
    local function cleanup()
        if prepared_path then
            pcall(self.builder.fs.removeFile,self.builder.fs,prepared_path)
            if not preserve_backup then pcall(self.builder.fs.removeFile,self.builder.fs,prepared_path..'.backup') end
        end
    end
    local function finish(value,err)
        if err or type(value)~='table' or value.error then return self:_fail(task,err or value and value.error) end
        if type(value.path)~='string' or value.path~=(prepared_path or task.final_path) then
            return self:_fail(task,Errors.new(Errors.STORAGE_ERROR,'EPUB output path changed'))
        end
        local warning=value.warning
        if prepared_path then
            if value.backup and value.backup.path~=prepared_path..'.backup' then
                return self:_fail(task,Errors.new(Errors.STORAGE_ERROR,'EPUB backup path changed'))
            end
            if type(value.size)~='number' or value.size<=0 or value.size%1~=0 then
                return self:_fail(task,Errors.new(Errors.STORAGE_ERROR,'EPUB prepared size is invalid'))
            end
            -- Protect the recovery file durably before touching the old EPUB.
            -- A failed terminal save must not make startup delete this backup.
            local saved,save_error=self:_transition(task,{preserve_export_backup=true})
            if not saved then return self:_interrupt_for_persistence(task,save_error) end
            preserve_backup=true
            local called,path,publish_error=pcall(self.builder.publish,self.builder,value,task.final_path)
            if not called or not path then
                preserve_backup=not called or type(publish_error)=='table' and type(publish_error.details)=='table'
                    and publish_error.details.recoverable_backup==true
                return self:_terminal(task,'failed',error_value(publish_error,'EPUB publication failed'),
                    {preserve_export_backup=preserve_backup and true or CLEAR})
            end
            preserve_backup=false
            warning=published_diagnostic(publish_error)
        end
        local changes={preserve_export_backup=CLEAR}
        if warning then changes.warning,changes.published_diagnostic=warning,warning end
        return self:_terminal(task,'completed',nil,changes)
    end
    if self.export_subprocess and self.scheduler then
        return self:_request(task,task.generation,function(callback)
            return require('legado.lib.download_export').start{scheduler=self.scheduler,subprocess=self.export_subprocess,
                now=self.now,job=function() return self:_assemble(task,source,chapters,prepared_path) end,
                callback=callback,cleanup=cleanup}
        end,finish)
    end
    return finish(self:_assemble(task,source,chapters))
end

function DownloadManager:_recordProgress(task, chapter)
    task.current=chapter.uid
    task.completed=(task.completed or 0)+1
    task.updated_at=self.now()
    local checkpoint=self.checkpoints[task.id]
    if task.completed-checkpoint.completed>=self.checkpoint_chapters or self.now()-checkpoint.at>=2 then
        local saved,err=self:_transition(task,{})
        if not saved then self:_interrupt_for_persistence(task,err);return false end
        checkpoint.completed,checkpoint.at=task.completed,self.now()
    end
    return true
end

function DownloadManager:_download(task, source, chapters)
    local generation=task.generation
    self.checkpoints[task.id]={completed=task.completed or 0,at=self.now()}
    local worker=DownloadWorker.new{
        scheduler=self.scheduler,concurrency=self.chapter_concurrency,chapters=chapters,
        source_id=task.source_id,book_id=task.book_id,
        target=task.kind=='cache' and self.offline_cache or self.cache,
        alternate=task.kind=='cache' and self.cache or self.offline_cache,copy_alternate=task.kind=='cache',
        valid=function() return self:_valid_callback(task,generation) end,
        request=function(chapter,callback)
            return self.service:getContent(source,task.book,chapter,callback,{priority='background'})
        end,
        progress=function(chapter) return self:_recordProgress(task,chapter) end,
        failed=function(err,chapter_failed) return self:_fail(task,err,chapter_failed) end,
        completed=function()
            self.workers[task.id]=nil
            if task.kind~='cache' then return self:_build(task,source,chapters) end
            local complete=#chapters==#task.chapters
            if not complete then
                local existing=self.offline_cache:readCatalog(task.source_id,task.book_id)
                complete=self:_completeCache(existing,task.book,task.chapters)
            end
            local saved,err=self.offline_cache:writeCatalog(task.source_id,task.book_id,
                {chapters=task.chapters,complete=true,cached_chapters=complete and #task.chapters or #chapters})
            if not saved then return self:_fail(task,err) end
            return self:_terminal(task,'completed')
        end,
    }
    self.workers[task.id]=worker
    worker:start()
end

function DownloadManager:_with_chapters(task, source, values)
    local chapters = {}
    if task.end_index and task.end_index > #(values or {}) then
        return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "selected ending chapter is outside the catalog"))
    end
    for index, chapter in ipairs(values or {}) do
        if task.end_index and index > task.end_index then break end
        if type(chapter) == "table" then
            if chapter.vip == true and task.kind == "cache" then
                return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "VIP chapters cannot be fully cached"))
            end
            if chapter.vip ~= true then chapters[#chapters + 1] = chapter end
        end
    end
    if #chapters == 0 then return self:_fail(task, Errors.new(Errors.INVALID_INPUT, "download catalog has no non-VIP chapters")) end
    local catalog_saved, catalog_error = self:_transition(task, {
        chapters = copy(values), total = #chapters, completed = 0, failed = 0,
    })
    if not catalog_saved then return self:_interrupt_for_persistence(task, catalog_error) end
    return self:_download(task, source, chapters, 1)
end

function DownloadManager:_catalog(task, source)
    local values = type(task.chapters) == "table" and task.chapters or nil
    if task.kind ~= "cache" and (not values or #values == 0) then
        values = self.storage:listChapters(task.book_id)
        if type(values) == "table" and #values == 0 then values = nil end
    end
    if task.kind ~= "cache" and values and #values > 0 then return self:_with_chapters(task, source, values) end
    local generation = task.generation
    return self:_request(task, generation, function(callback)
        return self.service:getChapters(source, task.book, callback,
            task.kind == "cache" and { background_catalog = true } or nil)
    end, function(chapters, err, metadata)
        if err or type(chapters) ~= "table" then return self:_fail(task, err) end
        if task.kind == "cache" and (not metadata or metadata.catalog_complete ~= true) then
            return self:_fail(task, Errors.new(Errors.PARSE_ERROR, "download catalog is incomplete"))
        end
        if task.kind == "cache" and values and #values > 0 then
            local changed = #values ~= #chapters
            if not changed then
                for index, previous in ipairs(values) do
                    if previous.uid ~= chapters[index].uid then changed = true; break end
                end
            end
            if changed then
                return self:_terminal(task, "failed", Errors.new(Errors.INVALID_INPUT,
                    "目录已变化，请从书籍详情重新选择缓存范围"))
            end
        end
        local persisted, persist_error = self.storage:replaceChapters(task.book_id, chapters)
        if not persisted then return self:_fail(task, persist_error) end
        if self.cache.writeCatalog then
            local catalog={chapters=chapters,complete=metadata and metadata.catalog_complete==true}
            if task.kind=='cache' and (self.cache==self.offline_cache
                or self.cache.root and self.cache.root==self.offline_cache.root) then
                local existing=self.offline_cache:readCatalog(task.source_id,task.book_id)
                if self:_completeCache(existing,task.book,chapters) then catalog.cached_chapters=#chapters end
            end
            local cached, cache_error = self.cache:writeCatalog(task.source_id, task.book_id, catalog)
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

function DownloadManager:enqueue(book, chapters, callback, kind, end_index)
    if type(chapters) == "function" then callback, chapters = chapters, nil end
    if self.persistence_blocked then return nil, self.init_error end
    if kind == "cache" and not self.offline_cache then
        return nil, Errors.new(Errors.STORAGE_ERROR, "offline cache is unavailable")
    end
    if type(book) ~= "table" or type(book.id) ~= "string" or type(book.source_id) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "download requires a normalized book")
    end
    if chapters ~= nil and type(chapters) ~= "table" then return nil, Errors.new(Errors.INVALID_INPUT, "chapters must be a table") end
    if end_index ~= nil and (kind ~= "cache" or type(end_index) ~= "number"
        or end_index < 1 or end_index % 1 ~= 0 or end_index >= MAX_SAFE_QUEUE_SEQUENCE) then
        return nil, Errors.new(Errors.INVALID_INPUT, "ending chapter must be a positive integer")
    end
    self.sequence = self.sequence + 1
    local created = self.now()
    local id = "download-" .. Identity.hash(book.id .. "\n" .. tostring(created) .. "\n" .. tostring(self.sequence))
    while self.tasks[id] do self.sequence = self.sequence + 1; id = "download-" .. Identity.hash(id .. self.sequence) end
    local next_queue_sequence, sequence_allocation_error = self:_nextQueueSequence()
    if not next_queue_sequence then return self:_blockSequenceAllocation(sequence_allocation_error) end
    local task = { id = id, book_id = book.id, source_id = book.source_id, book = copy(book), chapters = copy(chapters),
        kind = kind, end_index = end_index,
        status = "queued", total = 0, completed = 0, failed = 0, current = nil, cancel_requested = false,
        created_at = created, updated_at = created, queue_sequence = next_queue_sequence,
        final_path = kind ~= "cache" and (self.output_root .. "/" .. EpubBuilder.exportFilename(book)) or nil,
    }
    local saved, save_error = self:_persist(task)
    if not saved then return nil, save_error end
    self.queue_sequence = next_queue_sequence
    self.tasks[id], self.order[#self.order + 1], self.queue[#self.queue + 1] = task, id, id
    if type(callback) == "function" then self.callbacks[id] = callback end
    self:_schedulePump()
    return copy(task)
end

function DownloadManager:enqueueCache(book, callback, end_index)
    if type(callback) == "number" and end_index == nil then end_index, callback = callback, nil end
    return self:enqueue(book, nil, callback, "cache", end_index)
end

function DownloadManager:isCached(book)
    if not self.offline_cache or type(book) ~= "table" then return false end
    local catalog = self.offline_cache:readCatalog(book.source_id, book.id)
    if type(catalog)~='table' or catalog.complete~=true or type(catalog.chapters)~='table'
        or #catalog.chapters==0 then return false end
    if not self:_completeCache(catalog,book,catalog.chapters) then return false end
    local current=self.storage:listChapters(book.id)
    if type(current)~='table' then return true end
    if #current>#catalog.chapters then return false end
    for index,chapter in ipairs(current) do
        if chapter.uid~=catalog.chapters[index].uid then return false end
    end
    return true
end

function DownloadManager:get(id)
    local task = self.tasks[id]
    return task and copy(task) or nil
end

function DownloadManager:list(lightweight)
    local values = {}
    for _, id in ipairs(self.order) do
        local task=self.tasks[id]
        if task then
            local snapshot={}
            for key,value in pairs(task) do
                if key~='handle' and key~='request_slot' and (not lightweight or key~='chapters') then
                    snapshot[key]=copy(value)
                end
            end
            values[#values+1]=snapshot
        end
    end
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

function DownloadManager:remove(id)
    local task=self.tasks[id]
    if not task then return nil,Errors.new(Errors.INVALID_INPUT,'download task does not exist') end
    if self.persistence_blocked then return nil,self.init_error end
    self.removing=self.removing or {};self.removing[id]=true
    if not terminal[task.status] then
        local cancelled,err=self:cancel(id)
        if not cancelled then self.removing[id]=nil;return nil,err end
    end
    local read,catalog=true,nil
    if self.cache.readCatalog then read,catalog=pcall(self.cache.readCatalog,self.cache,task.source_id,task.book_id) end
    if not read then self.removing[id]=nil;return nil,error_value(catalog,'cannot read catalog metadata') end
    local recovered=self:readingCatalog(task.book,catalog)
    if recovered~=catalog then
        local called,saved,err=pcall(self.cache.writeCatalog,self.cache,task.source_id,task.book_id,recovered)
        if not called or not saved then self.removing[id]=nil;return nil,error_value(err,'cannot retain catalog metadata') end
    end
    if task.kind=='cache' and self.offline_cache then
        local read,catalog=pcall(self.offline_cache.readCatalog,self.offline_cache,task.source_id,task.book_id)
        if not read then self.removing[id]=nil;return nil,error_value(catalog,'cannot read cache metadata') end
        if catalog and catalog.cached_chapters==nil and self:_completeCache(catalog,task.book,catalog.chapters or {}) then
            local upgraded=copy(catalog);upgraded.cached_chapters=#upgraded.chapters
            local called,saved,err=pcall(self.offline_cache.writeCatalog,self.offline_cache,task.source_id,task.book_id,upgraded)
            if not called or not saved then self.removing[id]=nil;return nil,error_value(err,'cannot retain full download marker') end
        end
    end
    if type(self.storage.deleteDownloadTask)~='function' then
        self.removing[id]=nil
        return nil,Errors.new(Errors.STORAGE_ERROR,'download record deletion is unavailable')
    end
    local called,saved,err=pcall(self.storage.deleteDownloadTask,self.storage,id)
    if not called or not saved then self.removing[id]=nil;return nil,error_value(called and err or saved,'cannot delete download record') end
    self.tasks[id],self.callbacks[id],self.callback_delivered[id]=nil,nil,nil
    self.removing[id]=nil
    for index=#self.order,1,-1 do if self.order[index]==id then table.remove(self.order,index) end end
    for index=#self.queue,1,-1 do if self.queue[index]==id then table.remove(self.queue,index) end end
    return true
end

function DownloadManager:_requeue(id, allowed)
    if self.removing and self.removing[id] then return false end
    local task = self.tasks[id]
    if not task then return nil, Errors.new(Errors.INVALID_INPUT, "download task does not exist") end
    if task.preserve_export_backup then
        local fs=self.builder.fs
        local stage=self:_exportStage(task)
        if not fs or not fs.size or not stage or fs:size(stage..'.backup')~=nil then
            return nil,Errors.new(Errors.STORAGE_ERROR,'旧 EPUB 恢复失败，已保留备份文件，请恢复后新建导出任务')
        end
    end
    if self.persistence_blocked then return nil, self.init_error end
    if not allowed[task.status] then return false end
    local next_queue_sequence, sequence_allocation_error = self:_nextQueueSequence()
    if not next_queue_sequence then return self:_blockSequenceAllocation(sequence_allocation_error) end
    local saved, save_error = self:_transition(task, {
        status = "queued", cancel_requested = false, current = CLEAR, completed = 0, failed = 0,
        error = CLEAR, warning = CLEAR, published_diagnostic = CLEAR, queue_sequence = next_queue_sequence,
        preserve_export_backup=CLEAR,
    })
    if not saved then return nil, save_error end
    self.queue_sequence = next_queue_sequence
    self.callback_delivered[id] = nil
    self.queue[#self.queue + 1] = id
    self:_schedulePump(); return true
end

function DownloadManager:retry(id) return self:_requeue(id, { failed = true, cancelled = true }) end
function DownloadManager:resume(id) return self:_requeue(id, { interrupted = true }) end

function DownloadManager:recoverPersistence()
    if not self.persistence_blocked then return true end
    if self.reload_required then
        local restored, restore_error, reload_required = self:_restoreFromStorage(self.sequence_allocation_blocked)
        if not restored then
            self.init_error = error_value(restore_error, "download persistence is unavailable")
            self.reload_required = reload_required == true
            self.sequence_allocation_blocked = self.sequence_allocation_blocked or is_sequence_error(restore_error)
            self.queue = {}
            return nil, self.init_error
        end
        self.reload_required, self.sequence_allocation_blocked = false, false
        self.persistence_blocked, self.init_error = false, nil
        self:_schedulePump()
        return true
    end
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
    local migrated, migration_error = self:_migrateAndRebuildQueue()
    if not migrated then
        self.init_error = error_value(migration_error, "legacy download queue migration failed")
        self.reload_required = is_sequence_error(migration_error)
        self.sequence_allocation_blocked = is_sequence_error(migration_error)
        return nil, self.init_error
    end
    self.persistence_blocked, self.init_error = false, nil
    self:_schedulePump()
    return true
end

DownloadManager.retryPersistence = DownloadManager.recoverPersistence

function DownloadManager:open(id)
    local task = self.tasks[id]
    if not task or task.kind == "cache" or task.status ~= "completed" or type(task.final_path) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "completed EPUB is unavailable")
    end
    if type(self.open_final) ~= "function" then return task.final_path end
    return self.open_final(task.final_path, copy(task))
end

return DownloadManager
