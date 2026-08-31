local assertx = require("assertions")
local Diagnostics = require("legado.lib.diagnostics")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local source = { id = "source-1", bookSourceName = "Safe source" }
local book = { id = "book-1", source_id = "source-1", name = "Chosen", author = "Author", url = "https://books.test/b/1" }
local chapter = { uid = "chapter-1", book_id = "book-1", source_id = "source-1", title = "One", url = "https://books.test/c/1" }

local function fake_service()
    local service = { calls = {}, pending = {}, cancelled = 0 }
    local function queue(self, name, callback)
        self.calls[#self.calls + 1] = name
        local item = { callback = callback, cancelled = false }
        self.pending[#self.pending + 1] = item
        return { cancel = function()
            if item.cancelled then return false end
            item.cancelled = true
            self.cancelled = self.cancelled + 1
            return true
        end }
    end
    function service:search(keyword, ids, page, callback)
        self.keyword, self.ids, self.page = keyword, ids, page
        return queue(self, "search", callback)
    end
    function service:getChapters(value_source, value_book, callback)
        self.catalog_source, self.catalog_book = value_source, value_book
        return queue(self, "catalog", callback)
    end
    function service:getContent(value_source, value_book, value_chapter, callback)
        self.content_source, self.content_book, self.content_chapter = value_source, value_book, value_chapter
        return queue(self, "content", callback)
    end
    function service:respond(index, value, err, metadata)
        self.pending[index].callback(value, err, metadata)
    end
    return service
end

do
    local service = fake_service()
    local ticks = { 1.000, 1.125, 1.250, 1.500, 1.750, 2.000, 2.250, 2.625 }
    local tick = 0
    local final
    local diagnostics = Diagnostics.new({
        book_service = service,
        scanner = { scan = function() return { status = "usable", capabilities = { search = true, catalog = true, content = true }, issues = {} } end },
        now = function() tick = tick + 1; return ticks[tick] end,
    })
    local handle = diagnostics:run(source, "private keyword", function(report) final = report end)
    equal("table", type(handle), "diagnostics returns a cancellable handle")
    equal("search", service.calls[1], "search starts first")
    service:respond(1, { groups = { { book = book, alternatives = { book } } }, errors = {} }, nil,
        { http_status = 200, charset = "utf-8" })
    equal("catalog", service.calls[2], "catalog waits for a selected search result")
    equal(book, service.catalog_book, "first search result is selected deterministically")
    service:respond(2, { chapter }, nil, { http_status = 206, charset = "gb18030" })
    equal("content", service.calls[3], "content waits for catalog completion")
    equal(chapter, service.content_chapter, "first chapter is diagnosed")
    service:respond(3, { content = "TOP SECRET CHAPTER BODY", pages = 1 }, nil,
        { http_status = 200, charset = "utf-8" })
    equal("completed", final.status, "all four diagnostic steps complete")
    equal(4, #final.steps, "report contains four ordered steps")
    equal("search", final.steps[1].name, "search is the first step")
    equal("result", final.steps[2].name, "result selection is the second step")
    equal("catalog", final.steps[3].name, "catalog is the third step")
    equal("content", final.steps[4].name, "content is the fourth step")
    equal("success", final.steps[4].status, "content step succeeds")
    equal(200, final.steps[4].http_status, "safe HTTP status is retained")
    equal("utf-8", final.steps[4].charset, "safe charset is retained")
    equal(1, final.steps[3].field_counts.chapters, "catalog field count is retained")
    equal(1, final.steps[4].field_counts.pages, "content page count is retained without content")
    truthy(type(final.steps[1].duration_ms) == "number" and final.steps[1].duration_ms >= 0,
        "duration uses the injected clock")
end

local function flatten(value, seen)
    if type(value) ~= "table" then return tostring(value) end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local output = {}
    for key, child in pairs(value) do output[#output + 1] = tostring(key); output[#output + 1] = flatten(child, seen) end
    seen[value] = nil
    return table.concat(output, "|")
end

do
    local service = fake_service()
    local final
    local diagnostics = Diagnostics.new({ book_service = service, now = function() return 10 end })
    diagnostics:run(source, "query-secret", function(report) final = report end)
    service:respond(1, nil, {
        code = "NETWORK_ERROR", message = "Authorization: Bearer auth-secret Cookie=session-secret",
        details = {
            status = 403,
            url = "https://books.test/search?token=query-secret&key=hidden",
            request_body = "body-secret", response_body = "chapter-secret",
        },
    })
    equal("failed", final.status, "search failure stops diagnostics")
    equal("failed", final.steps[1].status, "failed step is explicit")
    equal("skipped", final.steps[2].status, "dependent result step is skipped")
    equal("skipped", final.steps[3].status, "dependent catalog step is skipped")
    equal("skipped", final.steps[4].status, "dependent content step is skipped")
    equal("NETWORK_ERROR", final.steps[1].error.code, "structured safe error code is retained")
    equal(403, final.steps[1].http_status, "safe error HTTP status is retained")
    local serialized = flatten(final)
    equal(nil, serialized:find("auth%-secret"), "authorization secret is redacted")
    equal(nil, serialized:find("session%-secret"), "cookie secret is redacted")
    equal(nil, serialized:find("query%-secret"), "query secret is redacted")
    equal(nil, serialized:find("body%-secret"), "request body is never retained")
    equal(nil, serialized:find("chapter%-secret"), "response body is never retained")
    equal(1, #service.calls, "failed diagnostics issue no dependent requests")
end

do
    local service = fake_service()
    local final
    local diagnostics = Diagnostics.new({ book_service = service, now = function() return 1 end })
    local handle = diagnostics:run(source, "book", function(report) final = report end)
    equal(true, handle:cancel(), "active diagnostics can be cancelled")
    equal(1, service.cancelled, "cancel reaches active network handle")
    equal("cancelled", final.status, "cancel completes with a cancelled report")
    equal("cancelled", final.steps[1].status, "active step is marked cancelled")
    equal("skipped", final.steps[2].status, "unstarted steps are skipped on cancellation")
    equal(false, handle:cancel(), "cancellation is idempotent")
    service:respond(1, { groups = { { book = book } } }, nil, { http_status = 200 })
    equal(1, #service.calls, "late callback after cancel cannot continue diagnostics")
end

do
    local service = fake_service()
    local final
    local diagnostics = Diagnostics.new({ book_service = service, now = function() return 1 end })
    diagnostics:run(source, "book", function(report) final = report end)
    service:respond(1, { groups = {}, errors = {} }, nil, { http_status = 200, charset = "utf-8" })
    equal("failed", final.status, "empty search result is a structured failure")
    equal("NO_SEARCH_RESULT", final.steps[2].error.code, "selection failure has a stable code")
    equal(1, #service.calls, "empty results do not fetch a catalog")
end

do
    local service = fake_service()
    local final
    local diagnostics = Diagnostics.new({ book_service = service, now = function() return 1 end })
    diagnostics:run(source, "book", function(report) final = report end)
    service:respond(1, { groups = { { book = book } }, errors = {} }, nil, { http_status = 200 })
    service:respond(2, {}, nil, { http_status = 200 })
    equal("failed", final.status, "empty catalog fails without throwing")
    equal("NO_CHAPTER", final.steps[3].error.code, "empty catalog has a stable error code")
    equal("skipped", final.steps[4].status, "empty catalog does not fetch content")
end

do
    local search_cancelled, catalog_cancelled = 0, 0
    local synchronous = {}
    function synchronous:search(_, _, _, callback)
        callback({ groups = { { book = book } }, errors = {} }, nil, { http_status = 200 })
        return { cancel = function() search_cancelled = search_cancelled + 1; return true end }
    end
    function synchronous:getChapters(_, _, callback)
        self.catalog_callback = callback
        return { cancel = function() catalog_cancelled = catalog_cancelled + 1; return true end }
    end
    local final
    local handle = Diagnostics.new({ book_service = synchronous, now = function() return 1 end })
        :run(source, "book", function(report) final = report end)
    equal(true, handle:cancel(), "sync search followed by async catalog remains cancellable")
    equal(0, search_cancelled, "completed synchronous search handle does not replace the active catalog handle")
    equal(1, catalog_cancelled, "cancellation reaches the actual active catalog handle")
    equal("cancelled", final.steps[3].status, "the actual active catalog step is cancelled")
end

return count
