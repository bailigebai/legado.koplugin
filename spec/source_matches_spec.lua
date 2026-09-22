local A = require("assertions")
local Service = require("legado.lib.book_service")
local Models = require("legado.lib.models")
local loaded, Matches = pcall(require, "legado.ui.source_matches")
assert(loaded, "exact source-matching model must exist")
local count = 0
local function eq(want, got, why) count = count + 1; A.equal(want, got, why) end
local sources = {
    { id = "a", bookSourceUrl = "https://a.test/", bookSourceName = "Alpha" },
    { id = "b", bookSourceUrl = "https://b.test/", bookSourceName = "Beta" },
    { id = "c", bookSourceUrl = "https://c.test/", bookSourceName = "Gamma" },
    { id = "d", bookSourceUrl = "https://d.test/", bookSourceName = "Disabled", enabled = false },
}
local function book(index, name, author, url)
    return Models.book(sources[index], { name = name or "Target Book", author = author == nil and "A Writer" or author, url = url or "/book" })
end
local function clock()
    local scheduler = { now = 0, queue = {} }
    function scheduler:scheduleIn(delay, action) self.queue[action] = self.now + delay; return action end
    function scheduler:unschedule(action) self.queue[action] = nil end
    function scheduler:advance(seconds)
        self.now = self.now + seconds
        local ready = {}
        for action, when in pairs(self.queue) do if when <= self.now then ready[#ready + 1] = action end end
        for _, action in ipairs(ready) do self.queue[action] = nil; action() end
    end
    return scheduler
end
local function fixture()
    local storage = { listSources = function() return sources end }
    local service = Service.new({ storage = storage, rule_engine = {}, request_engine = { concurrency = 3 }, url_template = {} })
    service.searches, service.catalogs, service.released = {}, {}, {}
    function service:_search_source(source, keyword, page, callback)
        self.searches[source.id] = { callback = callback, keyword = keyword, page = page }
        return { cancel = function() self.released["search_" .. source.id] = true end }
    end
    function service:getChapters(source, candidate, callback, options)
        self.catalogs[source.id] = { callback = callback, book = candidate, options = options }
        return { cancel = function() self.released["catalog_" .. source.id] = true end }
    end
    local scheduler, updates = clock(), {}
    local view = Matches.new({ service = service, storage = storage, book = book(1), scheduler = scheduler,
        onUpdate = function(current) updates[#updates + 1] = { time = scheduler.now, loading = current.loading, size = #current.results } end })
    return view, service, scheduler, updates
end

-- A title-only filter would expose unrelated authors and disabled/unmatched stations.
do
    local view, service, scheduler, updates = fixture()
    eq(true, view:start(), "matching starts")
    eq(4, service.fast_search_concurrency, "source matching enables bounded burst search concurrency")
    eq(4, service.requests.concurrency, "source matching widens the request queue safely")
    eq("Target Book", service.searches.a.keyword, "all-source search uses the current title")
    eq(nil, service.searches.d, "disabled stations are never searched")
    service.searches.a.callback({ book(1), book(1, nil, nil, "/duplicate"),
        book(1, "Target Book", "Other Writer", "/wrong-author"), book(4) })
    eq(1, #view.results, "one matching entry per enabled station")
    eq("Alpha", view.results[1].source_name, "entry uses the configured station name")
    eq(1, #view.results[1].alternatives, "same station duplicates do not inflate alternatives")
    eq(1, view.progress.completed, "search progress remains available")
    eq(true, view.loading, "matches are exposed before all stations finish")
    eq(nil, service.catalogs.a, "catalog probes wait until all source searches finish")
    service.searches.b.callback({ book(2, "Target Book II"), book(2, nil, ""), book(2, nil, "Other Writer") })
    service.searches.c.callback({ book(3, "  TARGET\t Book  ", " a  writer ") })
    eq(2, #view.results, "normalized exact title and author match; wrong title and author are hidden")
    eq("Gamma", view.results[2].source_name, "a second exact station is included")
    eq(nil, service.catalogs.b, "unmatched books do not trigger catalog requests")
    eq(nil, service.catalogs.d, "disabled payloads cannot trigger catalog requests")
    eq(64, service.catalogs.a.options.max_pages, "catalog search follows the existing full-catalog safety limit")
    eq(0, #updates, "progress does not repaint immediately")
    scheduler:advance(5)
    eq(0, #updates, "progress cannot repaint before six seconds")
    scheduler:advance(1)
    eq(1, #updates, "multiple progress events coalesce into one six-second update")
    service.catalogs.a.options.on_progress(1, 10)
    scheduler:advance(5)
    eq(1, #updates, "a second burst cannot repaint within six seconds of the previous update")
    scheduler:advance(1)
    eq(2, #updates, "a later burst gets its own delayed update")
    scheduler:advance(30)
    eq(2, #updates, "unchanged searches never poll or repaint repeatedly")
    view:close()
    eq(nil, service.fast_search_concurrency, "closing source matching restores service mode")
    eq(3, service.requests.concurrency, "closing source matching restores request concurrency")
end

-- Count ordering must follow observed chapters, including partial catalog lower bounds.
do
    local view, service, scheduler, updates = fixture()
    view:start()
    service.searches.a.callback({ book(1) })
    service.searches.b.callback({ book(2) })
    service.searches.c.callback({ book(3) })
    eq(nil, service.catalogs.c, "only two catalog requests run at once")
    service.catalogs.b.options.on_progress(1, 4)
    eq("Beta", view.results[1].source_name, "largest known chapter count comes first while loading")
    eq(4, view.results[1].chapter_count, "catalog progress exposes the known chapter count")
    eq(false, view.results[1].catalog_complete, "progress counts are marked as lower bounds")
    local four = { {}, {}, {}, {} }
    service.catalogs.b.callback(four, nil, { catalog_complete = true })
    eq("function", type(service.catalogs.c.callback), "completed catalog frees the next queue slot")
    service.catalogs.a.callback({ {}, {} }, nil, { catalog_complete = true })
    service.catalogs.c.callback({ {}, {}, {}, {}, {} }, nil, { catalog_complete = false })
    eq("Gamma", view.results[1].source_name, "a larger partial count still sorts above a smaller full count")
    eq("Beta", view.results[2].source_name, "complete counts sort descending")
    eq("Alpha", view.results[3].source_name, "lowest chapter count sorts last")
    eq(false, view.results[1].catalog_complete, "capped catalog retains incomplete metadata")
    eq(four, view.results[2].chapters, "loaded catalog is retained for source switching")
    eq(false, view.loading, "view finishes after both search and all catalogs settle")
    eq(3, view.progress.catalog_completed, "catalog completion progress is visible")
    scheduler:advance(6)
    eq(false, updates[1].loading, "coalesced update displays final loading state")
    scheduler:advance(100)
    eq(1, #updates, "finished view has no refresh loop")
end

-- Closing must release every in-flight operation and reject late progress/completion.
do
    local view, service, scheduler, updates = fixture()
    view:start()
    service.searches.a.callback({ book(1) })
    local late_b = service.searches.b.callback
    service.searches.b.callback({})
    service.searches.c.callback({})
    local action = next(scheduler.queue)
    local catalog = service.catalogs.a
    view:close()
    eq(true, service.released.catalog_a, "closing cancels catalog fetches")
    eq(nil, next(scheduler.queue), "closing removes pending screen refresh")
    late_b({ book(2) })
    catalog.options.on_progress(1, 999)
    catalog.callback({ {}, {} }, nil, { catalog_complete = true })
    action()
    eq(1, #view.results, "late search callbacks cannot add entries")
    eq(nil, view.results[1].chapter_count, "late catalog callbacks cannot alter entries")
    eq(0, #updates, "late refresh actions cannot repaint a closed screen")
    eq(false, view:start(), "a closed view cannot restart work")
end

-- Missing author cannot prove identity, even if both sides have empty authors.
do
    local view, service, scheduler, updates = fixture()
    view.book.author = "  "
    view:start()
    eq(nil, next(service.searches), "missing current author does not guess a matching book")
    eq("INVALID_INPUT", view.error.code, "missing identity metadata has a structured error")
    eq(true, #view.error.message > 0, "missing identity metadata has a readable explanation")
    eq(false, view.loading, "invalid metadata does not leave the view spinning")
    scheduler:advance(6)
    eq(1, #updates, "validation errors reach the screen")
end

-- Synchronous service failures must settle once without escaping into the reader UI.
do
    local view, service, scheduler = fixture()
    function service:search() error("private transport failure") end
    view:start()
    eq(false, view.loading, "thrown search startup error ends loading")
    eq("REQUEST_ERROR", view.error.code, "thrown search startup error is structured")
    eq(nil, view.error.message:find("private", 1, true), "startup errors do not expose transport details")
    scheduler:advance(6)
end
do
    local view, service = fixture()
    function service:getChapters() error("private catalog failure") end
    view:start()
    service.searches.a.callback({ book(1) })
    service.searches.b.callback({})
    service.searches.c.callback({})
    eq(false, view.loading, "thrown catalog startup error frees the queue and ends loading")
    eq(1, #view.results, "catalog failures retain the known matching station")
    eq("REQUEST_ERROR", view.errors[1].code, "catalog startup failures remain diagnosable")
    eq(nil, view.errors[1].message:find("private", 1, true), "catalog startup errors hide transport details")
end
do
    local view, service = fixture()
    local released = false
    view.scheduler = nil
    view.onUpdate = function(current) current:close() end
    function service:search(_, _, _, _, progress)
        progress({ groups = {}, total = 1, completed = 0 })
        return { cancel = function() released = true end }
    end
    view:start()
    eq(true, released, "closing during synchronous progress cancels the subsequently returned search handle")
    eq(false, view.alive, "synchronous close stays closed after search returns")
end
do
    local view, service = fixture()
    local groups = {}
    for i = 1, 2000 do
        local source = { id = tostring(i), bookSourceName = "Site " .. i }
        sources[#sources + 1] = source
        local candidate = Models.book(source, { name = "Target Book", author = "A Writer", url = "https://test/" .. i })
        groups[#groups + 1] = { book = candidate, alternatives = { candidate } }
    end
    function service:search(_, _, _, done)
        done({ groups = groups, total = 2000, completed = 2000 })
        return { cancel = function() end }
    end
    function service:getChapters(_, _, done)
        done(nil, { code = "UNSUPPORTED_RULE" })
        done(nil, { code = "UNSUPPORTED_RULE" })
        return { cancel = function() end }
    end
    view:start()
    eq(false, view.loading, "thousands of synchronous catalog failures settle without stack overflow")
    eq(2000, view.progress.catalog_completed, "duplicate catalog callbacks are counted once")
    eq(2000, #view.errors, "failed catalogs remain diagnosable while matched stations stay visible")
end

return count
