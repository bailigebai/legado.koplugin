local A = require("assertions")
local Fixtures = require("fixtures.rule_engine")
local Capabilities = require("legado.lib.rule_capabilities")
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

case("selector recursion and supplied DOMs share bounded validation", function()
    local engine = new_engine()
    local nested_not = ".missing"
    for _ = 1, Capabilities.LIMITS.MAX_RECURSION + 1 do nested_not = ":not(" .. nested_not .. ")" end
    local recursion_error = parse_error(engine, Fixtures.html, "a" .. nested_not .. "@text", {}, false, "PARSE_ERROR")
    equal("recursion", recursion_error.details and recursion_error.details.limit, "nested :not identifies the recursion limit")

    local nested_has = "span"
    for _ = 1, Capabilities.LIMITS.MAX_RECURSION + 1 do nested_has = "div:has(" .. nested_has .. ")" end
    local nested_html = {}
    for _ = 1, Capabilities.LIMITS.MAX_RECURSION + 2 do nested_html[#nested_html + 1] = "<div>" end
    nested_html[#nested_html + 1] = "<span>x</span>"
    for _ = 1, Capabilities.LIMITS.MAX_RECURSION + 2 do nested_html[#nested_html + 1] = "</div>" end
    parse_error(engine, table.concat(nested_html), nested_has .. "@text", {}, false, "PARSE_ERROR")

    local deep_root, cursor = { name = "root", nodes = {} }, nil
    cursor = deep_root
    for _ = 1, Capabilities.LIMITS.MAX_DOM_DEPTH + 1 do
        local child = { name = "div", nodes = {}, attributes = {} }
        cursor.nodes[1], child.parent = child, cursor
        cursor = child
    end
    local depth_error = parse_error(engine, "ignored", "> *@text", { current = deep_root }, true, "PARSE_ERROR")
    equal("dom_depth", depth_error.details and depth_error.details.limit, "supplied DOM depth is bounded")

    local cyclic = { name = "root", nodes = {}, attributes = {} }
    cyclic.nodes[1], cyclic.parent = cyclic, cyclic
    local cycle_error = parse_error(engine, "ignored", "> *@text", { node = cyclic }, true, "PARSE_ERROR")
    equal("dom_cycle", cycle_error.details and cycle_error.details.limit, "supplied DOM cycles are rejected")
end)

case("obfuscated executable tokens are rejected before parsing and by scanner", function()
    local parser_calls, decoder_calls = 0, 0
    local engine = new_engine({
        html_parser = { parse = function(text, limit) parser_calls = parser_calls + 1 return HtmlParser.parse(text, limit) end },
        json_decoder = function(text) decoder_calls = decoder_calls + 1 return Json.decode(text) end,
    })
    local rules = {
        "function/*x*/(a){}",
        "function--x\n(a){}",
        "\\u0065val(x)",
        "java/*x*/.lang.String",
        "A N D R O I D . content.Context",
        "Pack/*outer/*inner*/tail*/ages.foo",
        "@ J S : result",
    }
    for _, rule in ipairs(rules) do
        parse_error(engine, Fixtures.html, rule, {}, false, "UNSUPPORTED_RULE")
        local report = require("legado.lib.compatibility_scanner").scan({
            searchUrl = "https://example.test/search", ruleSearch = rule,
            ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
        })
        equal("unsupported", report.status, "scanner rejects obfuscated executable rule")
    end
    equal(0, parser_calls, "unsafe HTML rules are rejected before parser injection")
    equal(0, decoder_calls, "unsafe JSON rules are rejected before decoder injection")
end)

case("relative URL resolution handles authority roots and reference forms", function()
    local engine = new_engine()
    local root = { baseUrl = "https://example.test" }
    equal("https://example.test/next", parse_ok(engine, Fixtures.html, "{{resolveUrl('next')}}", root, false))
    equal("https://example.test/dir/", parse_ok(engine, Fixtures.html, "{{resolveUrl('/dir/')}}", root, false))
    equal("https://example.test/?q=1", parse_ok(engine, Fixtures.html, "{{resolveUrl('?q=1')}}", root, false))
    equal("https://example.test/#frag", parse_ok(engine, Fixtures.html, "{{resolveUrl('#frag')}}", root, false))
    equal("https://cdn.example/x", parse_ok(engine, Fixtures.html, "{{resolveUrl('//cdn.example/x')}}", root, false))
    equal("https://example.test/a/next", parse_ok(engine, Fixtures.html, "{{resolveUrl('../next')}}",
        { baseUrl = "https://example.test/a/b/" }, false))
end)

case("DOM text extraction follows text-node order and XPath directness", function()
    local engine = new_engine()
    local html = [[<div id="mixed">A<span title="2 > 1">B</span>C&amp;D</div>]]
    equal("ABC&D", parse_ok(engine, html, "#mixed@text", {}, false))
    array_equal({ "A", "C&D" }, parse_ok(engine, html, "@xpath://div/text()", {}, true))
    array_equal({}, parse_ok(engine, html, "@xpath://div[contains(text(),'B')]/@id", {}, true))
    equal("mixed", parse_ok(engine, html, "@xpath://div[contains(text(),'C&D')]/@id", {}, false))
end)

case("mixed templates explicitly evaluate dynamic selectors and every extractor", function()
    local engine = new_engine()
    equal("https://example.test/images/cover.jpg", parse_ok(engine, Fixtures.html, "img#{{key}}@src",
        { key = "cover", baseUrl = Fixtures.base_url }, false))
    equal("Synthetic summary", parse_ok(engine, Fixtures.html, "meta#{{key}}@content", { key = "summary" }, false))
    equal("cover-token", parse_ok(engine, Fixtures.html, "img#cover@{{key}}", { key = "data-token" }, false))
    equal("Alpha", parse_ok(engine, Fixtures.html, "{{key}}@text", { key = ".primary .title" }, false))
end)

case("template delimiter matching ignores quoted escaped closing braces", function()
    local engine = new_engine()
    equal("a-b", parse_ok(engine, Fixtures.html, "{{replace('a}}b','}}','-')}}", {}, false))
end)

case("Base64 padding is canonical and invalid Unicode entities are preserved", function()
    local engine = new_engine()
    equal("A", parse_ok(engine, Fixtures.html, "{{base64Decode('QQ==')}}", {}, false))
    parse_error(engine, Fixtures.html, "{{base64Decode('QR==')}}", {}, false, "PARSE_ERROR")
    parse_error(engine, Fixtures.html, "{{base64Decode('QUJ=')}}", {}, false, "PARSE_ERROR")
    parse_error(engine, Fixtures.html, "{{base64Decode('QQ=')}}", {}, false, "PARSE_ERROR")
    equal("&#x110000;", parse_ok(engine, Fixtures.html, "{{htmlDecode('&#x110000;')}}", {}, false))
    equal("&#xD800;", parse_ok(engine, Fixtures.html, "{{htmlDecode('&#xD800;')}}", {}, false))
end)

case("template interpolation preserves false and only empties nil", function()
    local engine = new_engine()
    equal("false", parse_ok(engine, Fixtures.html, "{{result}}", { result = false }, false))
    equal("", parse_ok(engine, Fixtures.html, "{{result}}", {}, false))
end)

case("CSS pseudo arity and positive child positions are validated", function()
    local engine = new_engine()
    local invalid = {
        "a:first(1)@text", "a:last()@text", "a:not()@text", "a:contains()@text",
        "a:containsOwn('')@text", "a:has(  )@text", "li:nth-child(0)@text",
        "li:nth-child(-1)@text", "span:nth-of-type(0)@text",
    }
    for _, rule in ipairs(invalid) do parse_error(engine, Fixtures.html, rule, {}, false, "PARSE_ERROR") end
    equal("AlphaNew", parse_ok(engine, Fixtures.html, "a:first@text", {}, false))
    equal("C", parse_ok(engine, Fixtures.html, "li:nth-child(3)@text", {}, false))
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
