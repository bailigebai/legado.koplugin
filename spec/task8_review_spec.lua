local assertx = require("assertions")
local DownloadManager = require("legado.lib.download_manager")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local source = { bookSourceUrl = "https://example.test", bookSourceName = "fixture" }
local function book(id) return { id = id, source_id = "source-8144a6ea", name = id, author = "A" } end
local function chapter(value, index)
    return { uid = value.id .. "-c" .. index, book_id = value.id, source_id = value.source_id,
        index = index, title = "C" .. index, url = "https://example.invalid/" .. index }
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, child in pairs(value) do result[key] = clone(child) end; return result
end

local function fixture(options)
    options = options or {}
    local state = { tasks = {}, puts = {}, pending = {}, cancellations = {}, refs = 0, release_all = 0, bodies = {} }
    for _, task in ipairs(options.initial or {}) do state.tasks[task.id] = clone(task) end
    local storage = {}
    function storage:putDownloadTask(task)
        state.puts[#state.puts + 1] = clone(task)
        if options.fail_put and options.fail_put(task, #state.puts, state) then
            return nil, { code = "STORAGE_ERROR", message = "synthetic persist failure" }
        end
        state.tasks[task.id] = clone(task); return task
    end
    function storage:listDownloadTasks()
        if options.preserve_initial_order then
            local values = {}; for _, task in ipairs(options.initial or {}) do values[#values + 1] = clone(state.tasks[task.id]) end
            return values
        end
        local values = {}; for _, task in pairs(state.tasks) do values[#values + 1] = clone(task) end; return values
    end
    function storage:listSources() return { source } end
    function storage:listChapters() return {} end
    function storage:replaceChapters() return true end
    local function cache_key(source_id, book_id, value_chapter) return source_id .. "/" .. book_id .. "/" .. value_chapter.uid end
    local cache = {
        readBody = function(_, source_id, book_id, value_chapter) return state.bodies[cache_key(source_id, book_id, value_chapter)] end,
        writeBody = function(_, source_id, book_id, value_chapter, body)
            state.bodies[cache_key(source_id, book_id, value_chapter)] = body; return true
        end,
        writeCatalog = function() return true end,
        readCover = function() return nil end,
    }
    local service = {}
    function service:getChapters(_, value, callback)
        if options.sync_catalog then
            callback(options.catalogs[value.id], nil)
            return { cancel = function() state.cancellations.catalog = (state.cancellations.catalog or 0) + 1 end }
        end
        state.pending[#state.pending + 1] = { kind = "catalog", book = value, callback = callback }
        return { cancel = function() state.cancellations.catalog = (state.cancellations.catalog or 0) + 1 end }
    end
    function service:getContent(_, value, value_chapter, callback)
        if options.sync_first and value_chapter.index == 1 then
            callback({ content = "<p>one</p>" }, nil)
            return { cancel = function() state.cancellations.first = (state.cancellations.first or 0) + 1 end }
        end
        local request = { kind = "content", book = value, chapter = value_chapter, callback = callback }
        state.pending[#state.pending + 1] = request
        return { cancel = function()
            request.cancelled = true
            state.cancellations[value_chapter.uid] = (state.cancellations[value_chapter.uid] or 0) + 1
        end }
    end
    local standby = {
        acquire = function() state.refs = state.refs + 1; return true end,
        release = function() if state.refs > 0 then state.refs = state.refs - 1 end; return true end,
        releaseAll = function() state.refs = 0; state.release_all = state.release_all + 1; return true end,
    }
    local builder = { write = function(_, path)
        if options.builder_write then return options.builder_write(path, state) end
        return path
    end }
    local manager = DownloadManager.new({ storage = storage, cache = cache, book_service = service,
        standby = standby, builder = builder, scheduler = options.scheduler,
        output_root = "downloads", now = function() return 10 end })
    return manager, state
end

local function permutations(values)
    local output = {}
    for first = 1, #values do
        for second = 1, #values do
            for third = 1, #values do
                if first ~= second and first ~= third and second ~= third then
                    output[#output + 1] = { clone(values[first]), clone(values[second]), clone(values[third]) }
                end
            end
        end
    end
    return output
end

local function restored_task(id, sequence, created, task_id)
    local value = book(id)
    return { id = task_id or ("task-" .. id), book_id = value.id, source_id = value.source_id, book = value,
        chapters = { chapter(value, 1) }, status = "queued", queue_sequence = sequence,
        created_at = created, updated_at = created, completed = 0, failed = 0,
        final_path = "downloads/" .. id .. ".epub" }
end

local function with_forced_task_pairs(order, call)
    local original_pairs = pairs
    _G.pairs = function(target)
        if type(target) == "table" and rawget(target, "a2") and rawget(target, "b2") and rawget(target, "c2") then
            local index = 0
            return function()
                index = index + 1
                local key = order[index]
                if key then return key, target[key] end
            end, target, nil
        end
        return original_pairs(target)
    end
    local result = { pcall(call) }
    _G.pairs = original_pairs
    if not result[1] then error(result[2]) end
    return unpack(result, 2)
end

-- Mixed legacy queue metadata must define one strict total order independent of
-- storage/hash insertion order, both at startup and after persistence recovery.
do
    for _, legacy_kind in ipairs({ "missing", "invalid" }) do
        local legacy_sequence
        if legacy_kind == "invalid" then legacy_sequence = "invalid" end
        local tasks = {
            restored_task("order-a", 2, 1, "a2"),
            restored_task("order-b", 1, 3, "b2"),
            restored_task("order-c", legacy_sequence, 2, "c2"),
        }
        for permutation_index, initial in ipairs(permutations(tasks)) do
            local scheduled = {}
            local scheduler = { scheduleIn = function(_, _, action) scheduled[#scheduled + 1] = action end }
            local forced_order = { initial[1].id, initial[2].id, initial[3].id }
            local manager, state = with_forced_task_pairs(forced_order, function()
                return fixture({ initial = initial, preserve_initial_order = true, scheduler = scheduler,
                    fail_put = function(_, _, current) return current.storage_down end })
            end)
            equal("b2,a2,c2", table.concat(manager.queue, ","),
                "startup mixed queue order is deterministic for permutation " .. permutation_index)
            state.storage_down = true
            scheduled[1]()
            truthy(manager.persistence_blocked, "mixed queue start outage blocks permutation " .. permutation_index)
            state.storage_down = false
            truthy(with_forced_task_pairs(forced_order, function() return manager:recoverPersistence() end),
                "mixed queue recovers permutation " .. permutation_index)
            local observed = {}
            for action_index = 2, 4 do
                scheduled[action_index]()
                local request = state.pending[#state.pending]
                observed[#observed + 1] = request and request.book.id or "missing"
                if request then request.callback({ content = "<p>ordered</p>" }, nil) end
            end
            equal("order-b,order-a,order-c", table.concat(observed, ","),
                "mixed queue ordering is deterministic for permutation " .. permutation_index)
            equal(3, #state.pending, "mixed queue has no duplicates for permutation " .. permutation_index)
        end
    end
end

-- A persistent storage outage is a circuit breaker: no unpersisted terminal
-- result is announced and active network/standby resources are always released.
do
    local scheduled = {}
    local scheduler = { scheduleIn = function(_, _, action) scheduled[#scheduled + 1] = action end }
    local value, next_value = book("persist-outage-running"), book("persist-outage-next")
    local manager, state = fixture({ scheduler = scheduler,
        fail_put = function(_, _, current) return current.storage_down end })
    local task = assert(manager:enqueue(value, { chapter(value, 1) }))
    local next_task = assert(manager:enqueue(next_value, { chapter(next_value, 1) }))
    state.storage_down = true
    scheduled[1]()
    truthy(manager.persistence_blocked, "running transition persistent outage blocks the manager")
    equal("queued", state.tasks[task.id].status, "failed running transition leaves queued durable truth")
    equal(0, #state.pending, "failed running persistence starts no network request")
    equal(0, state.refs, "failed running persistence holds no standby reference")
    state.storage_down = false
    truthy(manager:recoverPersistence(), "queued start recovers after storage returns")
    scheduled[2]()
    equal(value.id, state.pending[1] and state.pending[1].book.id,
        "recovery rebuilds persisted FIFO so the popped queued task runs first")
    equal("running", manager:get(task.id).status, "recovered first queued task persists running before network")
    equal("queued", manager:get(next_task.id).status, "later persisted task remains queued without duplication")
    state.pending[1].callback({ content = "<p>first</p>" }, nil)
    scheduled[3]()
    equal(2, #state.pending, "recovered FIFO starts each queued task exactly once")
    equal(next_value.id, state.pending[2] and state.pending[2].book.id,
        "later persisted task starts only after the recovered first task completes")
end

do
    local value = book("persist-outage-terminal")
    local values = { chapter(value, 1) }
    local callback_status
    local manager, state = fixture({
        fail_put = function(_, _, current) return current.storage_down end,
        builder_write = function(path, current)
            if not current.outage_triggered then current.outage_triggered = true; current.storage_down = true end
            return path
        end,
    })
    local task = assert(manager:enqueue(value, values, function(done) callback_status = done.status end))
    state.pending[1].callback({ content = "<p>done</p>" }, nil)
    truthy(manager.persistence_blocked, "repeated terminal persistence failure blocks the manager")
    equal("STORAGE_ERROR", manager.init_error and manager.init_error.code, "persistence outage is exposed structurally")
    equal(nil, callback_status, "unpersisted completion is never delivered")
    equal(0, state.refs, "persistent terminal outage releases standby")
    equal("running", state.tasks[task.id].status, "disk retains the last recoverable running truth")
    state.storage_down = false
    truthy(manager:recoverPersistence(), "explicit recovery succeeds after storage returns")
    equal(false, manager.persistence_blocked, "successful explicit recovery clears the circuit breaker")
    equal("interrupted", state.tasks[task.id].status, "recovery persists an interrupted resumable state")
    truthy(manager:resume(task.id), "recovered storage permits an explicit resume")
    equal("completed", manager:get(task.id).status, "explicit resume reuses cache and completes after persistence recovery")
    equal("completed", callback_status, "only the later persisted completion is delivered")
end

do
    local value = book("persist-outage-cancel")
    local values = { chapter(value, 1) }
    local manager, state = fixture({ fail_put = function(_, _, current) return current.storage_down end })
    local task = assert(manager:enqueue(value, values))
    state.storage_down = true
    local cancelled, err = manager:cancel(task.id)
    equal(nil, cancelled, "persistent cancel outage is not reported as cancelled")
    equal("STORAGE_ERROR", err and err.code, "persistent cancel outage is structured")
    truthy(manager.persistence_blocked, "cancel persistence outage blocks further pumping")
    equal(0, state.refs, "cancel persistence outage releases standby")
    equal(1, state.cancellations[values[1].uid], "cancel outage still cancels the active request")
    equal("running", state.tasks[task.id].status, "cancel outage preserves recoverable disk truth")
end

do
    local value = book("persist-outage-startup")
    local initial = { { id = "startup-outage", book_id = value.id, source_id = value.source_id, book = value,
        status = "running", current = "old", cancel_requested = false } }
    local manager, state = fixture({ initial = initial, fail_put = function() return true end })
    truthy(manager.persistence_blocked, "startup recovery outage blocks the manager")
    equal("STORAGE_ERROR", manager.init_error and manager.init_error.code, "startup outage exposes initialization error")
    equal("running", manager:get("startup-outage").status, "startup outage keeps in-memory recoverable truth")
    equal("running", state.tasks["startup-outage"].status, "startup outage leaves durable truth untouched")
    equal(1, state.release_all, "startup outage unconditionally releases inherited standby")
end

-- A synchronously completed request must not overwrite the handle for the
-- asynchronous request started by its callback.
do
    local value = book("sync-content")
    local values = { chapter(value, 1), chapter(value, 2) }
    local manager, state = fixture({ sync_first = true })
    local task = assert(manager:enqueue(value, values))
    equal(1, #state.pending, "synchronous first chapter advances to one asynchronous second request")
    truthy(manager:cancel(task.id), "mixed synchronous/asynchronous task cancels")
    equal(nil, state.cancellations.first, "completed synchronous handle is never cancelled")
    equal(1, state.cancellations[values[2].uid], "the current second request handle is cancelled")
end

do
    local value = book("sync-catalog")
    local values = { chapter(value, 1) }
    local manager, state = fixture({ sync_catalog = true, catalogs = { [value.id] = values } })
    local task = assert(manager:enqueue(value))
    truthy(manager:cancel(task.id), "synchronous catalog followed by content can be cancelled")
    equal(nil, state.cancellations.catalog, "completed synchronous catalog handle is never cancelled")
    equal(1, state.cancellations[values[1].uid], "catalog callback does not overwrite the active content handle")
end

-- Terminal, cancellation, and recovery transitions may only become visible
-- after their persisted state succeeds.
do
    local value = book("terminal-persist")
    local values = { chapter(value, 1) }
    local failed_once = false
    local manager, state = fixture({ fail_put = function(task)
        if task.status == "completed" and not failed_once then failed_once = true; return true end
    end })
    local callback_status, callback_error
    local task = assert(manager:enqueue(value, values, function(done, err) callback_status, callback_error = done.status, err end))
    state.pending[1].callback({ content = "<p>done</p>" }, nil)
    equal("interrupted", manager:get(task.id).status, "terminal persistence failure becomes interrupted, not completed")
    equal("interrupted", state.tasks[task.id].status, "terminal persistence fallback keeps memory and disk aligned")
    equal("interrupted", callback_status, "terminal callback never reports an unpersisted completion")
    equal("STORAGE_ERROR", callback_error and callback_error.code, "terminal persistence failure is reported")
    equal(0, state.refs, "persisted interruption releases standby")
end

do
    local value = book("cancel-persist")
    local values = { chapter(value, 1) }
    local failed_once = false
    local manager, state = fixture({ fail_put = function(task)
        if task.status == "cancelling" and not failed_once then failed_once = true; return true end
    end })
    local task = assert(manager:enqueue(value, values))
    local cancelled, cancel_error = manager:cancel(task.id)
    equal(nil, cancelled, "failed cancellation persistence is not reported as cancelled")
    equal("STORAGE_ERROR", cancel_error and cancel_error.code, "failed cancellation persistence is returned")
    equal("interrupted", manager:get(task.id).status, "cancel persistence failure becomes interrupted")
    equal("interrupted", state.tasks[task.id].status, "cancel fallback persists the same interrupted state")
end

do
    local value = book("recover-persist")
    local initial = { { id = "recover", book_id = value.id, source_id = value.source_id, book = value,
        status = "running", current = "old", cancel_requested = false } }
    local failed_once = false
    local manager, state = fixture({ initial = initial, fail_put = function(task)
        if task.status == "interrupted" and not failed_once then failed_once = true; return true end
    end })
    equal("failed", manager:get("recover").status, "recovery persistence failure falls back to a persisted failed state")
    equal("failed", state.tasks.recover.status, "recovery fallback keeps memory and disk aligned")
    equal(1, state.release_all, "startup recovery always releases inherited standby")
end

-- Retried work is appended to the explicit queue tail.
do
    local a, b, c = book("fifo-a"), book("fifo-b"), book("fifo-c")
    local manager, state = fixture()
    local ta = assert(manager:enqueue(a, { chapter(a, 1) }))
    local tb = assert(manager:enqueue(b, { chapter(b, 1) }))
    local tc = assert(manager:enqueue(c, { chapter(c, 1) }))
    state.pending[1].callback(nil, { code = "NETWORK_ERROR", message = "fail A" })
    equal("running", manager:get(tb.id).status, "B starts after A fails")
    truthy(manager:retry(ta.id), "failed A is retried while B is active")
    state.pending[2].callback({ content = "<p>B</p>" }, nil)
    equal("running", manager:get(tc.id).status, "C remains ahead of retried A")
    state.pending[3].callback({ content = "<p>C</p>" }, nil)
    equal("running", manager:get(ta.id).status, "retried A runs only after B then C")
end

return count
