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

case("block comments use JavaScript and Java non-nesting boundaries", function()
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
    local executable = {
        "/*/*/eval(x)",
        "/* /* */ java.lang.String",
        "/*/*/function(a){}",
        "/* outer /* inner */ local function f() end",
        "/*/*/\\u0065val(x)",
        "/* /* */ A N D R O I D .content.Context",
        "function--line comment\n(a){}",
        "new Function('return 1')",
        "\\u{65}val(x)",
    }
    for _, rule in ipairs(executable) do
        parse_error(engine, Fixtures.html, rule, {}, false, "UNSUPPORTED_RULE")
        local report = CompatibilityScanner.scan({
            searchUrl = "https://example.test/search", ruleSearch = rule,
            ruleBookInfo = ".book", ruleToc = ".chapter", ruleContent = ".content",
        })
        equal("unsupported", report.status, "scanner must share non-nesting unsafe detection")
    end
    parse_error(engine, Fixtures.json, "@json:$.items || /*/*/eval(x)", {}, false,
        "UNSUPPORTED_RULE")
    equal(0, parser_calls, "unsafe rules are rejected before HTML parsing")
    equal(0, decoder_calls, "unsafe rules are rejected before JSON decoding")

    local literal_html = [[<div>/*/*/eval(x)</div>]]
    equal("/*/*/eval(x)", parse_ok(new_engine(), literal_html,
        [[div:contains('/*/*/eval(x)')@text]], {}, false))
    equal("/*/*/safe(x)", parse_ok(new_engine(), literal_html,
        [[{{replace('/*/*/eval(x)','eval','safe')}}]], {}, false))
end)

case("hierarchical bases resolve relatives with empty authority or one slash", function()
    local engine = new_engine()
    local function resolved(base, relative)
        return parse_ok(engine, Fixtures.html,
            "{{resolveUrl('" .. relative .. "')}}", { baseUrl = base }, false)
    end

    equal("file:///a/d", resolved("file:///a/b/c", "../d"))
    equal("http:/a/d", resolved("http:/a/b/c", "../d"))
    equal("file:///a//d", resolved("file:///a//b/c", "../d"))
    equal("file:///d", resolved("file:///a/b/c", "/d"))
    equal("http:/d", resolved("http:/a/b/c", "/d"))
    equal("file:///a/b/c?q=1", resolved("file:///a/b/c?old=1", "?q=1"))
    equal("http:/a/b/c?old=1#f", resolved("http:/a/b/c?old=1", "#f"))
    equal("file:///a/b/c?old=1", resolved("file:///a/b/c?old=1#old", ""))
    equal("http://cdn.example/y", resolved("http:/a/b/c", "//cdn.example/x/../y"))
    equal("../d", resolved("mailto:user@example.test", "../d"))
    equal("https://e/a//b/c", resolved("https://e/a//b/", "c"))
end)

case("numeric pseudo template slots are case-insensitive outside literals", function()
    local engine = new_engine()
    local html = [[<ul><li>A</li><li>B</li><li>C</li></ul>]]
        .. [[<div data-x=":NTH-CHILD(2)">:EQ(1)</div>]]
    equal("B", parse_ok(engine, html, "li:EQ({{page}})@text", { page = 1 }, false))
    equal("B", parse_ok(engine, html,
        "li:NTH-CHILD({{page}})@text", { page = 2 }, false))
    array_equal({ "B", "C" }, parse_ok(engine, html,
        "li:Gt({{page}})@text", { page = 0 }, true))
    equal("B", parse_ok(engine, html,
        "li:nth-OF-type({{page}})@text", { page = 2 }, false))

    equal("div:contains(':EQ(1)')@text", parse_ok(engine, html,
        "div:contains(':EQ({{page}})')@text", { page = 1 }, false))
    equal([[div[data-x=":NTH-CHILD(2)"]@text]], parse_ok(engine, html,
        [[div[data-x=":NTH-CHILD({{page}})"]@text]], { page = 2 }, false))
    equal("li:not(:EQ(1))@text", parse_ok(engine, html,
        "li:not(:EQ({{page}}))@text", { page = 1 }, false))
    equal("li:EQ(11)@text", parse_ok(engine, html,
        "li:EQ(1{{page}})@text", { page = 1 }, false))
end)

local failures = {}
for _, item in ipairs(cases) do
    local ok, err = pcall(item.body)
    if not ok then failures[#failures + 1] = "[RED] " .. item.name .. ": " .. tostring(err) end
end

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return assertion_count
