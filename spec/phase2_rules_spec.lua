local A = require('assertions')
local Safe = require('legado.lib.safe_functions')
local Rules = require('legado.lib.rule_engine')
local Json = require('legado.lib.json_codec')
local Capabilities = require('legado.lib.rule_capabilities')
local count = 0
local function eq(want, got, why) count = count + 1; A.equal(want, got, why) end
local rules = Rules.new { json_decoder = Json, html_parser = require('legado.vendor.htmlparser'), safe_functions = Safe.functions, url_resolver = Safe.resolve_url }

local cases = {
    { '<Note>  介绍  </Note>', 'Note@js:result.trim()', '介绍' }, -- collection #369
    { '<meta property="og:image" content="https://covers.test/book.jpg@small"/>', '//*[@property="og:image"]/@content@js:result.split("@")[0]', 'https://covers.test/book.jpg' }, -- #126
    { '<p>小说作者：某人 小说大小 1MB</p>', 'p@text##小说作者：\n@js:result.split("小说大小")[0].trim()', '某人' }, -- #372
    { '第章第章', '@js:result.replace("第章", "")', '第章' },
    { '\194\160\239\187\191 中 文 \226\128\137', '@js:result.trim()', '中 文' },
}
for _, case in ipairs(cases) do
    local value, err = rules:parse(case[1], case[2], {}, false)
    eq(nil, err and err.code, 'recognized restricted string expression evaluates')
    eq(case[3], value, 'restricted expression preserves its declared string semantics')
    eq(nil, Capabilities.findUnsupported(case[2]), 'static compatibility uses the same restricted grammar')
end
eq('offset=20', rules:expandTemplate('offset={{(page-1)*10}}', { page = 3 }), 'page arithmetic observes parentheses and precedence')
eq('n=7', rules:expandTemplate('n={{page+2*3}}', { page = 1 }), 'multiplication precedes addition')
eq('x=-1', rules:expandTemplate('x={{-5%2}}', {}), 'remainder uses the dividend sign')
eq('line=\n', rules:expandTemplate('line={{"\\n"}}', {}), 'quoted template string decodes escape sequences')

for _, expression in ipairs({ 'result.trim(); java.ajax("https://bad.test")', 'result.match(/.*/)', 'result.split("")[0]',
    'result.replace("x", "$&")', 'result.constructor("return 1")()', 'result["trim"]()', 'result.trim() + unknown',
    'while(true){}', 'result.trim() // comment', 'result.trim(); result.trim()' }) do
    local _, err = rules:parse(' x ', '@js:' .. expression, {}, false)
    eq('UNSUPPORTED_RULE', err and err.code, 'unknown executable or unsupported syntax is rejected as a whole')
end
local _, divided = rules:expandTemplate('{{page/0}}', { page = 1 })
eq('PARSE_ERROR', divided and divided.code, 'non-finite arithmetic cannot enter a URL')
local _, long = rules:parse('x', '@js:result' .. string.rep('.trim()', 40), {}, false)
eq('UNSUPPORTED_RULE', long and long.code, 'expression depth has a finite bound')
local _, expanded = rules:parse(string.rep('x', 3 * 1024 * 1024), '@js:result.trim()+result', {}, false)
eq('PARSE_ERROR', expanded and expanded.code, 'expression result cannot exceed the bounded chapter payload')

local value, err = rules:parse('{"a":{"list":[{"name":"One"}]},"b":{"list":[{"name":"Two"}]}}', '$..list[*].name', {}, true)
eq(nil, err and err.code, 'named recursive JSONPath supports collection examples')
eq('One', value and value[1], 'recursive JSONPath has stable object traversal order')
eq('Two', value and value[2], 'recursive JSONPath visits later descendant objects')
local cycle = {}; cycle.self = cycle
local _, cyclic = rules:parse(cycle, '$..list', {}, true)
eq('PARSE_ERROR', cyclic and cyclic.code, 'recursive JSONPath rejects cycles rather than hanging')

local elements, element_error = rules:parseElements('<p> One </p><p> Two </p>', 'p@text@js:result.trim()', {})
eq(nil, element_error and element_error.code, 'element lists share the restricted expression grammar')
eq('Two', elements and elements[2], 'element list transformation preserves all extracted values')
local Templates = require('legado.lib.url_template')
local request, request_error = Templates.new { rule_engine = rules }:build(' /page/{{(page-1)*10}} @js:result.trim()', { page = 3 })
eq(nil, request_error and request_error.code, 'URL suffix transformation uses the shared expression evaluator')
eq('/page/20', request and request.url, 'URL expression applies after template expansion')
local _, unsupported_url = Templates.new { rule_engine = rules }:build('@js:java.ajax(result)', {})
eq('UNSUPPORTED_RULE', unsupported_url and unsupported_url.code, 'request templates reject unsupported executable suffixes')
local large = {}; for i = 1, 600 do large[i] = {}; for j = 1, 20 do large[i][j] = j end end
local _, nodes = rules:parse(large, '$[*]..missing', {}, true)
eq('PARSE_ERROR', nodes and nodes.code, 'recursive JSONPath has one traversal budget across input roots')
local deep = {}; local cursor = deep
for i = 1, 66 do cursor.child = {}; cursor = cursor.child end
local _, depth_error = rules:parse(deep, '$..missing', {}, true)
eq('PARSE_ERROR', depth_error and depth_error.code, 'recursive JSONPath rejects deeply nested inputs')
local many = {}; for i = 1, 1001 do many[i] = { found = i } end
local _, output_error = rules:parse(many, '$..found', {}, true)
eq('PARSE_ERROR', output_error and output_error.code, 'recursive JSONPath caps matching results')
local _, tokens = rules:parse('x', '@js:result' .. string.rep('.replace("x","x")', 35), {}, false)
eq('UNSUPPORTED_RULE', tokens and tokens.code, 'restricted expressions reject excessive tokens')
eq('', rules:parse(string.rep(' ', 65536), '@js:result.trim()', {}, false), 'large whitespace strings trim without repeated string copying')

do
    local Service = require('legado.lib.book_service')
    local Models = require('legado.lib.models')
    local source = { id = 'reverse', bookSourceUrl = 'https://books.test/', ruleToc = { chapterList = '-$.chapters[*]', chapterName = '$.name', chapterUrl = '$.url', nextTocUrl = '$.next' } }
    local book = { id = 'book', source_id = Models.sourceId(source), url = 'https://books.test/toc' }
    local pending, result, metadata, result_error = {}, nil, nil, nil
    local service = Service.new { storage = {}, rule_engine = rules, url_template = require('legado.lib.url_template').new { rule_engine = rules },
        request_engine = { execute = function(_, request, callback) pending[#pending + 1] = { request = request, callback = callback }; return {cancel=function() end} end } }
    service:getChapters(source, book, function(value, _, trace) result, metadata = value, trace end)
    pending[1].callback { body = '{"chapters":[{"name":"Four","url":"/4"},{"name":"Three","url":"/3"}],"next":"/toc2"}', final_url = 'https://books.test/toc' }
    eq(2, #pending, 'reversed catalog still follows the next catalog page')
    pending[2].callback { body = '{"chapters":[{"name":"Two","url":"/2"},{"name":"One","url":"/1"}]}', final_url = 'https://books.test/toc2' }
    eq('One', result and result[1].title, 'catalog reverse applies across the entire catalog rather than inside each page')
    eq('Four', result and result[4].title, 'reversed catalog ends with its latest chapter')
    eq(1, result and result[1].index, 'reordered chapter indices follow the reading order')
    eq(4, result and result[4].index, 'reordered final chapter index is stable')
    eq(true, metadata and metadata.catalog_complete, 'all catalog pages produce a complete reversed catalog')
    service:getChapters(source, book, function(value, err, trace) result, result_error, metadata = value, err, trace end, { max_pages = 1 })
    pending[3].callback { body = '{"chapters":[{"name":"Four","url":"/4"},{"name":"Three","url":"/3"}],"next":"/toc2"}', final_url = 'https://books.test/toc' }
    eq(3, #pending, 'reversed catalog respects the caller page budget')
    eq(nil, result, 'reversed partial catalog cannot expose late chapters with false first-chapter indices')
    eq('PARSE_ERROR', result_error and result_error.code, 'insufficient reverse catalog budget reports that first-chapter order is unknown')
    service:getChapters(source, book, function(value, err, trace) result, result_error, metadata = value, err, trace end, { max_chapters = 2 })
    pending[4].callback { body = '{"chapters":[{"name":"Four","url":"/4"},{"name":"Three","url":"/3"}],"next":"/toc2"}', final_url = 'https://books.test/toc' }
    eq(5, #pending, 'reverse catalog ignores the startup chapter cap until its first chapter is known')
    pending[5].callback { body = '{"chapters":[{"name":"Two","url":"/2"},{"name":"One","url":"/1"}]}', final_url = 'https://books.test/toc2' }
    eq('One', result and result[1].title, 'startup first chapter is the original final chapter even with a small chapter cap')
    eq(1, result and result[1].index, 'only the verified first chapter gets the first reading index')
    eq(true, metadata and metadata.catalog_complete, 'fully fetched reverse catalog is reused rather than discarded after ordering')
end
return count
