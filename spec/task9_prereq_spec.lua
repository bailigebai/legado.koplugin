local assertx = require("assertions")
local DownloadManager = require("legado.lib.download_manager")
local Errors = require("legado.lib.errors")
local Storage = require("legado.lib.storage")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for key, child in pairs(value) do result[clone(key, seen)] = clone(child, seen) end
    return result
end

local function restored(id, sequence, created)
    local value = { id = id, book_id = "book-" .. id, source_id = "source-one",
        book = { id = "book-" .. id, source_id = "source-one", name = id, author = "A" },
        chapters = {}, status = "queued", queue_sequence = sequence,
        created_at = created or 1, updated_at = created or 1,
        total = 0, completed = 0, failed = 0, cancel_requested = false,
        final_path = "downloads/" .. id .. ".epub" }
    return value
end

local function manager_fixture(options)
    options = options or {}
    local state = {
        tasks = {}, list_value = options.list_value, list_throws = options.list_throws,
        list_error = options.list_error, fail_put = options.fail_put, put_error = options.put_error,
        throw_put = options.throw_put, puts = 0, network = 0, scheduled = {}, releases = 0,
    }
    for _, task in ipairs(options.initial or {}) do
        state.tasks[rawget(task, "id")] = options.raw_listing and task or clone(task)
    end
    if state.list_value == nil then
        state.list_value = function()
            local values = {}
            for _, task in pairs(state.tasks) do
                values[#values + 1] = options.raw_listing and task or clone(task)
            end
            return values
        end
    end
    local storage = {}
    function storage:listDownloadTasks()
        if state.list_throws then error(state.list_error or "damaged download collection") end
        if type(state.list_value) == "function" then return state.list_value() end
        return state.list_value
    end
    function storage:putDownloadTask(task)
        state.puts = state.puts + 1
        if state.throw_put then
            local thrown = state.throw_put(task, state)
            if thrown ~= nil then error(thrown) end
        end
        if state.fail_put and state.fail_put(task, state) then
            return nil, state.put_error or Errors.new(Errors.STORAGE_ERROR, "synthetic persistence failure")
        end
        state.tasks[task.id] = clone(task)
        return clone(task)
    end
    function storage:listSources() return {} end
    function storage:listChapters() return {} end
    function storage:replaceChapters() return true end

    local scheduler = {}
    function scheduler:scheduleIn(_, action) state.scheduled[#state.scheduled + 1] = action end
    local service = {}
    function service:getContent() state.network = state.network + 1; return { cancel = function() end } end
    function service:getChapters() state.network = state.network + 1; return { cancel = function() end } end
    local standby = { acquire = function() return true end, release = function() return true end,
        releaseAll = function() state.releases = state.releases + 1; return true end }
    local manager = DownloadManager.new({ storage = storage, cache = { readBody = function() end },
        book_service = service, builder = { write = function() end }, standby = standby,
        scheduler = scheduler, output_root = "downloads", now = options.now or function() return 100 end })
    return manager, state
end

-- Every initialization write is an exception boundary.  A backend throw at
-- the first, middle, or last duplicate migration becomes a blocked manager;
-- recovery resumes from durable progress after the backend is repaired.
do
    for failure_index, failure_id in ipairs({ "throw-b", "throw-c", "throw-d" }) do
        local metatable_calls = 0
        local hostile_error = setmetatable({ secret = "must-not-leak-" .. failure_index }, {
            __index = function() metatable_calls = metatable_calls + 1; error("error __index executed") end,
            __tostring = function() metatable_calls = metatable_calls + 1; error("error __tostring executed") end,
        })
        local ok, manager, state = pcall(function()
            local current, current_state = manager_fixture({ initial = {
                restored("throw-a", 1, 1), restored("throw-b", 1, 2),
                restored("throw-c", 1, 3), restored("throw-d", 1, 4),
            }, throw_put = function(task)
                if task.id == failure_id then return hostile_error end
            end })
            return current, current_state
        end)
        truthy(ok, "migration throw " .. failure_index .. " cannot escape construction")
        truthy(manager.persistence_blocked, "migration throw " .. failure_index .. " blocks persistence")
        equal(Errors.STORAGE_ERROR, manager.init_error and manager.init_error.code,
            "migration throw " .. failure_index .. " is normalized structurally")
        equal(nil, manager.init_error and manager.init_error.details,
            "migration throw " .. failure_index .. " exposes no backend exception details")
        equal(nil, (manager.init_error and manager.init_error.message or ""):find("must-not-leak", 1, true),
            "migration throw " .. failure_index .. " redacts the hostile payload")
        equal(0, metatable_calls, "migration throw " .. failure_index .. " executes no error metatable")
        equal(0, #manager.queue, "migration throw " .. failure_index .. " exposes no partial queue")
        equal(0, #state.scheduled, "migration throw " .. failure_index .. " schedules no network pump")
        state.throw_put = nil
        truthy(manager:recoverPersistence(), "migration throw " .. failure_index .. " recovers after repair")
        local seen = {}
        for _, task in pairs(state.tasks) do
            truthy(not seen[task.queue_sequence], "migration throw " .. failure_index .. " recovery has unique sequences")
            seen[task.queue_sequence] = true
        end
    end
end

-- Hostile thrown/returned error objects are data, never executable error
-- interfaces, and their payload must not enter diagnostics.
do
    for index, mode in ipairs({ "list-throw", "put-return" }) do
        local metatable_calls = 0
        local hostile_error = setmetatable({ secret = "backend-password-" .. index }, {
            __index = function() metatable_calls = metatable_calls + 1; error("hostile error index") end,
            __tostring = function() metatable_calls = metatable_calls + 1; error("hostile error tostring") end,
        })
        local options
        if mode == "list-throw" then
            options = { list_value = function() return {} end, list_throws = true, list_error = hostile_error }
        else
            options = { initial = { restored("returned-error-a", 1, 1), restored("returned-error-b", 1, 2) },
                fail_put = function(task) return task.id == "returned-error-b" end, put_error = hostile_error }
        end
        local ok, manager, state = pcall(function()
            local current, current_state = manager_fixture(options)
            return current, current_state
        end)
        truthy(ok, mode .. " hostile object cannot escape construction")
        truthy(manager.persistence_blocked, mode .. " hostile object blocks persistence")
        equal(Errors.STORAGE_ERROR, manager.init_error and manager.init_error.code,
            mode .. " hostile object is normalized structurally")
        equal(nil, manager.init_error and manager.init_error.details,
            mode .. " hostile object exposes no details")
        equal(nil, (manager.init_error and manager.init_error.message or ""):find("backend-password", 1, true),
            mode .. " hostile payload is redacted")
        equal(0, metatable_calls, mode .. " never executes error metatable methods")
        equal(0, #state.scheduled, mode .. " schedules no network")
        state.list_throws, state.fail_put = false, nil
        truthy(manager:recoverPersistence(), mode .. " recovers after backend repair")
    end
end

-- Restored state is copied through raw operations into plain tables before it
-- enters manager state.  Neither root nor nested persistence metatables may be
-- executed later by get/list, sorting, transitions, or the scheduled pump.
do
    local metatable_calls = 0
    local function hostile()
        metatable_calls = metatable_calls + 1
        error("persisted metatable executed")
    end
    local task = restored("hostile-metatable", 1, 1)
    task.book = setmetatable(task.book, {
        __index = hostile, __newindex = hostile, __pairs = hostile, __tostring = hostile,
    })
    setmetatable(task, {
        __index = hostile, __newindex = hostile, __pairs = hostile, __tostring = hostile,
    })
    local manager, state = manager_fixture({ initial = { task }, raw_listing = true })
    equal(0, metatable_calls, "construction never executes persisted root or nested metatables")
    equal(false, manager.persistence_blocked, "safe raw fields survive metatable stripping")
    local got_ok, got = pcall(manager.get, manager, task.id)
    truthy(got_ok, "get remains callable after hostile persistence metatables are stripped")
    equal("hostile-metatable", got and got.book and got.book.name,
        "normalized nested book content remains available")
    equal(nil, got and getmetatable(got), "restored task copy has no persistence metatable")
    equal(nil, got and got.book and getmetatable(got.book), "nested restored copy has no persistence metatable")
    local pump_ok = pcall(state.scheduled[1])
    truthy(pump_ok, "scheduled startup work cannot execute a restored __newindex hook")
    equal(0, metatable_calls, "all later manager operations remain isolated from persistence metatables")
    equal(0, state.network, "hostile metatable fixture reaches no network source")
end

-- Fields consumed by sorting, transitions, arithmetic, and UI state must be
-- normalized up front.  Malformed or non-persistable values block safely and
-- recovery re-reads durable state after repair.
do
    local cyclic = {}; cyclic.self = cyclic
    local keyed = {}; keyed[{}] = "unsupported table key"
    local bad_fields = {
        { "created_at", "oops" }, { "updated_at", {} }, { "generation", "oops" },
        { "total", -1 }, { "completed", 1.5 }, { "failed", "oops" },
        { "cancel_requested", "false" }, { "current", {} }, { "book", function() end },
        { "chapters", coroutine.create(function() end) }, { "error", io.stdout },
        { "book", cyclic }, { "book", keyed },
        { "book", { source_id = "source-one", name = "missing id" } },
        { "book", { id = "book-bad-restored-field-15", source_id = "source-one", name = "bad cover", author = "A",
            cover_url = {} } },
        { "chapters", { { uid = {}, index = 1, title = "bad uid", url = "https://example.test" } } },
        { "error", { code = 7, message = {} } },
    }
    for index, definition in ipairs(bad_fields) do
        local task = restored("bad-restored-field-" .. index, 1, 1)
        task[definition[1]] = definition[2]
        local ok, manager, state = pcall(function()
            local current, current_state = manager_fixture({ initial = { task }, raw_listing = true })
            return current, current_state
        end)
        truthy(ok, "bad restored field " .. index .. " cannot escape construction")
        truthy(manager.persistence_blocked, "bad restored field " .. index .. " blocks persistence")
        equal(Errors.STORAGE_ERROR, manager.init_error and manager.init_error.code,
            "bad restored field " .. index .. " returns structured initialization error")
        equal(0, #manager.queue, "bad restored field " .. index .. " exposes no runnable queue")
        equal(0, #state.scheduled, "bad restored field " .. index .. " schedules no pump")
        equal(0, state.network, "bad restored field " .. index .. " starts no network")
        state.list_value = function() return { restored("repaired-field-" .. index, 1, 1) } end
        truthy(manager:recoverPersistence(), "bad restored field " .. index .. " recovers after durable repair")
        equal("repaired-field-" .. index, manager.queue[1],
            "repaired field " .. index .. " restores normalized work")
    end
end

-- The first task in deterministic duplicate order keeps its valid sequence;
-- later duplicates become legacy tail entries and are durably renumbered.
do
    local manager, state = manager_fixture({ initial = {
        restored("duplicate-b", 1, 1), restored("unique", 2, 2), restored("duplicate-a", 1, 1),
    } })
    equal(1, state.tasks["duplicate-a"].queue_sequence, "first deterministic duplicate keeps its valid sequence")
    equal(2, state.tasks.unique.queue_sequence, "unrelated unique sequence remains stable")
    equal(3, state.tasks["duplicate-b"].queue_sequence, "later duplicate is migrated after the existing maximum")
    equal("duplicate-a,unique,duplicate-b", table.concat(manager.queue, ","),
        "duplicate migration creates a strict FIFO without equal sequence values")

    local restarted = manager_fixture({ initial = {
        clone(state.tasks["duplicate-b"]), clone(state.tasks.unique), clone(state.tasks["duplicate-a"]),
    } })
    equal("duplicate-a,unique,duplicate-b", table.concat(restarted.queue, ","),
        "restart preserves the durable duplicate migration order")
end

-- Values outside LuaJIT's safe integer range are legacy metadata.  A real
-- maximum-safe sequence is valid but leaves no allocatable successor.
do
    local manager, state = manager_fixture({ initial = { restored("too-large", 9007199254740992, 1) } })
    equal(1, state.tasks["too-large"].queue_sequence, "unsafe integer sequence migrates to a small exact value")
    equal("too-large", table.concat(manager.queue, ","), "unsafe sequence recovery retains the queued task")
end

-- String sequences are accepted only as exact positive decimal integer
-- literals.  Parsing must never round a fractional/exponent form into a valid
-- queue integer, and accepted leading zeroes are normalized durably.
do
    for index, value in ipairs({
        "9007199254740990.5", "9007199254740991.4", "2.0", "2e0",
        " 2", "2 ", "+2", "-2", "NaN", "Inf", "0", "000",
    }) do
        local id = "invalid-sequence-string-" .. index
        local manager, state = manager_fixture({ initial = { restored(id, value, index) } })
        equal(1, state.tasks[id].queue_sequence,
            "non-integer sequence literal " .. index .. " is migrated instead of rounded")
        equal(id, manager.queue[1], "non-integer sequence literal " .. index .. " remains queued safely")
    end

    local leading_manager, leading_state = manager_fixture({ initial = {
        restored("leading-zero-sequence", "0002", 1),
    } })
    equal(2, leading_state.tasks["leading-zero-sequence"].queue_sequence,
        "positive leading-zero integer is normalized to its exact numeric value")
    equal("leading-zero-sequence", leading_manager.queue[1],
        "normalized leading-zero sequence retains its queue position")

    local boundary_manager, boundary_state = manager_fixture({ initial = {
        restored("exact-safe-string", "9007199254740991", 1),
    } })
    equal(9007199254740991, boundary_state.tasks["exact-safe-string"].queue_sequence,
        "maximum-safe integer string is normalized without precision loss")
    equal("exact-safe-string", boundary_manager.queue[1],
        "maximum-safe integer string remains a valid queued task")
end

do
    local manager, state = manager_fixture({ initial = { restored("last-safe", 9007199254740991, 1) } })
    local added, err = manager:enqueue({ id = "later", source_id = "source-one", name = "Later" }, {})
    equal(nil, added, "exhausted sequence space rejects enqueue")
    equal(Errors.STORAGE_ERROR, err and err.code, "sequence exhaustion returns a structured storage error")
    truthy(manager.persistence_blocked, "sequence exhaustion trips the persistence circuit breaker")
    equal(0, state.puts, "sequence exhaustion performs no colliding persistence write")
    for _, action in ipairs(state.scheduled) do action() end
    equal(0, state.network, "sequence exhaustion permits no queued network work")
    equal(nil, manager:recoverPersistence(), "unchanged exhausted counter cannot report a false recovery")
    truthy(manager.persistence_blocked, "unchanged exhausted counter remains blocked")
    state.tasks["last-safe"].queue_sequence = 1
    truthy(manager:recoverPersistence(), "repairing the durable counter permits recovery")
end

-- A duplicate that cannot be assigned after the maximum-safe value blocks at
-- initialization. Recovery is idempotent and succeeds only after durable data
-- is repaired to make sequence space available.
do
    local manager, state = manager_fixture({ initial = {
        restored("safe-first", 9007199254740991, 1), restored("safe-duplicate", 9007199254740991, 2),
    } })
    truthy(manager.persistence_blocked, "unmigratable duplicate blocks initialization")
    equal(Errors.STORAGE_ERROR, manager.init_error and manager.init_error.code,
        "unmigratable duplicate exposes structured initialization error")
    equal(0, #manager.queue, "unmigratable duplicate exposes no runnable partial queue")
    equal(0, #state.scheduled, "unmigratable duplicate schedules no network work")
    equal(nil, manager:recoverPersistence(), "unchanged exhaustion remains blocked on explicit recovery")
    state.tasks["safe-first"].queue_sequence = 1
    state.tasks["safe-duplicate"].queue_sequence = 1
    truthy(manager:recoverPersistence(), "recovery reloads repaired durable sequence metadata")
    equal(1, state.tasks["safe-first"].queue_sequence, "repaired first sequence remains stable")
    equal(2, state.tasks["safe-duplicate"].queue_sequence, "repaired duplicate migrates without collision")
end

-- Queue order is counter-based, never clock-based: equal timestamps and a
-- wall-clock rollback cannot collide or insert newer work ahead of old work.
do
    local ticks, index = { 100, 100, 50 }, 0
    local manager = manager_fixture({ now = function() index = index + 1; return ticks[index] end })
    local first = assert(manager:enqueue({ id = "clock-a", source_id = "source-one", name = "A" }, {}))
    local second = assert(manager:enqueue({ id = "clock-b", source_id = "source-one", name = "B" }, {}))
    local third = assert(manager:enqueue({ id = "clock-c", source_id = "source-one", name = "C" }, {}))
    equal(1, first.queue_sequence, "first equal-time enqueue begins the monotonic counter")
    equal(2, second.queue_sequence, "second equal-time enqueue receives a unique successor")
    equal(3, third.queue_sequence, "clock rollback cannot move the queue counter backwards")
    equal(first.id .. "," .. second.id .. "," .. third.id, table.concat(manager.queue, ","),
        "equal and reversed clocks preserve enqueue FIFO")
end

do
    local failed = restored("retry-at-boundary", 9007199254740991, 1)
    failed.status = "failed"
    local manager, state = manager_fixture({ initial = { failed } })
    local retried, err = manager:retry(failed.id)
    equal(nil, retried, "exhausted sequence space rejects requeue")
    equal(Errors.STORAGE_ERROR, err and err.code, "exhausted requeue is structured")
    truthy(manager.persistence_blocked, "exhausted requeue trips the same circuit breaker")
    equal(0, state.puts, "exhausted requeue cannot persist a colliding sequence")
    equal(0, state.network, "exhausted requeue starts no network")
end

-- Failure at either end of a duplicate migration leaves the manager blocked;
-- retry continues from durable progress without renumbering a successful prefix.
for _, failure_id in ipairs({ "migrate-second", "migrate-third" }) do
    local manager, state = manager_fixture({ initial = {
        restored("migrate-first", 1, 1), restored("migrate-second", 1, 2), restored("migrate-third", 1, 3),
    }, fail_put = function(task, current)
        if task.id == failure_id and not current.failed_once then current.failed_once = true; return true end
    end })
    truthy(manager.persistence_blocked, failure_id .. " failure blocks partial migration")
    equal(0, #manager.queue, failure_id .. " failure exposes no partial runnable queue")
    local durable_second = state.tasks["migrate-second"].queue_sequence
    state.fail_put = nil
    truthy(manager:recoverPersistence(), failure_id .. " migration recovers after storage returns")
    if failure_id == "migrate-third" then
        equal(durable_second, state.tasks["migrate-second"].queue_sequence,
            "successful migration prefix remains stable across recovery")
    end
    local observed = {}
    for _, task in pairs(state.tasks) do observed[task.queue_sequence] = (observed[task.queue_sequence] or 0) + 1 end
    equal(1, observed[1], failure_id .. " recovery retains one original sequence")
    equal(1, observed[2], failure_id .. " recovery allocates sequence two once")
    equal(1, observed[3], failure_id .. " recovery allocates sequence three once")
end

-- Construction must survive thrown, scalar, and malformed download listings.
-- The blocked object remains callable and can reload once the backend is fixed.
local hostile_task = setmetatable({}, { __index = function() error("hostile task field") end })
for index, bad in ipairs({
    false, "oops", 7, { { status = "queued" } },
    { restored("malformed-fields", {}, {}) },
    { hostile_task },
}) do
    local options = { list_value = bad }
    if index == 1 then options.list_value, options.list_throws = function() return {} end, true end
    local ok, manager, state = pcall(function()
        local current, fixture_state = manager_fixture(options)
        return current, fixture_state
    end)
    truthy(ok, "damaged download listing " .. index .. " never escapes initialization")
    truthy(manager.persistence_blocked, "damaged download listing " .. index .. " blocks persistence")
    equal(Errors.STORAGE_ERROR, manager.init_error and manager.init_error.code,
        "damaged download listing " .. index .. " has a structured initialization error")
    equal(0, #state.scheduled, "damaged download listing " .. index .. " schedules no network")
    equal(nil, manager:recoverPersistence(), "still-damaged listing " .. index .. " stays blocked")
    state.list_throws = false
    state.list_value = function() return { restored("repaired-" .. index, 1, 1) } end
    truthy(manager:recoverPersistence(), "repaired download listing " .. index .. " recovers")
    equal("repaired-" .. index, manager.queue[1], "repaired listing " .. index .. " restores its task")
end

-- Fallback storage validates every schema collection before its first save,
-- so corrupted durable data is never silently replaced or overwritten.
for _, collection in ipairs({ "sources", "books", "chapters", "progress", "downloads" }) do
    local data = { sources = "{}", books = "{}", chapters = "{}", progress = "{}", downloads = "{}" }
    data[collection] = '"oops"'
    local content = 'return {["schema_version"]=1,["data"]={'
        .. '["sources"]=' .. data.sources .. ',["books"]=' .. data.books
        .. ',["chapters"]=' .. data.chapters .. ',["progress"]=' .. data.progress
        .. ',["downloads"]=' .. data.downloads .. '}}'
    local writes = 0
    local fs = { read = function() return content end,
        atomicWrite = function() writes = writes + 1; return true end }
    local storage, err = Storage.new({ path = "damaged-" .. collection .. ".lua", fs = fs,
        sqlite_loader = function() return nil end })
    equal(nil, storage, collection .. " scalar collection is rejected")
    equal(Errors.STORAGE_ERROR, err and err.code, collection .. " corruption returns a structured error")
    equal(0, writes, collection .. " corruption is never overwritten")
end

return count
