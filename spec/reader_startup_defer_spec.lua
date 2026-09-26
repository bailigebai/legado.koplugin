local A = require('assertions')
local Session = require('legado.lib.reader_session')
local Fakes = require('support.network_fakes')
local count = 0
local function eq(a, b, message) count = count + 1; A.equal(a, b, message) end
local source, book = { id = 's' }, { id = 'b', source_id = 's' }
local chapters = {}
for i = 1, 1000 do chapters[i] = { uid = 'c' .. i, index = i, title = 'Chapter ' .. i, url = 'https://books.test/' .. i } end
local function fixture(async, scheduler)
    local state = { requests = {}, bodies = { c1 = '<p>First</p>' }, events = {}, saves = 0 }
    local cache = {
        readBody = function(_, _, _, chapter) return state.bodies[chapter.uid], { code = 'STORAGE_ERROR', message = 'unavailable' } end,
        writeBody = function(_, _, _, chapter, body) state.bodies[chapter.uid] = body; return true end,
        writeHtml = function() return 'first.html' end,
    }
    local ui = { openDocument = function(_, _, callbacks)
        state.callbacks = callbacks
        local document = { getProgressFraction = function() return 0 end }
        state.document = document
        if not async then callbacks.ready(document) end
        return document
    end }
    local service = { getContent = function(_, _, _, chapter, callback)
        state.events[#state.events + 1] = chapter.index == 1 and 'foreground' or 'prefetch'
        state.requests[#state.requests + 1] = chapter.index
        if chapter.index == 1 and state.defer_foreground then state.foreground = callback
        else callback({ content = 'Prepared chapter' }) end
        return { cancel = function() end }
    end }
    local session = Session.new({ cache = cache, ui = ui, service = service, scheduler = scheduler,
        storage = { putProgress = function() state.saves = state.saves + 1; return true end },
        settings = { get = function() return 2 end } })
    session.loadCatalog = function() state.events[#state.events + 1] = 'catalog' end
    local function open(options)
        options = options or {}
        options.catalog_complete = false
        options.on_complete = options.on_complete or function()
            state.events[#state.events + 1] = 'ready'
            state.requests_at_ready = #state.requests
        end
        return session:open(source, book, chapters, 1, options)
    end
    return session, state, open
end
for _, async in ipairs({ false, true }) do
    local scheduler = Fakes.scheduler()
    local session, state, open = fixture(async, scheduler)
    open()
    if async then
        eq(0, #scheduler.queue, 'document still opening schedules no background work')
        state.callbacks.ready(state.document)
    end
    eq(0, state.requests_at_ready, 'reader-ready callback runs before any speculative request')
    eq(2, #state.requests, 'reader-ready starts the bounded prefetch window immediately')
    eq(0, state.saves, 'first reader-ready performs no progress persistence')
    eq(0, scheduler.queue[1].at, 'a zero-delay follow-up keeps page checks on the UI scheduler')
    scheduler:runNext()
    eq('ready', state.events[1], 'first observable completion belongs to the document')
    eq(2, #state.requests, 'the follow-up does not duplicate immediate prefetch')
    eq(true, scheduler.queue[1].at>0 and scheduler.queue[1].at<1, 'full catalog yields for first paint but starts promptly after prefetch')
    scheduler:runNext()
    eq('catalog', state.events[#state.events], 'catalog eventually starts in the background')
    session:close()
end
for _, deferred in ipairs({ false, true }) do
    local scheduler = Fakes.scheduler()
    local session, state, open = fixture(false, scheduler)
    state.bodies.c1, state.defer_foreground = nil, deferred
    open()
    if deferred then
        eq(nil, state.requests_at_ready, 'pending first chapter download has no ready notification')
        eq(0, #scheduler.queue, 'pending first chapter download cannot schedule prefetch')
        state.foreground({ content = 'First chapter' })
    end
    eq(1, state.requests_at_ready, 'first download completes readiness before speculative downloads')
    eq(3, #state.requests, 'first download completion immediately starts later prefetch')
    scheduler:runNext()
    eq(3, #state.requests, 'the follow-up does not duplicate later prefetch')
    session:close()
end
do
    local scheduler = Fakes.scheduler()
    local session, state, open = fixture(false, scheduler)
    open(); session:close(); scheduler:runAll()
    eq(2, #state.requests, 'closing after commit cancels the already-started prefetch handles')
end
do
    local scheduler = Fakes.scheduler()
    local session, state, open = fixture(false, scheduler)
    open()
    local stale = scheduler.queue[1].action
    open(); local started = #state.requests; stale()
    eq(started, #state.requests, 'replaced reading intent invalidates the old follow-up action')
    session:close(); scheduler:runAll()
end
do
    local scheduler = Fakes.scheduler()
    local session, state, open = fixture(false, scheduler)
    open({ on_complete = function() session:close() end })
    scheduler:runAll()
    eq(0, #state.requests, 'reader closed within ready callback cannot start background work')
    eq(0, #scheduler.queue, 'closed reader leaves no deferred work')
end
do
    local session, state, open = fixture(false, nil)
    open()
    eq(0, state.requests_at_ready, 'legacy unscheduled adapter also notifies before synchronous prefetch')
    eq(2, #state.requests, 'legacy unscheduled adapter preserves prefetch support')
    session:close()
end
return count
