local A = require("assertions")
local Fixtures = require("fixtures.rule_engine")
local CompatibilityScanner = require("legado.lib.compatibility_scanner")
local RuleEngine = require("legado.lib.rule_engine")
local Json = require("legado.lib.json_codec")
local HtmlParser = require("legado.vendor.htmlparser")
local SafeFunctions = require("legado.lib.safe_functions")

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

local function parse_error(engine, input, rule, context, want_list, expected_code)
    local value, err = engine:parse(input, rule, context or {}, want_list)
    equal(nil, value, "error parse must not return a value")
    truthy(type(err) == "table", "error parse returns an AppError")
    equal(expected_code, err.code, "unexpected error code for " .. rule)
    return err
end

local cases = {}
local function case(name, body) cases[#cases + 1] = { name = name, body = body } end

case("unsafe scanning ignores quoted literal data but blocks executable tokens outside strings", function()
    local html = [[<div data-api="java.lang" data-code="eval(">function safe</div>]]
    local engine = new_engine()
    equal("function safe", parse_ok(engine, html, "div:contains('function')@text", {}, false))
    equal("function safe", parse_ok(engine, html,
        "div[data-api='java.lang'][data-code='eval(']@text", {}, false))
    equal("safe", parse_ok(engine, html,
        "{{replace('function','function','safe')}}", {}, false))

    local supported = CompatibilityScanner.scan({
        searchUrl = "https://example.test/search", ruleSearch = "div:contains('function')@text",
        ruleBookInfo = "div[data-api='java.lang']@text", ruleToc = ".chapter", ruleContent = ".content",
    })
    equal("usable", supported.status, "quoted literal data remains scanner-compatible")

    local parser_calls, decoder_calls = 0, 0
    local guarded = new_engine({
        html_parser = { parse = function(text, limit)
            parser_calls = parser_calls + 1
            return HtmlParser.parse(text, limit)
        end },
        json_decoder = function(text)
            decoder_calls = decoder_calls + 1
            return Json.decode(text)
        end,
    })
    local executable = {
        "local function f() end",
        "async function f() {}",
        "new Function('return 1')",
        "function* values() {}",
        "\\u{65}val(x)",
        "return java/*x*/.lang.String",
        "function--comment\n(a){}",
    }
    for _, rule in ipairs(executable) do
        parse_error(guarded, Fixtures.html, rule, {}, false, "UNSUPPORTED_RULE")
        local report = CompatibilityScanner.scan({
            searchUrl = "https://example.test/search", ruleSearch = rule,
            ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
        })
        equal("unsupported", report.status, "executable token remains scanner-blocked")
    end
    parse_error(guarded, Fixtures.json, "@json:$.items || \\u0065val(x)", {}, false, "UNSUPPORTED_RULE")
    equal(0, parser_calls, "unsafe rules are rejected before HTML parsing")
    equal(0, decoder_calls, "unsafe rules are rejected before JSON decoding")
end)

case("absolute hierarchical URLs normalize dot segments without changing opaque schemes", function()
    local engine = new_engine()
    local context = { baseUrl = "https://base.example/a/b" }
    equal("https://cdn/y", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('https://cdn/x/../y')}}", context, false))
    equal("https://cdn/a//c?x=1#frag", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('https://cdn/a//b/../c?x=1#frag')}}", context, false))
    equal("mailto:user@example.test", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('mailto:user@example.test')}}", context, false))
    equal("data:text/plain,a/../b", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('data:text/plain,a/../b')}}", context, false))
end)

case("markup validation uses HTML quote rules and skips raw-text element contents", function()
    local engine = new_engine()
    equal("ok", parse_ok(engine, [[<div title="x\">ok</div>]], "div@text", {}, false))
    equal("ok", parse_ok(engine,
        [[<script>var s="</div>";</script><div>ok</div>]], "div@text", {}, false))
    equal("ok", parse_ok(engine,
        [[<style>.x:before{content:"</div>"}</style><div>ok</div>]], "div@text", {}, false))
    parse_error(engine, "<div><span>x</div></span>", "div@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "<div><span>x</span>", "div@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "<script>var x = 1", "div@text", {}, false, "PARSE_ERROR")
end)

case("templated CSS pseudos accept complete dynamic argument slots only", function()
    local engine = new_engine()
    local html = [[<ul><li>A</li><li class="skip"><span>B</span></li><li>C</li></ul>]]
    equal("B", parse_ok(engine, html, "li:nth-child({{page}})@text", { page = 2 }, false))
    equal("B", parse_ok(engine, html, "li:nth-of-type({{page}})@text", { page = 2 }, false))
    equal("B", parse_ok(engine, html, "li:eq({{page}})@text", { page = 1 }, false))
    array_equal({ "B", "C" }, parse_ok(engine, html, "li:gt({{page}})@text", { page = 0 }, true))
    equal("B", parse_ok(engine, html, "li:contains({{key}})@text", { key = "B" }, false))
    equal("B", parse_ok(engine, html, "li:has({{key}})@text", { key = "span" }, false))
    equal("C", parse_ok(engine, html, "li:not({{key}}):last@text", { key = ".skip" }, false))
    equal("li:nth-child(12)@text", parse_ok(engine, html,
        "li:nth-child(1{{page}})@text", { page = 2 }, false))
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
