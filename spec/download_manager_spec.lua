local assertx = require("assertions")
local DownloadManager = require("legado.lib.download_manager")
local StandbyGuard = require("legado.lib.standby_guard")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

do
    local calls = { prevent = 0, allow = 0 }
    local ui = {
        preventStandby = function() calls.prevent = calls.prevent + 1 end,
        allowStandby = function() calls.allow = calls.allow + 1 end,
    }
    local guard = StandbyGuard.new({ ui_manager = ui })
    truthy(guard:acquire(), "standby guard acquires supported KOReader capability")
    truthy(guard:acquire(), "standby guard is reference counted")
    equal(1, calls.prevent, "nested acquire prevents standby only once")
    truthy(guard:release(), "first release decrements reference")
    equal(0, calls.allow, "nested reference keeps standby inhibited")
    truthy(guard:release(), "last release restores standby")
    equal(1, calls.allow, "last release calls KOReader allowStandby once")
    truthy(guard:releaseAll(), "releaseAll is safe when already released")
    local unsupported = StandbyGuard.new({ ui_manager = {}, shell = function() error("shell must not run") end })
    equal(false, unsupported:acquire(), "unsupported platform is a safe no-op")
    equal(0, unsupported:count(), "unsupported guard never records a reference")
end

local source = { bookSourceUrl = "https://example.test", bookSourceName = "测试源" }
local book_one = { id = "book-one", source_id = "source-8144a6ea", source_name = "测试源", name = "Book", author = "A" }
local book_two = { id = "book-two", source_id = "source-8144a6ea", source_name = "测试源", name = "Next", author = "B" }
local function chapter(book, index, vip)
    return { uid = book.id .. "-chapter-" .. index, book_id = book.id, source_id = book.source_id,
        index = index, title = "Chapter " .. index, url = "https://example.test/" .. book.id .. "/" .. index, vip = vip == true }
end
local chapters_one = { chapter(book_one, 1), chapter(book_one, 2), chapter(book_one, 3, true) }
local chapters_two = { chapter(book_two, 1) }

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}; if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    return result
end

local function storage_fake(initial)
    local state = { tasks = {}, transitions = {}, chapters = {}, sources = { source } }
    for _, task in ipairs(initial or {}) do state.tasks[task.id] = copy(task) end
    local storage = {}
    function storage:putDownloadTask(task)
        state.tasks[task.id] = copy(task); state.transitions[#state.transitions + 1] = task.id .. ":" .. task.status
        return copy(task)
    end
    function storage:getDownloadTask(id) return state.tasks[id] and copy(state.tasks[id]) or nil end
    function storage:listDownloadTasks()
        local values = {}; for _, task in pairs(state.tasks) do values[#values + 1] = copy(task) end
        table.sort(values, function(a, b) return a.id < b.id end); return values
    end
    function storage:listSources() return state.sources end
    function storage:listChapters(book_id) return copy(state.chapters[book_id] or {}) end
    function storage:replaceChapters(book_id, values) state.chapters[book_id] = copy(values); return true end
    return storage, state
end

local function cache_fake(initial)
    local state = { bodies = initial or {}, writes = {} }
    local cache = {}
    local function key(s, b, c) return s .. "/" .. b .. "/" .. c.uid end
    function cache:readBody(s, b, c) return state.bodies[key(s, b, c)] end
    function cache:writeBody(s, b, c, body)
        state.bodies[key(s, b, c)] = body; state.writes[#state.writes + 1] = c.uid; return "cache/" .. c.uid
    end
    function cache:readCover() return nil end
    function cache:writeCatalog() return true end
    return cache, state, key
end

local function service_fake()
    local state = { pending = {}, catalog_pending = {}, cancellations = 0, requested = {} }
    local service = {}
    function service:getContent(_, book, chapter, callback)
        local request = { book = book, chapter = chapter, callback = callback, cancelled = false }
        state.pending[#state.pending + 1] = request; state.requested[#state.requested + 1] = chapter.uid
        return { cancel = function()
            if request.cancelled then return false end
            request.cancelled = true; state.cancellations = state.cancellations + 1; return true
        end }
    end
    function service:getChapters(_, book, callback)
        local request = { book = book, callback = callback, cancelled = false }
        state.catalog_pending[#state.catalog_pending + 1] = request
        return { cancel = function() request.cancelled = true; return true end }
    end
    return service, state
end

local function standby_fake()
    local state = { refs = 0, acquired = 0, released = 0, release_all = 0 }
    local guard = {}
    function guard:acquire() state.refs = state.refs + 1; state.acquired = state.acquired + 1; return true end
    function guard:release() if state.refs > 0 then state.refs = state.refs - 1; state.released = state.released + 1 end; return true end
    function guard:releaseAll() state.refs = 0; state.release_all = state.release_all + 1; return true end
    return guard, state
end

local function builder_fake(behavior)
    behavior = behavior or {}
    local state = { calls = {} }
    local builder = {}
    function builder:write(path, book, chapters, bodies, assets)
        state.calls[#state.calls + 1] = { path = path, book = book, chapters = chapters, bodies = bodies, assets = assets }
        if behavior.failure then return nil, { code = "STORAGE_ERROR", message = "builder failed" } end
        return path
    end
    return builder, state
end

local function manager_fixture(options)
    options = options or {}
    local storage, stored = storage_fake(options.initial)
    local cache, cached, key = cache_fake(options.cached)
    local service, served = service_fake()
    local standby, awake = standby_fake()
    local builder, built = builder_fake(options.builder)
    local opened = {}
    local manager = DownloadManager.new({ storage = storage, cache = cache, book_service = service,
        builder = builder, standby = standby, output_root = "downloads", now = function() return 1788134400 end,
        open_final = function(path) opened[#opened + 1] = path; return "opened:" .. path end })
    return manager, { storage = stored, cache = cached, key = key, service = served, standby = awake, builder = built, opened = opened }
end

-- Valid cached chapters are skipped, missing chapters fetch sequentially, and
-- a second queued task cannot start before the first terminal transition.
do
    local initial = { ["source-8144a6ea/book-one/book-one-chapter-1"] = "<p>cached one</p>" }
    local manager, state = manager_fixture({ cached = initial })
    local completed = 0
    local first = assert(manager:enqueue(book_one, chapters_one, function() completed = completed + 1 end))
    local second = assert(manager:enqueue(book_two, chapters_two))
    equal("running", manager:get(first.id).status, "first queued task becomes active")
    equal("queued", manager:get(second.id).status, "second task remains queued")
    equal(1, state.standby.refs, "one active task holds one standby reference")
    equal(1, #state.service.pending, "only first missing chapter is requested")
    equal("book-one-chapter-2", state.service.pending[1].chapter.uid, "valid cache is skipped in chapter order")
    equal(1, manager:get(first.id).completed, "cache hit updates completed counter")
    local late = state.service.pending[1].callback
    late({ content = "<p>fresh two</p>" }, nil)
    equal("completed", manager:get(first.id).status, "all non-VIP chapters complete the task")
    equal(2, manager:get(first.id).completed, "completed counter includes cache and fetch")
    equal(0, manager:get(first.id).failed, "successful task has no failed chapters")
    equal(1, #state.builder.calls, "EPUB builder runs exactly once")
    equal("<p>cached one</p>", state.builder.calls[1].bodies["book-one-chapter-1"], "builder reuses cached body")
    equal("<p>fresh two</p>", state.builder.calls[1].bodies["book-one-chapter-2"], "builder receives fetched cached body")
    equal(2, #state.builder.calls[1].chapters, "VIP chapter is excluded from complete download")
    equal("running", manager:get(second.id).status, "queue advances only after first terminal state")
    equal(1, state.standby.refs, "standby reference transfers to next active task without leaking")
    late({ content = "<p>late duplicate</p>" }, nil)
    equal(1, #state.builder.calls, "late duplicate callback cannot rebuild EPUB")
    equal(1, completed, "terminal callback fires exactly once")
    truthy(manager:open(first.id):find("opened:", 1, true), "completed task exposes final EPUB open hook")
    equal(1, #state.opened, "open hook is invoked exactly once")
end

-- Partial fetch failure retains successful cache, releases standby, and lets
-- the next queued task run.
do
    local manager, state = manager_fixture()
    local first = assert(manager:enqueue(book_one, chapters_one))
    local second = assert(manager:enqueue(book_two, chapters_two))
    state.service.pending[1].callback({ content = "<p>one</p>" }, nil)
    equal(2, #state.service.pending, "second chapter starts only after first succeeds")
    state.service.pending[2].callback(nil, { code = "NETWORK_ERROR", message = "offline" })
    equal("failed", manager:get(first.id).status, "partial fetch failure marks task failed")
    equal(1, manager:get(first.id).failed, "partial fetch failure increments failed counter")
    equal("<p>one</p>", state.cache.bodies[state.key(book_one.source_id, book_one.id, chapters_one[1])],
        "successful chapter cache survives task failure")
    equal(0, #state.builder.calls, "partial fetch never publishes an EPUB")
    equal("running", manager:get(second.id).status, "queue continues after failure")
    equal(1, state.standby.refs, "failed task releases its reference before next acquire")
end

-- Cancellation is idempotent; current and late callbacks cannot mutate the
-- cancelled generation or invoke completion twice.
do
    local manager, state = manager_fixture()
    local callbacks = 0
    local task = assert(manager:enqueue(book_one, chapters_one, function() callbacks = callbacks + 1 end))
    local late = state.service.pending[1].callback
    truthy(manager:cancel(task.id), "active task cancellation succeeds")
    truthy(manager:cancel(task.id), "repeated cancellation is idempotent")
    equal("cancelled", manager:get(task.id).status, "cancelled task reaches a terminal state")
    equal(1, state.service.cancellations, "current request is cancelled once")
    equal(0, state.standby.refs, "cancel releases standby")
    late({ content = "<p>late</p>" }, nil)
    equal(0, #state.cache.writes, "late callback cannot write cache")
    equal(0, #state.builder.calls, "late callback cannot publish EPUB")
    equal(1, callbacks, "cancel terminal callback fires exactly once")
end

-- Retry and interrupted resume reuse valid cache instead of re-fetching it.
do
    local manager, state = manager_fixture()
    local task = assert(manager:enqueue(book_one, chapters_one))
    state.service.pending[1].callback({ content = "<p>one</p>" }, nil)
    state.service.pending[2].callback(nil, { code = "NETWORK_ERROR" })
    truthy(manager:retry(task.id), "failed task can be retried")
    equal("running", manager:get(task.id).status, "retry requeues and starts task")
    equal("book-one-chapter-2", state.service.pending[3].chapter.uid, "retry skips chapter cached before failure")
    state.service.pending[3].callback({ content = "<p>two</p>" }, nil)
    equal("completed", manager:get(task.id).status, "retry can finish the same task")
    equal(1, #state.builder.calls, "retry publishes one complete EPUB")
end

-- Startup converts abandoned active states to interrupted and releases any
-- inherited standby inhibition before explicit resume.
do
    local initial = {
        { id = "a", book_id = "book-one", source_id = book_one.source_id, status = "running", book = book_one, chapters = chapters_one },
        { id = "b", book_id = "book-two", source_id = book_two.source_id, status = "cancelling", book = book_two, chapters = chapters_two },
        { id = "c", book_id = "done", status = "completed", final_path = "downloads/done.epub" },
    }
    local manager, state = manager_fixture({ initial = initial })
    equal("interrupted", manager:get("a").status, "running task recovers as interrupted")
    equal("interrupted", manager:get("b").status, "cancelling task recovers as interrupted")
    equal("completed", manager:get("c").status, "completed history remains completed")
    equal(1, state.standby.release_all, "startup recovery releases inherited standby state")
    truthy(manager:resume("a"), "interrupted task can be explicitly resumed")
    equal("running", manager:get("a").status, "resume starts recovered task")
end

-- Catalog acquisition and builder failure are persisted and release resources.
do
    local manager, state = manager_fixture({ builder = { failure = true } })
    local task = assert(manager:enqueue(book_two))
    equal(1, #state.service.catalog_pending, "missing catalog is fetched through BookService")
    state.service.catalog_pending[1].callback(chapters_two, nil)
    state.service.pending[1].callback({ content = "<p>only</p>" }, nil)
    equal("failed", manager:get(task.id).status, "archive commit failure marks task failed")
    equal(0, state.standby.refs, "builder failure releases standby")
    equal(1, #state.storage.chapters[book_two.id], "fetched catalog is persisted")
end

return count
