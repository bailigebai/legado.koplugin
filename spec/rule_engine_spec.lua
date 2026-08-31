local A = require("assertions")
local fixtures = require("fixtures.rule_engine")

local assertion_count = 0
local function equal(expected, actual, message)
    assertion_count = assertion_count + 1
    A.equal(expected, actual, message)
end

local function truthy(value, message)
    assertion_count = assertion_count + 1
    A.truthy(value, message)
end

local function array_equal(expected, actual, message)
    assertion_count = assertion_count + 1
    A.type("table", actual, message)
    A.equal(#expected, #actual, (message or "array differs") .. " length")
    for index, value in ipairs(expected) do
        A.equal(value, actual[index], (message or "array differs") .. " at " .. index)
    end
end

local function new_engine(overrides)
    local RuleEngine = require("legado.lib.rule_engine")
    local Json = require("legado.lib.json_codec")
    local HtmlParser = require("legado.vendor.htmlparser")
    local SafeFunctions = require("legado.lib.safe_functions")
    local options = {
        json_decoder = Json.decode,
        html_parser = HtmlParser,
        url_resolver = SafeFunctions.resolve_url,
        safe_functions = SafeFunctions.functions,
    }
    for key, value in pairs(overrides or {}) do options[key] = value end
    return RuleEngine.new(options)
end

local function parse_ok(engine, input, rule, context, want_list)
    local value, err = engine:parse(input, rule, context or {}, want_list)
    equal(nil, err, "expected successful parse for " .. rule)
    return value
end

local function parse_error(engine, input, rule, context, want_list, code)
    local value, err = engine:parse(input, rule, context or {}, want_list)
    equal(nil, value, "error parse must not return a value")
    truthy(type(err) == "table", "error parse returns an AppError")
    equal(code, err.code, "unexpected error code")
    return err
end

local cases = {}
local function case(name, body) cases[#cases + 1] = { name = name, body = body } end

case("css selectors, positional filters, and extraction", function()
    local engine = new_engine()
    local context = { baseUrl = fixtures.base_url }
    equal("https://example.test/book/1", parse_ok(engine, fixtures.html,
        "section#books.panel[data-role][data-role^='main'][data-role$='area'][data-role*='in-a'][class~='featured'] > a.book:eq(0)@href",
        context, false))
    array_equal({ "Beta" }, parse_ok(engine, fixtures.html, "#books .book:gt(0) .title@text", context, true))
    array_equal({ "Alpha" }, parse_ok(engine, fixtures.html, "#books .book:lt(1) .title @text", context, true))
    equal("AlphaNew", parse_ok(engine, fixtures.html, "a.book:first@text", context, false))
    equal("Beta", parse_ok(engine, fixtures.html, "a.book:last@text", context, false))
    equal("B", parse_ok(engine, fixtures.html, "li:not(.missing):nth-child(2)@text", context, false))
    equal("Two", parse_ok(engine, fixtures.html, ".twins span:nth-of-type(2)@text", context, false))
    equal("AlphaNew", parse_ok(engine, fixtures.html, "a:contains('Alpha')@text", context, false))
    equal("Hello Tail", parse_ok(engine, fixtures.html, "p:containsOwn('Hello')@ownText", context, false))
    equal("AlphaNew", parse_ok(engine, fixtures.html, "a:has(span.title)@text", context, false))
    array_equal({ "Hello", "Tail" }, parse_ok(engine, fixtures.html, "p.note@textNodes", context, true))
    equal("<span class=\"title\">Alpha</span><em>New</em>", parse_ok(engine, fixtures.html, "a.primary@html", context, false))
    equal("https://example.test/images/cover.jpg", parse_ok(engine, fixtures.html, "img#cover@src", context, false))
    equal("Synthetic summary", parse_ok(engine, fixtures.html, "meta#summary@content", context, false))
    equal("cover-token", parse_ok(engine, fixtures.html, "img#cover@data-token", context, false))
    array_equal({}, parse_ok(engine, fixtures.html, ".does-not-exist@text", context, true))
    equal(nil, parse_ok(engine, fixtures.html, ".does-not-exist@text", context, false))
end)

case("jsonpath properties, indexes, wildcards, filters, and copies", function()
    local engine = new_engine()
    equal("A", parse_ok(engine, fixtures.json, "@json:$.store.books[0].title", {}, false))
    array_equal({ "A", "B" }, parse_ok(engine, fixtures.json, "$.store.books[*].title", {}, true))
    equal("quoted", parse_ok(engine, fixtures.json, "$['store']['odd.key'].value", {}, false))
    array_equal({ "B" }, parse_ok(engine, fixtures.json, "$.store.books[?(@.price != 5)].title", {}, true))
    array_equal({ "A" }, parse_ok(engine, fixtures.json, "$.store.books[?(@.active == true)].title", {}, true))
    equal(false, parse_ok(engine, fixtures.json, "$.store.books[1].active", {}, false))
    array_equal({ "B" }, parse_ok(engine, fixtures.json, "$.store.books[?(@.title == 'B')].title", {}, true))
    equal("kept", parse_ok(engine, fixtures.json, "@json:$['a||b']", {}, false))
    equal("escaped", parse_ok(engine, fixtures.json, "@json:$['quote\\'key']", {}, false))
    equal("x&&y", parse_ok(engine, fixtures.json, "@json:$.joined", {}, false))
    array_equal({}, parse_ok(engine, fixtures.json, "$.missing[*]", {}, true))

    local input = { store = { books = { { title = "Caller owned" } } } }
    local values = parse_ok(engine, input, "$.store.books[*]", {}, true)
    values[1].title = "mutated return"
    equal("Caller owned", input.store.books[1].title, "returned tables must not alias caller data")
end)

case("xpath axes, values, and approved predicates", function()
    local engine = new_engine()
    equal("Beta", parse_ok(engine, fixtures.html, "@xpath://section[@id='books']/a[2]/span/text()", {}, false))
    equal("book/2", parse_ok(engine, fixtures.html, "/html/body/section/a[last()]/@href", {}, false))
    equal("/book/1", parse_ok(engine, fixtures.html, ".//a[contains(@class,'primary')][contains(text(),'Alpha')]/@href", {}, false))
    array_equal({ "Alpha", "Beta" }, parse_ok(engine, fixtures.html, "//section/*/span/text()", {}, true))
    local current = require("legado.vendor.htmlparser").parse(fixtures.html):select("section")[1]
    equal("AlphaNew Beta", parse_ok(engine, fixtures.html, "@xpath:.", { current = current }, false))
    equal("Alpha", parse_ok(engine, fixtures.html, "@xpath:./a[1]/span/text()", { current = current }, false))
end)

case("composition, escaping, cleanup, and scalar/list contracts", function()
    local engine = new_engine()
    equal("Beta", parse_ok(engine, fixtures.html, ".missing@text || .secondary .title@text", {}, false))
    equal("AlphaBeta", parse_ok(engine, fixtures.html, ".primary .title@text && .secondary .title@text", {}, false))
    array_equal({ "Alpha", "Beta" }, parse_ok(engine, fixtures.html,
        ".primary .title@text && .secondary .title@text", {}, true))
    equal("AlphA", parse_ok(engine, fixtures.html, ".primary .title@text##a##A", {}, false))
    equal("lph", parse_ok(engine, fixtures.html, ".primary .title@text##[Aa]", {}, false))
    equal("x&&y", parse_ok(engine, fixtures.json, "@json:$[\"joined\"]", {}, false))
    equal("Alpha", parse_ok(engine, fixtures.html, "a:contains('A||lpha')@text || .primary .title@text", {}, false))
end)

case("templates and whitelisted safe functions", function()
    local engine = new_engine()
    local context = { key = "A b", page = 3, result = " Value ", baseUrl = fixtures.base_url }
    equal("A b-3- Value ", parse_ok(engine, fixtures.html, "{{key}}-{{page}}-{{result}}", context, false))
    equal("A B", parse_ok(engine, fixtures.html, "{{upper(key)}}", context, false))
    equal("Value", parse_ok(engine, fixtures.html, "{{trim(result)}}", context, false))
    equal("A%20b", parse_ok(engine, fixtures.html, "{{urlEncode(key)}}", context, false))
    equal("A b", parse_ok(engine, fixtures.html, "{{urlDecode('A%20b')}}", context, false))
    equal("<b>&", parse_ok(engine, fixtures.html, "{{htmlDecode('&lt;b&gt;&amp;')}}", context, false))
    equal("QSBi", parse_ok(engine, fixtures.html, "{{base64Encode(key)}}", context, false))
    equal("A b", parse_ok(engine, fixtures.html, "{{base64Decode('QSBi')}}", context, false))
    equal("bc79052a3f1515cb9df3d2092d031fe0", parse_ok(engine, fixtures.html, "{{md5(key)}}", context, false))
    equal("b2bcc38cd866b4113329cffbaea5be46ff2b452e", parse_ok(engine, fixtures.html, "{{sha1(key)}}", context, false))
    equal("b2bcc38cd866b4113329cffbaea5be46ff2b452e", parse_ok(engine, fixtures.html, "{{sha(key)}}", context, false))
    equal("a760b0e1e5180903bce545f6444f0b986012105a194d02b2f909452d6b287dff", parse_ok(engine, fixtures.html, "{{sha256(key)}}", context, false))
    equal("a b", parse_ok(engine, fixtures.html, "{{lower(key)}}", context, false))
    equal("A_b", parse_ok(engine, fixtures.html, "{{replace(key,' ','_')}}", context, false))
    equal("a-b", parse_ok(engine, fixtures.html, "{{replace('a||b','||','-')}}", context, false))
    equal("VALUE", parse_ok(engine, fixtures.html, "{{upper({{trim(result)}})}}", context, false))
    equal("Alpha", parse_ok(engine, fixtures.html, "{{.primary .title@text}}", context, false))
    equal("https://example.test/next", parse_ok(engine, fixtures.html, "{{resolveUrl('/next')}}", context, false))
    parse_error(engine, fixtures.html, "{{openFile(key)}}", context, false, "UNSUPPORTED_RULE")
end)

case("unsafe constructs are rejected before input parsing", function()
    local parser_calls, decoder_calls = 0, 0
    local engine = new_engine({
        html_parser = { parse = function() parser_calls = parser_calls + 1 return {} end },
        json_decoder = function() decoder_calls = decoder_calls + 1 return {} end,
    })
    local unsafe = {
        "@js:result", "<js>alert(1)</js>", "eval(result)", "java.lang.String",
        "android.content.Context", "Packages.foo", "WebView.loadUrl", "function(x) return x end",
        "(x) => { return x }",
    }
    for _, rule in ipairs(unsafe) do
        parse_error(engine, "not parsed", rule, {}, false, "UNSUPPORTED_RULE")
    end
    equal(0, parser_calls, "unsafe HTML rules must be rejected before parsing")
    equal(0, decoder_calls, "unsafe JSON rules must be rejected before parsing")
    local report = require("legado.lib.compatibility_scanner").scan({
        searchUrl = "https://example.test/search", ruleSearch = "(x) => { return x }",
        ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
    })
    equal("unsupported", report.status, "scanner shares executable-rule capabilities")
    equal("FUNCTION_BODY", report.issues[1].code, "scanner and engine share the function-body rejection")
end)

case("malformed inputs and bounded resources return structured errors", function()
    local engine = new_engine()
    parse_error(engine, "<div><span></div>", "span@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "{broken", "$.value", {}, false, "PARSE_ERROR")
    parse_error(engine, fixtures.html, "div[", {}, false, "PARSE_ERROR")
    local incomplete_injection = new_engine({ safe_functions = {} })
    parse_error(incomplete_injection, fixtures.html, "p.note@text", {}, false, "PARSE_ERROR")

    local Capabilities = require("legado.lib.rule_capabilities")
    local deep = {}
    for _ = 1, Capabilities.LIMITS.MAX_DOM_DEPTH + 1 do deep[#deep + 1] = "<div>" end
    deep[#deep + 1] = "x"
    for _ = 1, Capabilities.LIMITS.MAX_DOM_DEPTH + 1 do deep[#deep + 1] = "</div>" end
    local depth_error = parse_error(engine, table.concat(deep), "div@text", {}, false, "PARSE_ERROR")
    equal("dom_depth", depth_error.details and depth_error.details.limit, "DOM depth limit is identified")

    local many = {}
    for index = 1, Capabilities.LIMITS.MAX_OUTPUT_ITEMS + 1 do
        many[#many + 1] = "<i>" .. index .. "</i>"
    end
    local output_error = parse_error(engine, table.concat(many), "i@text", {}, true, "PARSE_ERROR")
    equal("output_items", output_error.details and output_error.details.limit, "output limit is identified")

    local nested = "key"
    for _ = 1, Capabilities.LIMITS.MAX_TEMPLATE_DEPTH + 1 do nested = "upper({{" .. nested .. "}})" end
    local template_error = parse_error(engine, fixtures.html, "{{" .. nested .. "}}", { key = "x" }, false, "PARSE_ERROR")
    equal("template_depth", template_error.details and template_error.details.limit, "template limit is identified")
end)

case("caller context and repeated results remain unmodified", function()
    local engine = new_engine()
    local context = { key = "original", page = 1, result = { nested = "caller" }, baseUrl = fixtures.base_url }
    local copy = { key = context.key, page = context.page, result = context.result, baseUrl = context.baseUrl }
    local first = parse_ok(engine, fixtures.html, ".title@text", context, true)
    first[1] = "changed"
    local second = parse_ok(engine, fixtures.html, ".title@text", context, true)
    array_equal({ "Alpha", "Beta" }, second)
    equal(copy.key, context.key)
    equal(copy.page, context.page)
    equal(copy.result, context.result)
    equal(copy.baseUrl, context.baseUrl)
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
