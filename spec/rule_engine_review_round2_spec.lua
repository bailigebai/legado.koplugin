local A = require("assertions")
local Fixtures = require("fixtures.rule_engine")
local Capabilities = require("legado.lib.rule_capabilities")
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

case("DOM validation rejects external parent sibling scans and bounds positional pools", function()
    local engine = new_engine()
    local root = { name = "root", nodes = {}, attributes = {} }
    local target = { name = "div", nodes = {}, attributes = { id = "target" } }
    root.nodes[1] = target

    local external = { name = "external", nodes = {}, attributes = {} }
    for index = 1, Capabilities.LIMITS.MAX_HTML_NODES do
        external.nodes[index] = { name = index % 2 == 0 and "span" or "div", nodes = {}, attributes = {} }
    end
    external.nodes[Capabilities.LIMITS.MAX_HTML_NODES + 1] = target
    target.parent = external

    local child_error = parse_error(engine, "ignored", "div:nth-child(10001)@id",
        { current = root }, false, "PARSE_ERROR")
    equal("parent_mismatch", child_error.details and child_error.details.limit,
        "nth-child cannot scan siblings outside the validated root")

    local type_error = parse_error(engine, "ignored", "div:nth-of-type(5001)@id",
        { current = root }, false, "PARSE_ERROR")
    equal("parent_mismatch", type_error.details and type_error.details.limit,
        "nth-of-type cannot scan siblings outside the validated root")

    local oversized = { name = "root", nodes = {}, attributes = {} }
    for index = 1, Capabilities.LIMITS.MAX_HTML_NODES + 1 do
        local child = { name = "div", nodes = {}, attributes = { id = tostring(index) }, parent = oversized }
        oversized.nodes[index] = child
    end
    local eq_error = parse_error(engine, "ignored", "div:eq(10000)@id",
        { current = oversized }, false, "PARSE_ERROR")
    equal("html_nodes", eq_error.details and eq_error.details.limit,
        "eq positional pools cannot exceed the DOM node budget")

    local consistent = { name = "root", nodes = {}, attributes = {} }
    for index = 1, 3 do
        local child = { name = index == 2 and "span" or "div", nodes = {}, attributes = { id = tostring(index) }, parent = consistent }
        consistent.nodes[index] = child
    end
    equal("3", parse_ok(engine, "ignored", "div:nth-child(3)@id", { current = consistent }, false))
    equal("3", parse_ok(engine, "ignored", "div:nth-of-type(2)@id", { current = consistent }, false))
    equal("3", parse_ok(engine, "ignored", "div:eq(1)@id", { current = consistent }, false))
end)

case("unsafe keyword normalization preserves boundaries and decodes brace escapes", function()
    local parser_calls, decoder_calls = 0, 0
    local engine = new_engine({
        html_parser = { parse = function(text, limit)
            parser_calls = parser_calls + 1
            return HtmlParser.parse(text, limit)
        end },
        json_decoder = function(text)
            decoder_calls = decoder_calls + 1
            return Json.decode(text)
        end,
    })
    local rules = {
        "local function f() end",
        "async function f() {}",
        "return function() {}",
        "new Function('return 1')",
        "function* values() {}",
        "\\u{65}val(x)",
        "function/*x*/(a){}",
        "function--x\n(a){}",
        "java/*x*/.lang.String",
        "A N D R O I D . content.Context",
        "return java/*x*/.lang.String",
        "return A N D R O I D . content.Context",
        "return Pack/*x*/ages.foo",
    }
    for _, rule in ipairs(rules) do
        parse_error(engine, Fixtures.html, rule, {}, false, "UNSUPPORTED_RULE")
        local report = CompatibilityScanner.scan({
            searchUrl = "https://example.test/search", ruleSearch = rule,
            ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
        })
        equal("unsupported", report.status, "scanner rejects unsafe keyword form")
    end
    parse_error(engine, Fixtures.json, "@json:$.items || \\u{65}val(x)", {}, false, "UNSUPPORTED_RULE")
    equal(0, parser_calls, "unsafe rules are rejected before HTML parsing")
    equal(0, decoder_calls, "unsafe rules are rejected before JSON decoding")
end)

case("URL resolution preserves empty segments and normalizes network paths", function()
    local engine = new_engine()
    equal("https://e/a//b/c", parse_ok(engine, Fixtures.html, "{{resolveUrl('c')}}",
        { baseUrl = "https://e/a//b/" }, false))
    equal("https://cdn/y", parse_ok(engine, Fixtures.html, "{{resolveUrl('//cdn/x/../y')}}",
        { baseUrl = "https://e/a/b" }, false))
    equal("https://e/a//", parse_ok(engine, Fixtures.html, "{{resolveUrl('../')}}",
        { baseUrl = "https://e/a//b/" }, false))
end)

case("markup validation scans quoted tag tails without mistaking slash greater-than", function()
    local engine = new_engine()
    equal("ok", parse_ok(engine, "<div title='x/> y'>ok</div>", "div@text", {}, false))
    equal("ok", parse_ok(engine, '<div title="2 > 1">ok</div>', "div@text", {}, false))
    parse_error(engine, "<div><span>x</div></span>", "div@text", {}, false, "PARSE_ERROR")
    parse_error(engine, "<div><span>x</span>", "div@text", {}, false, "PARSE_ERROR")
end)

case("post-expansion CSS grammar recognizes dynamic selector slots", function()
    local engine = new_engine()
    local html = [[<main><div id="target" class="box" data-kind="cover"><span id="child">Nested</span></div></main>]]
    equal("Nested", parse_ok(engine, html, "div {{key}}", { key = "span" }, false))
    equal("Nested", parse_ok(engine, html, "{{key}}#target@text", { key = "div" }, false))
    equal("Nested", parse_ok(engine, html, "div#{{key}}@text", { key = "target" }, false))
    equal("Nested", parse_ok(engine, html, ".{{key}}@text", { key = "box" }, false))
    equal("Nested", parse_ok(engine, html, "[data-kind='{{key}}']@text", { key = "cover" }, false))
    equal("Nested", parse_ok(engine, html, "main > {{key}}@text", { key = "div" }, false))
    equal("Nested", parse_ok(engine, html, "main {{key}} div@text", { key = ">" }, false))
    equal("cover", parse_ok(engine, html, "#target@{{key}}", { key = "data-kind" }, false))
    equal("A b-3-Value", parse_ok(engine, html, "{{key}}-{{page}}-{{result}}",
        { key = "A b", page = 3, result = "Value" }, false))
end)

case("strict Base64 rejects whitespace instead of silently normalizing it", function()
    local engine = new_engine()
    equal("A", parse_ok(engine, Fixtures.html, "{{base64Decode('QQ==')}}", {}, false))
    parse_error(engine, Fixtures.html, "{{base64Decode('Q Q = =')}}", {}, false, "PARSE_ERROR")
    parse_error(engine, Fixtures.html, "{{base64Decode('QQ==\\n')}}", {}, false, "PARSE_ERROR")
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
