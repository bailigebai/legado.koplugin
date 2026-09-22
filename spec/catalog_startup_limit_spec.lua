local A = require('assertions')
local Json = require('legado.lib.json_codec')
local Rules = require('legado.lib.rule_engine')
local Safe = require('legado.lib.safe_functions')
local Models = require('legado.lib.models')
local Service = require('legado.lib.book_service')
local Templates = require('legado.lib.url_template')
local count = 0
local function eq(a, b, message) count = count + 1; A.equal(a, b, message) end
local source = { bookSourceUrl = 'https://books.test/', ruleToc = {
    chapterList = '$.chapters[*]', chapterName = '$.title', chapterUrl = '$.url', isVip = '$.vip', nextTocUrl = '$.next',
} }
local book = Models.book(source, { name = 'Book', url = '/book' }, source.bookSourceUrl)
local function fixture()
    local rules = Rules.new({ json_decoder = Json, safe_functions = Safe.functions, url_resolver = Safe.resolve_url })
    local reads = { ['$.title'] = 0, ['$.url'] = 0, ['$.vip'] = 0 }
    local parse = rules.parse
    function rules:parse(input, rule, context, list)
        if reads[rule] then reads[rule] = reads[rule] + 1 end
        return parse(self, input, rule, context, list)
    end
    local engine = { callbacks = {}, cancelled = 0 }
    function engine:execute(_, callback)
        self.callbacks[#self.callbacks + 1] = callback
        return { cancel = function() self.cancelled = self.cancelled + 1 end }
    end
    function engine:respond(index, rows, next_url)
        self.callbacks[index]({ status = 200, charset = 'utf-8', final_url = 'https://books.test/toc/' .. index,
            body = Json.encode({ chapters = rows, next = next_url }) })
    end
    return Service.new({ storage = {}, rule_engine = rules, request_engine = engine,
        url_template = Templates.new({ rule_engine = rules }) }), engine, reads
end
local rows = {}
for i = 1, 1000 do rows[i] = { title = 'Chapter ' .. i, url = '/chapter/' .. i, vip = false } end
do
    local service, request, reads = fixture()
    local chapters, metadata, progress
    service:getChapters(source, book, function(v, e, m) assert(not e); chapters, metadata = v, m end,
        { max_pages = 1, max_chapters = 3, on_progress = function(_, n) progress = n end })
    request:respond(1, rows)
    eq(3, #chapters, 'startup only returns the first three chapters from a thousand-row page')
    for _, rule in ipairs({ '$.title', '$.url', '$.vip' }) do eq(3, reads[rule], 'startup only evaluates three ' .. rule .. ' rules') end
    eq('https://books.test/chapter/1', chapters[1].url, 'startup begins with the first actual chapter')
    eq(false, metadata.catalog_complete, 'remaining rows make the catalog partial without a next-page link')
    eq(200, metadata.http_status, 'startup retains response diagnostics')
    eq(3, progress, 'progress reports only prepared chapters')
end
for _, scenario in ipairs({ { n = 2, complete = true }, { n = 3, complete = true }, { n = 3, next = '/next', complete = false } }) do
    local service, request = fixture()
    local chapters, metadata
    service:getChapters(source, book, function(v, e, m) assert(not e); chapters, metadata = v, m end, { max_chapters = 3 })
    local subset = {}; for i = 1, scenario.n do subset[i] = rows[i] end
    request:respond(1, subset, scenario.next)
    eq(scenario.n, #chapters, 'small catalog retains all available chapters')
    eq(scenario.complete, metadata.catalog_complete, 'exact cap distinguishes a complete catalog from a next page')
    eq(1, #request.callbacks, 'chapter cap does not request a redundant page')
end
do
    local service, request = fixture()
    local chapters
    service:getChapters(source, book, function(v, e) assert(not e); chapters = v end, { max_chapters = 3 })
    request:respond(1, { { title = 'Volume', url = '' }, rows[1], rows[1], rows[2], rows[3], rows[4] })
    eq(3, #chapters, 'empty and duplicate links do not consume the startup allowance')
    eq('Chapter 3', chapters[3].title, 'startup cap counts unique readable chapters')
    eq(3, chapters[3].index, 'startup chapter indexes stay dense')
end
do
    local service, request = fixture()
    local chapters, metadata
    service:getChapters(source, book, function(v, e, m) assert(not e); chapters, metadata = v, m end)
    request:respond(1, { rows[1], rows[2] }, '/next')
    eq(nil, chapters, 'normal catalog continues to wait for pagination')
    request:respond(2, { rows[2], rows[3], rows[4] })
    eq(4, #chapters, 'normal catalog keeps all unique chapters across pages')
    eq(true, metadata.catalog_complete, 'normal catalog marks complete after the last page')
end
do
    local service, request, reads = fixture()
    local calls = 0
    local handle = service:getChapters(source, book, function() calls = calls + 1 end, { max_chapters = 3 })
    handle:cancel(); request:respond(1, rows)
    eq(0, calls, 'cancelled startup cannot notify the reader')
    eq(0, reads['$.title'], 'cancelled startup does no chapter parsing')
    eq(1, request.cancelled, 'cancelled startup cancels its network request')
end
do
    local service, request = fixture()
    local calls, handle = 0
    handle = service:getChapters(source, book, function() calls = calls + 1 end,
        { max_chapters = 3, on_progress = function() handle:cancel() end })
    request:respond(1, rows)
    eq(0, calls, 'cancellation from startup progress suppresses completion')
end
return count
