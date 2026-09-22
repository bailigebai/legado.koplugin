local A = require("assertions")
local Json = require("legado.lib.json_codec")
local Safe = require("legado.lib.safe_functions")
local Rules = require("legado.lib.rule_engine")
local Service = require("legado.lib.book_service")
local Importer = require("legado.lib.source_importer")
local count = 0
local function eq(a, b, why) count = count + 1; A.equal(a, b, why) end
local saved = {}
local storage = {
    listSources = function() return saved end,
    replaceSources = function(_, value) saved = value; return true end,
    getSource = function(_, id) for _, source in ipairs(saved) do if source.id == id then return source end end end,
}
local importer = Importer:new({ storage = storage })
local report = importer:importJson([[{
    "bookSourceName":"Local fiction", "bookSourceUrl":"https://fiction.test/",
    "searchUrl":"/search?q={{urlencode(key)}}&page={{page}}",
    "ruleSearch":{"bookList":".book", "name":"a@text", "author":".author@text", "bookUrl":"a@href"},
    "ruleBookInfo":{"name":"h1@text", "tocUrl":"#toc@href"},
    "ruleToc":{"chapterList":"#chapters a", "chapterName":"text", "chapterUrl":"@href"},
    "ruleContent":{"content":".content p@text"}
}]], "fixture.json")
eq(1, report.imported, "standard object-shaped source imports")
eq("usable", report.compatibility[1].status, "object rules are not reported missing")
local pages = {
    ["https://fiction.test/search?q=Sample&page=1"] = '<div class="book"><a href="/book/one">Sample</a><span class="author">Writer</span></div>',
    ["https://fiction.test/book/one"] = '<h1>Sample</h1><a id="toc" href="/toc/one">Chapters</a>',
    ["https://fiction.test/toc/one"] = '<div id="chapters"><a href="/chapter/1">One</a><a href="/chapter/2">Two</a></div>',
    ["https://fiction.test/chapter/1"] = '<div class="content"><p>First paragraph.</p><p>Second paragraph.</p></div>',
    ["https://fiction.test/chapter/2"] = '<div class="content"></div>',
}
local rules = Rules.new({ json_decoder = Json, html_parser = require("legado.vendor.htmlparser"),
    safe_functions = Safe.functions, url_resolver = Safe.resolve_url })
local service = Service.new({ storage = storage, rule_engine = rules,
    url_template = require("legado.lib.url_template").new({ rule_engine = rules }),
    request_engine = { execute = function(_, request, callback)
        local body = assert(pages[request.url], "unexpected URL: " .. request.url)
        callback({ body = body, status = 200, final_url = request.url })
        return { cancel = function() return false end }
    end },
})
local result, failure
service:search("Sample", nil, 1, function(value, err) result, failure = value, err end)
eq(nil, failure, "real HTML search succeeds")
eq(1, #result.groups, "bookList retains markup for nested fields")
local book = result.groups[1].book
eq("Writer", book.author, "author belongs to the selected result")
eq("https://fiction.test/book/one", book.url, "book URL remains absolute")
service:getBookInfo(saved[1], book, function(value, err) book, failure = value, err end)
eq(nil, failure, "real HTML detail succeeds")
eq("https://fiction.test/toc/one", book.toc_url, "separate catalog URL is extracted")
local chapters
service:getChapters(saved[1], book, function(value, err) chapters, failure = value, err end)
eq(nil, failure, "real HTML catalog succeeds")
eq(2, #chapters, "chapterList preserves anchor roots")
eq("Two", chapters[2].title, "current-element text extracts the chapter title")
eq("https://fiction.test/chapter/1", chapters[1].url, "current-element href extracts the chapter URL")
local content
service:getContent(saved[1], book, chapters[1], function(value, err) content, failure = value, err end)
eq(nil, failure, "real HTML content succeeds")
eq("First paragraph.\nSecond paragraph.", content.content, "all paragraphs survive scalar content extraction")
service:getContent(saved[1], book, chapters[2], function(value, err) content, failure = value, err end)
eq(nil, content, "empty chapter must not be cached as a successful download")
eq("PARSE_ERROR", failure.code, "empty content explains source failure")
local diagnostic
require("legado.lib.diagnostics").new({ book_service = service }):run(saved[1], "Sample",
    function(value) diagnostic = value end)
eq("completed", diagnostic.status, "diagnostics fetches detail before following its separate catalog URL")
eq("book_info", diagnostic.steps[2].name, "second diagnostic step explicitly checks book details")
eq(200, diagnostic.steps[2].http_status, "detail response status is recorded")
eq(2, diagnostic.steps[3].field_counts.chapters, "diagnostics uses the catalog URL from the detail page")
return count
