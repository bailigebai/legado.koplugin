local A = require("assertions")
local Service = require("legado.lib.book_service")
local Search = require("legado.ui.search")
local Models = require("legado.lib.models")
local count = 0
local function eq(a, b, why) count = count + 1; A.equal(a, b, why) end
local sources = {}
for _, id in ipairs({ "a", "b", "c" }) do
    sources[#sources + 1] = { id = id, bookSourceUrl = "https://" .. id .. ".test/", bookSourceName = id }
end
local function service(list)
    local s = Service.new({ storage = { listSources = function() return list or sources end },
        rule_engine = {}, request_engine = {}, url_template = {}, settings = { concurrency = 2 } })
    s.pending, s.cancelled = {}, 0
    function s:_search_source(source, _, _, callback)
        self.pending[source.id] = callback
        return { cancel = function() self.cancelled = self.cancelled + 1; return true end }
    end
    return s
end
local function book(index, name, url, author)
    return Models.book(sources[index], { name = name, url = url, author = author or "Writer" })
end

do
    local s, progress, result, failure, completions = service(), {}, nil, nil, 0
    s:search("Target", nil, 1, function(value, err) result, failure = value, err; completions = completions + 1 end,
        function(value) progress[#progress + 1] = value end)
    s.pending.b({ book(2, "Target extra", "/other"), book(2, "Target", "/same"), book(2, "Target", "/same") })
    eq(1, #progress, "early results publish before the slow source finishes")
    eq(nil, result, "legacy completion still waits for all sources")
    eq("Target", progress[1].groups[1].book.name, "exact title matches precede partial matches")
    eq(2, #progress[1].groups, "duplicate URLs do not duplicate books")
    eq(1, #progress[1].groups[1].alternatives, "duplicate source URLs do not inflate alternatives")
    eq(3, progress[1].total, "progress exposes selected source total")
    eq(1, progress[1].completed, "progress counts completed sources")
    eq(1, progress[1].succeeded, "progress counts successful sources")
    eq(0, progress[1].failed, "progress starts with no failures")
    eq("function", type(s.pending.c), "a finished source opens the next queue slot")
    s.pending.c(nil, { code = "TIMEOUT", message = "private host" })
    eq(1, progress[2].failed, "a broken source reports failure without stopping the queue")
    eq(1, #progress[2].errors, "progress retains source diagnostics")
    eq(nil, progress[2].errors[1].message:find("private", 1, true), "diagnostics do not leak transport data")
    s.pending.a({ book(1, "target", "/same"), book(1, "Different", "/writer", "Target") })
    eq(nil, failure, "partial success has no aggregate failure")
    eq(1, completions, "completion is delivered once")
    eq(3, result.completed, "completion includes the same counters")
    eq(2, result.succeeded, "final successful source count")
    eq(2, #result.groups[1].alternatives, "same title and author merge across sources")
    eq(Models.sourceId(sources[1]), result.groups[1].book.source_id, "selected source order remains deterministic")
    eq("Different", result.groups[2].book.name, "exact author matches also precede partial matches")
    eq(1, #progress[1].groups[1].alternatives, "later merges do not mutate an earlier snapshot")
end

do
    local s, updates, completes = service(), 0, 0
    local handle = s:search("Target", nil, 1, function() completes = completes + 1 end,
        function() updates = updates + 1 end)
    s.pending.a({ book(1, "Target", "/one") })
    handle:cancel()
    s.pending.b({ book(2, "Late", "/late") })
    s.pending.c(nil, { code = "TIMEOUT" })
    eq(1, updates, "cancellation discards all late progress")
    eq(0, completes, "cancellation discards completion")
end

do
    local many = {}
    for i = 1, 3000 do many[i] = { id = tostring(i), bookSourceName = "Invalid" } end
    local s, result, error = service(many)
    function s:_search_source(_, _, _, callback)
        callback(nil, { code = "UNSUPPORTED_RULE" })
        return { cancel = function() end }
    end
    s:search("Target", nil, 1, function(value, err) result, error = value, err end)
    eq(3000, result.completed, "thousands of synchronous rejections drain without stack overflow")
    eq(3000, result.failed, "all synchronous failures are counted")
    eq("NETWORK_ERROR", error.code, "all failures retain the aggregate error contract")
    local empty, empty_error
    service({}):search("Target", nil, 1, function(value, err) empty, empty_error = value, err end)
    eq(0, empty.total, "no enabled sources is distinguishable from no hits")
    eq(nil, empty_error, "no source remains backward compatible")
end

do
    local progress, complete, updates, cancelled = nil, nil, 0, 0
    local view = Search.new({ service = { search = function(_, _, _, _, done, update)
        complete, progress = done, update
        return { cancel = function() cancelled = cancelled + 1; return true end }
    end }, onUpdate = function() updates = updates + 1 end })
    view:submit("Target", nil, 1)
    eq("Target", view.keyword, "loading screen knows the query before any source responds")
    eq("function", type(progress), "search UI subscribes to progress")
    local group = { book = book(1, "Target", "/one"), alternatives = { book(1, "Target", "/one") } }
    progress({ groups = { group }, errors = {}, total = 3, completed = 1, succeeded = 1, failed = 0 })
    eq(true, view.loading, "early results retain loading state")
    eq(1, view.progress.completed, "UI exposes progress counters")
    eq("Target", view:selectAlternative(1, 1).name, "books can be opened before search completes")
    eq(1, updates, "early results trigger a UI update")
    view:cancel()
    eq(false, view.loading, "cancel stops the loading state")
    eq(true, view.cancelled, "cancel is distinguishable from successful completion")
    eq("Target", view.results[1].book.name, "cancel retains the visible results")
    eq(2, updates, "cancel updates the visible state")
    progress({ groups = {}, errors = {}, completed = 3 })
    complete({ groups = {}, errors = {} })
    eq("Target", view.results[1].book.name, "cancelled callbacks cannot erase retained results")
    view:submit("Next", nil, 1)
    eq(false, view.cancelled, "new request clears cancellation state")
    complete({ groups = { group }, errors = {}, total = 3, completed = 3, succeeded = 3, failed = 0, has_more = false })
    eq(false, view.loading, "completion still ends loading")
    eq(false, view.has_more, "explicit pagination status overrides nonempty results")
    eq(3, view.progress.completed, "completion updates progress")
    eq(1, cancelled, "cancel releases the service request")
end
do
    local released = 0
    local view = Search.new({ service = { search = function(_, _, _, _, _, progress)
        progress({ groups = {}, errors = {}, total = 2, completed = 1, succeeded = 0, failed = 1 })
        return { cancel = function() released = released + 1; return true end }
    end }, onUpdate = function(current) current:close() end })
    view:submit("Target", nil, 1)
    eq(1, released, "closing during synchronous progress cancels the subsequently returned handle")
end
do
    local receive
    local view = Search.new({ service = { search = function(_, _, _, _, complete)
        receive = complete; return { cancel = function() return true end }
    end } })
    view:submit("Target", { "a" }, 1)
    receive({ groups = { { book = book(1, "Target", "/one") } }, total = 3, completed = 3, succeeded = 2, failed = 1 })
    view:changePage(1)
    eq(2, view.page, "loading screen knows the requested page")
    eq("a", view.source_ids[1], "loading screen retains source selection")
    view:cancel()
    eq(1, view.page, "cancel before any progress restores the visible result page")
    eq("Target", view.results[1].book.name, "cancelled page keeps existing books")
    eq(3, view.progress.total, "cancelled page restores the displayed total")
    eq(3, view.progress.completed, "cancelled page restores the displayed completed count")
    eq(2, view.progress.succeeded, "cancelled page restores the displayed success count")
    eq(1, view.progress.failed, "cancelled page restores the displayed failure count")
end
do
    local calls = {}
    local view = Search.new({ service = { search = function(_, keyword, ids, page, complete)
        calls[#calls + 1] = { keyword = keyword, ids = ids, page = page, complete = complete }
        return { cancel = function() return true end }
    end } })
    view:submit("A", { "a" }, 2)
    calls[1].complete({ groups = { { book = book(1, "A", "/one") } }, total = 3, completed = 3, succeeded = 2, failed = 1 })
    view:submit("B", { "b" }, 1)
    view:cancel()
    eq("A", view.keyword, "cancel before progress restores the displayed books' query")
    eq("a", view.source_ids[1], "cancel before progress restores the displayed books' source selection")
    eq(2, view.page, "cancel before progress restores the displayed books' page")
    eq("A", view.results[1].book.name, "restored criteria still describe the retained books")
    eq(3, view.progress.total, "cancelled new query restores the displayed total")
    eq(3, view.progress.completed, "cancelled new query restores the displayed completed count")
    eq(2, view.progress.succeeded, "cancelled new query restores the displayed success count")
    eq(1, view.progress.failed, "cancelled new query restores the displayed failure count")
    calls[2].complete({ groups = {} })
    eq("A", view.keyword, "late cancelled completion cannot overwrite restored criteria")
    view:changePage(1)
    eq("A", calls[3].keyword, "pagination after cancellation searches the displayed query")
    eq("a", calls[3].ids[1], "pagination after cancellation uses the displayed source selection")
    eq(3, calls[3].page, "pagination after cancellation advances from the displayed page")
    view:submit("B", { "b" }, 1)
    view:submit("C", { "c" }, 1)
    view:cancel()
    eq("A", view.keyword, "superseding pending searches retains the last displayed query for cancellation")
    eq("a", view.source_ids[1], "superseding pending searches retains the last displayed source selection")
    eq(2, view.page, "superseding pending searches retains the last displayed page")
    eq(3, view.progress.completed, "superseding pending searches retains the displayed counters")
    view:submit("Failed", nil, 1)
    local failure = { code = "NETWORK_ERROR" }
    calls[#calls].complete({ groups = {}, errors = {}, total = 1, completed = 1, succeeded = 0, failed = 1 }, failure)
    view:submit("Retry", nil, 1)
    view:cancel()
    eq(failure, view.error, "cancelled replacement restores the displayed aggregate error")
end
return count
