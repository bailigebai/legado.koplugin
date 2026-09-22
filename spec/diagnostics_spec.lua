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
    function service:getBookInfo(value_source, value_book, callback)
        self.info_source, self.info_book = value_source, value_book
        return queue(self, "book_info", callback)
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
    equal("book_info", service.calls[2], "detail waits for a selected search result")
    equal(book, service.info_book, "first search result is selected deterministically")
    local details = { id = book.id, source_id = book.source_id, name = book.name, url = book.url, toc_url = "https://books.test/toc/1" }
    service:respond(2, details, nil, { http_status = 200, charset = "utf-8" })
    equal("catalog", service.calls[3], "catalog waits for details")
    equal(details, service.catalog_book, "catalog uses the enriched book model")
    service:respond(3, { chapter }, nil, { http_status = 206, charset = "gb18030" })
    equal("content", service.calls[4], "content waits for catalog completion")
    equal(chapter, service.content_chapter, "first chapter is diagnosed")
    service:respond(4, { content = "TOP SECRET CHAPTER BODY", pages = 1 }, nil,
        { http_status = 200, charset = "utf-8" })
    equal("completed", final.status, "all four diagnostic steps complete")
    equal(4, #final.steps, "report contains four ordered steps")
    equal("search", final.steps[1].name, "search is the first step")
    equal("book_info", final.steps[2].name, "book details are the second step")
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

local hostile_scan = {
    status = "partial",
    capabilities = { search = true, catalog = true, content = true, SECRET_CAPABILITY = true },
    issues = {
        { field = "extra.https://reader:password@x/?token=SECRET\ncontrol", code = "EXECUTABLE_JS", message = "SECRET message" },
        { field = "ruleContent.%53%45%43%52%45%54", code = "UNKNOWN_SECRET", message = "SECRET unknown" },
    },
    SECRET = "must not survive",
}

local function assert_compatibility_redacted(report, label)
    local serialized = flatten(report)
    equal(nil, serialized:find("SECRET", 1, true), label .. " redacts literal secrets")
    equal(nil, serialized:find("password", 1, true), label .. " redacts URL userinfo")
    equal(nil, serialized:find("token=", 1, true), label .. " redacts query strings")
    equal(nil, serialized:find("%%53%%45%%43%%52%%45%%54"), label .. " redacts encoded key material")
end

do
    local complete_service = {}
    function complete_service:search(_, _, _, callback)
        callback({ groups = { { book = book } } }, nil, { http_status = 200 })
        return { cancel = function() return false end }
    end
    function complete_service:getChapters(_, _, callback)
        callback({ chapter }, nil, { http_status = 200 })
        return { cancel = function() return false end }
    end
    function complete_service:getBookInfo(_, value, callback)
        callback(value, nil, { http_status = 200 })
        return { cancel = function() return false end }
    end
    function complete_service:getContent(_, _, _, callback)
        callback({ content = "body", pages = 1 }, nil, { http_status = 200 })
        return { cancel = function() return false end }
    end
    local completed
    Diagnostics.new({ book_service = complete_service, scanner = { scan = function() return hostile_scan end }, now = function() return 1 end })
        :run(source, "book", function(report) completed = report end)
    assert_compatibility_redacted(completed, "successful diagnostics")

    local failing = fake_service()
    local failed
    Diagnostics.new({ book_service = failing, scanner = { scan = function() return hostile_scan end }, now = function() return 1 end })
        :run(source, "book", function(report) failed = report end)
    failing:respond(1, nil, { code = "NETWORK_ERROR" })
    assert_compatibility_redacted(failed, "failed diagnostics")

    local cancelling = fake_service()
    local cancelled
    local handle = Diagnostics.new({ book_service = cancelling, scanner = { scan = function() return hostile_scan end }, now = function() return 1 end })
        :run(source, "book", function(report) cancelled = report end)
    handle:cancel()
    assert_compatibility_redacted(cancelled, "cancelled diagnostics")
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
    service:respond(2, book, nil, { http_status = 200 })
    service:respond(3, {}, nil, { http_status = 200 })
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
    function synchronous:getBookInfo(_, value, callback)
        callback(value, nil, { http_status = 200 })
        return { cancel = function() error("completed detail must not replace the active request") end }
    end
    local final
    local handle = Diagnostics.new({ book_service = synchronous, now = function() return 1 end })
        :run(source, "book", function(report) final = report end)
    equal(true, handle:cancel(), "sync search followed by async catalog remains cancellable")
    equal(0, search_cancelled, "completed synchronous search handle does not replace the active catalog handle")
    equal(1, catalog_cancelled, "cancellation reaches the actual active catalog handle")
    equal("cancelled", final.steps[3].status, "the actual active catalog step is cancelled")
end

do
    local service = fake_service()
    local final
    Diagnostics.new({ book_service = service }):run(source, "book", function(report) final = report end)
    service:respond(1, { groups = {}, errors = { { code = "UNSUPPORTED_RULE" } } },
        { code = "NETWORK_ERROR", message = "all selected sources failed" })
    equal("UNSUPPORTED_RULE", final.steps[1].error.code, "single-source diagnostics preserves the underlying parser failure")
end

do
    local service = fake_service()
    local final
    Diagnostics.new({ book_service = service }):run(source, "book", function(report) final = report end)
    service:respond(1, { groups = { { book = book } } })
    service:respond(2, nil, { code = "PARSE_ERROR", message = "private detail response" }, { http_status = 200 })
    equal("failed", final.status, "detail rule failures stop the diagnostic")
    equal("PARSE_ERROR", final.steps[2].error.code, "detail failure identifies the actual stage")
    equal("skipped", final.steps[3].status, "failed details do not request a catalog")
    equal(2, #service.calls, "no downstream network requests after detail failure")
    equal(nil, flatten(final):find("private detail response", 1, true), "detail response is not leaked into the report")

    service = fake_service()
    local handle = Diagnostics.new({ book_service = service }):run(source, "book", function(report) final = report end)
    service:respond(1, { groups = { { book = book } } })
    equal(true, handle:cancel(), "detail request can be cancelled")
    equal(true, service.pending[2].cancelled, "cancellation reaches the active detail request")
    equal("cancelled", final.steps[2].status, "detail step records cancellation")
    service:respond(2, book)
    equal(2, #service.calls, "late detail completion cannot request a catalog")
end

return count
