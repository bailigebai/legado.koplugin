local assertx = require("assertions")
local Json = require("legado.lib.json_codec")
local HtmlParser = require("legado.vendor.htmlparser")
local RuleEngine = require("legado.lib.rule_engine")
local SafeFunctions = require("legado.lib.safe_functions")
local UrlTemplate = require("legado.lib.url_template")
local BookService = require("legado.lib.book_service")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function new_rule_engine()
    return RuleEngine.new({
        json_decoder = Json, html_parser = HtmlParser,
        safe_functions = SafeFunctions.functions, url_resolver = SafeFunctions.resolve_url,
    })
end

local sources = {
    a = {
        id = "a", bookSourceName = "Source A", bookSourceUrl = "https://a.test/root/", enabled = true,
        searchUrl = "search?keyword={{urlencode(key)}}&page={{page}}",
        header = { ["X-Source"] = "A" },
        ruleSearch = {
            bookList = "$.items[*]", name = "$.name", author = "$.author", bookUrl = "$.url",
            coverUrl = "$.cover", intro = "$.intro", kind = "$.kind", lastChapter = "$.last",
        },
        ruleBookInfo = {
            name = "$.name", author = "$.author", intro = "$.intro", tocUrl = "$.toc",
        },
        ruleToc = { chapterList = "$.chapters[*]", chapterName = "$.title", chapterUrl = "$.url", isVip = "$.vip", nextTocUrl = "$.next" },
        ruleContent = { content = "$.content", nextContentUrl = "$.next" },
    },
    b = {
        id = "b", bookSourceName = "Source B", bookSourceUrl = "https://b.test/", enabled = true,
        searchUrl = "find/{{urlencode(key)}}/{{page}}",
        ruleSearch = { bookList = "$.items[*]", name = "$.name", author = "$.author", bookUrl = "$.url" },
        ruleBookInfo = { name = "$.name" }, ruleToc = { chapterList = "$.chapters[*]", chapterName = "$.title", chapterUrl = "$.url" },
        ruleContent = { content = "$.content" },
    },
    off = { id = "off", bookSourceName = "Disabled", bookSourceUrl = "https://off.test/", enabled = false },
    h = {
        id = "h", bookSourceName = "Header source", bookSourceUrl = "https://h.test/", enabled = true,
        header = { ["X-Key"] = "source-{{key}}", ["X-Page"] = "page-{{page}}" },
        searchUrl = { url = "search", method = "POST", body = "{{key}}/{{page}}", headers = { ["x-key"] = "request-{{page}}" } },
        ruleSearch = { bookList = "$.items[*]", name = "$.name", author = "$.author", bookUrl = "$.url" },
    },
}

local storage = {}
function storage:getSource(id) return sources[id] end
function storage:listSources() return { sources.a, sources.b, sources.off } end

local function controlled_engine()
    local engine = { pending = {}, requests = {}, active = 0, peak = 0, cancelled = 0 }
    function engine:execute(request, callback)
        self.requests[#self.requests + 1] = request
        self.active = self.active + 1
        self.peak = math.max(self.peak, self.active)
        local entry = { request = request, callback = callback, done = false, cancelled = false }
        self.pending[#self.pending + 1] = entry
        return { cancel = function()
            if entry.done or entry.cancelled then return false end
            entry.cancelled = true; engine.cancelled = engine.cancelled + 1; engine.active = engine.active - 1
            return true
        end }
    end
    function engine:respond(index, response, err)
        local entry = assert(self.pending[index])
        if entry.done or entry.cancelled then return end
        entry.done = true; self.active = self.active - 1
        entry.callback(response, err)
    end
    return engine
end

local function new_service(request_engine, concurrency, scheduler)
    local rules = new_rule_engine()
    return BookService.new({
        storage = storage, rule_engine = rules, request_engine = request_engine,
        url_template = UrlTemplate.new({ rule_engine = rules }),
        settings = { get = function(_, key) return key == "concurrency" and concurrency or nil end },
        scheduler = scheduler,
    })
end

do
    local request = controlled_engine()
    local service = new_service(request, 2)
    local result, finish_error
    local handle = service:search("space key", { "a", "b" }, 2, function(value, err) result, finish_error = value, err end)
    equal(2, #request.requests, "search starts up to configured concurrency")
    equal(2, request.peak, "search never exceeds concurrency")
    equal("https://a.test/root/search?keyword=space%20key&page=2", request.requests[1].url, "search URL uses key/page and source base")
    equal("A", request.requests[1].headers["X-Source"], "source headers are passed to request engine")
    equal("a", request.requests[1].source_id, "request cookies remain source isolated")
    request:respond(2, nil, { code = "NETWORK_ERROR", message = "secret host failure", details = { token = "do-not-show" } })
    equal(nil, result, "multi-source callback waits for all sources")
    request:respond(1, {
        status = 200, final_url = "https://a.test/results/page2/index.json",
        body = '{"items":[{"name":" Shared ","author":"Alice","url":"../book/1","cover":"/cover/1.jpg"},{"name":"Unique","author":"Bob","url":"book/2"}]}'
    })
    equal(nil, finish_error, "partial source failure preserves successful results")
    equal(2, #result.groups, "successful source results are returned")
    equal(1, #result.errors, "failed source is isolated and reported")
    equal(Models.sourceId(sources.b), result.errors[1].source_id, "errors expose only opaque source identifiers")
    equal(nil, result.errors[1].message:find("secret", 1, true), "UI-safe source error omits transport secrets")
    equal("https://a.test/results/book/1", result.groups[1].book.url, "relative book URL resolves from response final URL")
    equal("https://a.test/cover/1.jpg", result.groups[1].book.cover_url, "root-relative cover resolves from response final URL")
    equal(1, #result.groups[1].alternatives, "group retains its first source alternative")
    equal(false, handle:isCancelled(), "completed composite handle is not cancelled")
end

do
    local request = controlled_engine()
    local service = new_service(request, 1)
    local search_metadata
    service:search("trace", { "a" }, 1, function(_, _, metadata) search_metadata = metadata end)
    request:respond(1, { status = 201, charset = "gb18030", final_url = "https://a.test/search", body = '{"items":[]}' })
    equal(201, search_metadata.http_status, "single-source search exposes safe diagnostic HTTP status")
    equal("gb18030", search_metadata.charset, "single-source search exposes safe diagnostic charset")
end

do
    local request = controlled_engine()
    local service = new_service(request, 1)
    local result
    local handle = service:search("shared", nil, 1, function(value) result = value end)
    equal(1, #request.requests, "all-enabled search respects concurrency one")
    request:respond(1, { status = 200, final_url = "https://a.test/s", body = '{"items":[{"name":" Shared ","author":"Alice","url":"/a"}]}' })
    equal(2, #request.requests, "queue starts next source after completion")
    request:respond(2, { status = 200, final_url = "https://b.test/s", body = '{"items":[{"name":"shared","author":"ALICE","url":"/b"},{"name":"Third","author":"C","url":"/c"}]}' })
    equal(2, #result.groups, "identical title and author aggregate stably")
    equal(2, #result.groups[1].alternatives, "aggregation preserves both source choices")
    equal(Models.sourceId(sources.a), result.groups[1].alternatives[1].source_id, "first selected source remains primary")
    equal(Models.sourceId(sources.b), result.groups[1].alternatives[2].source_id, "later alternative remains ordered")
    truthy(result.groups[1].alternatives[1].id ~= result.groups[1].alternatives[2].id, "source switching changes book identity")
    equal(true, handle:cancel() == false, "completed aggregate cannot be cancelled")
end

do
    local request = controlled_engine()
    local service = new_service(request, 2)
    local callback_count = 0
    local handle = service:search("cancel", { "a", "b" }, 1, function() callback_count = callback_count + 1 end)
    equal(true, handle:cancel(), "composite cancellation changes state once")
    equal(false, handle:cancel(), "composite cancellation is idempotent")
    equal(2, request.cancelled, "composite cancellation cancels every active request")
    request:respond(1, { status = 200, body = '{"items":[]}', final_url = "https://a.test/s" })
    equal(0, callback_count, "cancelled search never mutates its consumer")
end

do
    local request = controlled_engine()
    local service = new_service(request, 2)
    local all_failed, all_error
    service:search("fail", { "a", "b" }, 1, function(value, err) all_failed, all_error = value, err end)
    request:respond(1, nil, { code = "TIMEOUT", message = "raw timeout" })
    request:respond(2, nil, { code = "NETWORK_ERROR", message = "raw network" })
    equal(0, #all_failed.groups, "all-failed search still returns an empty result object")
    equal(2, #all_failed.errors, "all failures remain diagnosable")
    equal("NETWORK_ERROR", all_error.code, "all-failed search reports an aggregate error")
end

do
    local request = controlled_engine()
    local service = new_service(request, 2)
    local detail
    local seed = { id = "seed", source_id = Models.sourceId(sources.a), name = "Seed", author = "A", url = "https://a.test/books/1" }
    service:getBookInfo(sources.a, seed, function(value, err) assert(not err); detail = value end)
    request:respond(1, { status = 200, final_url = "https://cdn.test/detail/1.json", body = '{"name":"Full","author":"Alice","intro":"About","toc":"../toc/1.json"}' })
    equal("https://cdn.test/toc/1.json", detail.toc_url, "detail toc URL resolves from detail final URL")
    local chapters
    service:getChapters(sources.a, detail, function(value, err) assert(not err); chapters = value end)
    equal("https://cdn.test/toc/1.json", request.requests[2].url, "catalog uses parsed toc URL")
    request:respond(2, { status = 200, final_url = "https://cdn.test/toc/1.json", body = '{"chapters":[{"title":"One","url":"../content/1","vip":false}],"next":"page2.json"}' })
    equal(nil, chapters, "multi-page catalog waits for the continuation page")
    equal("https://cdn.test/toc/page2.json", request.requests[3].url, "catalog continuation resolves from response final URL")
    request:respond(3, { status = 200, final_url = "https://cdn.test/toc/page2.json", body = '{"chapters":[{"title":"Two","url":"../content/2","vip":true}]}' })
    equal(2, #chapters, "catalog concatenates chapter pages")
    equal("https://cdn.test/content/1", chapters[1].url, "chapter URL resolves from catalog final URL")
    equal(2, chapters[2].index, "chapter indexes remain stable across catalog pages")
    local content
    service:getContent(sources.a, detail, chapters[1], function(value, err) assert(not err); content = value end)
    request:respond(4, { status = 200, final_url = chapters[1].url, body = '{"content":"Chapter body","next":"/content/2"}' })
    equal(nil, content, "multi-page content waits for the continuation page")
    equal("https://cdn.test/content/2", request.requests[5].url, "content pagination URL resolves from final URL")
    request:respond(5, { status = 200, final_url = "https://cdn.test/content/2", body = '{"content":"Continued"}' })
    equal("Chapter body\nContinued", content.content, "content pages concatenate in network order")
    equal(nil, content.next_url, "completed content has no remaining continuation URL")
    equal(5, #request.requests, "catalog and content follow only the selected source")
end


do
    local request = controlled_engine()
    local service = new_service(request, 2)
    service:search("header key", { "h" }, 3, function() end)
    equal("request-3", request.requests[1].headers["x-key"], "request option header overrides source header case-insensitively")
    equal(nil, request.requests[1].headers["X-Key"], "case-insensitive merge emits no duplicate header")
    equal("page-3", request.requests[1].headers["X-Page"], "source headers expand with page context")
    equal("header key/3", request.requests[1].body, "request option body expands with key and page")
end

do
    local request = controlled_engine()
    local scheduler = { queue = {} }
    function scheduler:scheduleIn(_, action) self.queue[#self.queue + 1] = action; return action end
    function scheduler:runAll() while #self.queue > 0 do table.remove(self.queue, 1)() end end
    local service = new_service(request, 2, scheduler)
    local book = Models.book(sources.a, { name = "A", url = "/book" }, sources.a.bookSourceUrl)
    local chapter = Models.chapter(book, sources.a, { index = 1, title = "One", url = "/one" }, sources.a.bookSourceUrl)
    local callbacks = {}
    service:getBookInfo(sources.b, book, function(value, err) callbacks[#callbacks + 1] = err end)
    service:getChapters(sources.b, book, function(value, err) callbacks[#callbacks + 1] = err end)
    service:getContent(sources.a, book, { uid = chapter.uid, source_id = Models.sourceId(sources.b), book_id = book.id, url = chapter.url }, function(value, err) callbacks[#callbacks + 1] = err end)
    equal(0, #callbacks, "invalid ownership callbacks are always deferred")
    equal(0, #request.requests, "invalid ownership never reaches RequestEngine")
    scheduler:runAll()
    equal(3, #callbacks, "all four-flow ownership checks use the scheduler boundary")
    for _, err in ipairs(callbacks) do equal("INVALID_INPUT", err.code, "ownership error is structured") end
end

return count
