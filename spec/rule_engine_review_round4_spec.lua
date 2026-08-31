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

case("unsafe scanning establishes original quote boundaries before Unicode decoding", function()
    local engine = new_engine()
    local html = [[<div data-x="\u0022eval(">\u0027function</div>]]
    equal("\\u0027function", parse_ok(engine, html,
        [[div:contains('\u0027function')@text]], {}, false))
    equal("\\u0027function", parse_ok(engine, html,
        [[div[data-x="\u0022eval("]@text]], {}, false))
    equal("\\u0027function", parse_ok(engine, html,
        [[{{replace('\u0027function','x','y')}}]], {}, false))

    local report = CompatibilityScanner.scan({
        searchUrl = "https://example.test/search",
        ruleSearch = [[div:contains('\u0027function')@text]],
        ruleBookInfo = [[div[data-x="\u0022eval("]@text]],
        ruleToc = ".chapter", ruleContent = ".content",
    })
    equal("usable", report.status, "Unicode-looking quoted literals remain usable")

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
        "\\u0065val(x)",
        "\\u{65}val(x)",
        "local \\u0066unction f() end",
        "new \\u{46}unction('return 1')",
        "async function f() {}",
        "function* values() {}",
        "return java/*x*/.lang.String",
        "function--comment\n(a){}",
    }
    for _, rule in ipairs(executable) do
        parse_error(guarded, Fixtures.html, rule, {}, false, "UNSUPPORTED_RULE")
        local unsafe_report = CompatibilityScanner.scan({
            searchUrl = "https://example.test/search", ruleSearch = rule,
            ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
        })
        equal("unsupported", unsafe_report.status, "outside-string executable escape remains blocked")
    end
    parse_error(guarded, Fixtures.json, "@json:$.items || \\u0065val(x)", {}, false, "UNSUPPORTED_RULE")
    equal(0, parser_calls, "unsafe rules are rejected before HTML parsing")
    equal(0, decoder_calls, "unsafe rules are rejected before JSON decoding")
end)

case("absolute hierarchical URLs include empty-authority and path-only scheme forms", function()
    local engine = new_engine()
    local context = { baseUrl = "https://base.example/a/b" }
    equal("file:///b", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('file:///a/../b')}}", context, false))
    equal("http:/b", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('http:/a/../b')}}", context, false))
    equal("file:///a//c?x=1#f", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('file:///a//b/../c?x=1#f')}}", context, false))
    equal("mailto:user@example.test", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('mailto:user@example.test')}}", context, false))
    equal("data:text/plain,a/../b", parse_ok(engine, Fixtures.html,
        "{{resolveUrl('data:text/plain,a/../b')}}", context, false))
end)

case("raw-text masking prevents phantom DOM nodes while preserving raw text", function()
    local engine = new_engine()
    local styled = [[<style>.x{content:"<div>fake</div>"}</style><div>ok</div>]]
    array_equal({ "ok" }, parse_ok(engine, styled, "div@text", {}, true))
    equal([[.x{content:"<div>fake</div>"}]], parse_ok(engine, styled, "style@text", {}, false))
    equal([[.x{content:"<div>fake</div>"}]], parse_ok(engine, styled, "style@html", {}, false))

    local scripted = [[<script>var x="<span>fake</span>";</SCRIPT><span>ok</span>]]
    array_equal({ "ok" }, parse_ok(engine, scripted, "span@text", {}, true))
    equal([[var x="<span>fake</span>";]], parse_ok(engine, scripted, "script@text", {}, false))

    local commented = [[<!--lead--><style>.x{content:"<div>fake</div>"}</style><div>ok</div>]]
    array_equal({ "ok" }, parse_ok(engine, commented, "div@text", {}, true))
    equal([[.x{content:"<div>fake</div>"}]], parse_ok(engine, commented, "style@text", {}, false))

    parse_error(engine, "<style>.x{color:red}", "div@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "<script>x</style>", "div@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "<div><span>x</div></span>", "div@text", {}, false, "PARSE_ERROR")
end)

case("numeric pseudo template substitution ignores quoted and partial marker text", function()
    local engine = new_engine()
    local html = [[<ul><li>A</li><li>B</li></ul><div data-x=":nth-child(2)">:eq(2)</div>]]
    equal("B", parse_ok(engine, html, "li:eq({{page}})@text", { page = 1 }, false))
    equal("B", parse_ok(engine, html, "li:nth-child({{page}})@text", { page = 2 }, false))
    equal("div:contains(':eq(2)')@text", parse_ok(engine, html,
        "div:contains(':eq({{page}})')@text", { page = 2 }, false))
    equal("div[data-x=':nth-child(2)']@text", parse_ok(engine, html,
        "div[data-x=':nth-child({{page}})']@text", { page = 2 }, false))
    equal("li:eq(11)@text", parse_ok(engine, html,
        "li:eq(1{{page}})@text", { page = 1 }, false))
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
