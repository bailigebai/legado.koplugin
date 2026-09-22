local A = require("assertions")
local CompatibilityScanner = require("legado.lib.compatibility_scanner")
local HtmlParser = require("legado.vendor.htmlparser")
local Json = require("legado.lib.json_codec")
local RuleEngine = require("legado.lib.rule_engine")
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
    equal("table", type(actual), message)
    equal(#expected, #actual, (message or "array differs") .. " length")
    for index, value in ipairs(expected) do
        equal(value, actual[index], (message or "array differs") .. " at " .. index)
    end
end

local function new_engine()
    return RuleEngine.new({
        json_decoder = Json.decode,
        html_parser = HtmlParser,
        url_resolver = SafeFunctions.resolve_url,
        safe_functions = SafeFunctions.functions,
    })
end

local function parse_ok(engine, input, rule, context, want_list)
    local value, err = engine:parse(input, rule, context or {}, want_list == true)
    equal(nil, err, "parse succeeds: " .. rule)
    return value
end

local function elements_ok(engine, input, rule, context)
    local value, err = engine:parseElements(input, rule, context or {})
    equal(nil, err, "element parse succeeds: " .. rule)
    return value
end

local html = [[<main>]]
    .. [[<div class="group" id="g1"><a class="book" href="/a1"><span>A1</span></a><a class="book" href="/a2">A2</a></div>]]
    .. [[<div class="group" id="g2"><a class="book" href="/b1"><span>B1</span></a><a class="book" href="/b2">B2</a></div>]]
    .. [[<article class="content"><p>One</p><p>Two</p></article>]]
    .. [[</main>]]

local engine = new_engine()

local css = elements_ok(engine, html, ".book")
array_equal({
    [[<a class="book" href="/a1"><span>A1</span></a>]],
    [[<a class="book" href="/a2">A2</a>]],
    [[<a class="book" href="/b1"><span>B1</span></a>]],
    [[<a class="book" href="/b2">B2</a>]],
}, css, "CSS lists preserve outer HTML")

local prefixed_css = elements_ok(engine, html, "@CSS:.group > a.book")
equal(4, #prefixed_css, "@CSS prefix selects the same element list")
equal(css[1], prefixed_css[1], "@CSS preserves the selected element")

local xpath = elements_ok(engine, html, "@xpath://div[@id='g2']/a")
array_equal({
    [[<a class="book" href="/b1"><span>B1</span></a>]],
    [[<a class="book" href="/b2">B2</a>]],
}, xpath, "XPath lists preserve outer HTML")
equal(xpath[1], elements_ok(engine, html, "@XPath://div[@id='g2']/a")[1],
    "canonical Legado XPath prefix is case-insensitive")

local json_input = [[{"items":[{"name":"A"},{"name":"B"}]}]]
local objects = elements_ok(engine, json_input, "@json:$.items[*]")
equal(2, #objects, "JSONPath returns every selected object")
equal("A", objects[1].name, "JSONPath preserves object shape")
objects[1].name = "changed"
equal("A", elements_ok(engine, json_input, "$.items[*]")[1].name,
    "JSONPath element results do not alias decoded input")
equal("B", elements_ok(engine, json_input, "@Json:$.items[*]")[2].name,
    "canonical Legado JSONPath prefix is case-insensitive")

local cleaned_members = elements_ok(engine,
    [=[{"books":["<a href=\"/one\">xxTitle</a>"]}]=], "$.books[*]##xx##")
array_equal({ [[<a href="/one">Title</a>]] }, cleaned_members,
    "element-list cleanup keeps serialized members parseable")
equal("Title", parse_ok(engine, cleaned_members[1], "text"),
    "text extraction works after element-list cleanup")
equal("/one", parse_ok(engine, cleaned_members[1], "@href"),
    "current-root attributes work after element-list cleanup")
array_equal({ [[<a class="entry" href="/a1"><span>A1</span></a>]] },
    elements_ok(engine, html, ".book:first##book##entry"),
    "CSS cleanup retains the selected element's outer markup")

local first_per_group = elements_ok(engine, html, "class.group@tag.a.0")
array_equal({ css[1], css[3] }, first_per_group,
    "default indexes apply separately inside each selected parent")
local last_per_group = elements_ok(engine, html, "class.group@tag.a.-1")
array_equal({ css[2], css[4] }, last_per_group,
    "negative default indexes apply separately inside each selected parent")
array_equal({ css[1], css[3] }, elements_ok(engine, html, "class.group@children.0"),
    "children supports a zero-based position")
equal([[<div class="group" id="g2"><a class="book" href="/b1"><span>B1</span></a><a class="book" href="/b2">B2</a></div>]],
    elements_ok(engine, html, "id.g2")[1], "id default selector is supported")

equal("A1", parse_ok(engine, first_per_group[1], "@text"),
    "serialized list members expose current-root text")
equal("https://example.test/a1", parse_ok(engine, first_per_group[1], "@href", {
    baseUrl = "https://example.test/catalog",
}), "serialized list members expose and resolve current-root attributes")
local group_member = elements_ok(engine, html, "id.g1")[1]
equal("A1", parse_ok(engine, group_member, "children.0@text"),
    "children starts at the serialized member rather than the synthetic document root")
equal("/a1", parse_ok(engine, group_member, "children.0@href"),
    "children exposes attributes from the selected direct child")
equal("A1A2", parse_ok(engine, html, "children.0@text"),
    "full-document children starts at its single real root element")
equal("A1\nB1", parse_ok(engine, html, "class.group@tag.a.0@text"),
    "class and tag chains still apply positions per selected parent")
equal("A1", parse_ok(engine, first_per_group[1], "tag.span@text"),
    "default navigation extracts nested text")
equal("One\nTwo", parse_ok(engine, html, "tag.p@text"),
    "scalar default rules preserve all paragraph text")
array_equal({ "One", "Two" }, parse_ok(engine, html, "tag.p@text", {}, true),
    "list default rules retain individual text values")
equal("A1", parse_ok(engine, html, ".group a@text"),
    "existing CSS scalar behavior remains first-match compatible")

local unsupported_values, unsupported_error = engine:parseElements(html, "tag.a[0,1]", {})
equal(nil, unsupported_values, "unsupported default index syntax returns no values")
equal("UNSUPPORTED_RULE", unsupported_error and unsupported_error.code,
    "unsupported default index syntax has a structured error")
truthy(unsupported_error and unsupported_error.message:find("index", 1, true),
    "unsupported default index error names the limitation")

local expanded, expand_error = engine:expandTemplate("/popular?page={{page}}", { page = 3 })
equal(nil, expand_error, "relative URL templates expand without selector evaluation")
equal("/popular?page=3", expanded, "relative URL template remains a URL")
equal("Bearer source-token", engine:expandTemplate("Bearer {{key}}", { key = "source-token" }),
    "header templates expand as plain strings")
equal("VALUE", engine:expandTemplate("{{upper({{trim(result)}})}}", { result = " value " }),
    "nested safe templates expand")
local script_value, script_error = engine:expandTemplate("{{eval('danger')}}", {})
equal(nil, script_value, "script templates never execute")
equal("UNSUPPORTED_RULE", script_error and script_error.code, "script templates are rejected")

local ordinary_tables = CompatibilityScanner.scan({
    searchUrl = "https://example.test/search?q={{key}}",
    ruleSearch = { bookList = "class.book", name = "@text", bookUrl = "@href" },
    ruleBookInfo = { name = "class.title@text" },
    ruleToc = { chapterList = "class.chapter", chapterName = "@text", chapterUrl = "@href" },
    ruleContent = { content = "class.content@html" },
})
equal("usable", ordinary_tables.status, "ordinary object-shaped core rules are usable")
equal(0, #ordinary_tables.issues, "ordinary object-shaped core rules have no missing issues")

for _, unsafe_rule in ipairs({ "@webjs:return document.body", "<useweb><p>interactive</p></useweb>" }) do
    local report = CompatibilityScanner.scan({
        searchUrl = "https://example.test/search",
        ruleSearch = { bookList = unsafe_rule },
        ruleBookInfo = { name = "@text" },
        ruleToc = { chapterList = "class.chapter" },
        ruleContent = { content = "class.content@html" },
    })
    equal("unsupported", report.status, "WebView-dependent core rules are unsupported")
    equal("WEBVIEW", report.issues[1] and report.issues[1].code,
        "WebView-dependent syntax has a stable capability code")
end

return assertion_count
