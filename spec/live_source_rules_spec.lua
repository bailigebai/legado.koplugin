local A = require("assertions")
local Rules = require("legado.lib.rule_engine")
local Safe = require("legado.lib.safe_functions")
local Html = require("legado.vendor.htmlparser")

local engine = Rules.new({
    html_parser = Html,
    url_resolver = Safe.resolve_url,
    safe_functions = Safe.functions,
})
local assertion_count = 0
local function equal(expected, actual, message)
    assertion_count = assertion_count + 1
    A.equal(expected, actual, message)
end
local function parse(input, rule, context, list)
    local values, err = engine:parse(input, rule, context or {}, list)
    equal(nil, err, "value rule succeeds: " .. rule)
    return values
end
local function elements(input, rule, context)
    local values, err = engine:parseElements(input, rule, context or {})
    equal(nil, err, "element rule succeeds: " .. rule)
    return values
end
local function array_equal(expected, actual, message)
    equal("table", type(actual), message)
    equal(#expected, #actual, message .. " length")
    for index, value in ipairs(expected) do equal(value, actual[index], message .. " item " .. index) end
end

local link = [[<a href="/book/1" data-id="one">Title <span>Extra</span> Tail</a>]]
equal("https://example.test/book/1", parse(link, "href", { baseUrl = "https://example.test/search" }),
    "real chapterUrl href reads and resolves the selected member")
equal("one", parse(link, "data-id"), "bare attributes read the selected member")
equal("Title Tail", parse(link, "ownText"), "bare ownText excludes descendant text")
equal([[Title <span>Extra</span> Tail]], parse(link, "html"), "bare html retains markup")
array_equal({ "Title", "Tail" }, parse(link, "textNodes", {}, true), "bare textNodes retains text segments")
equal(nil, parse("<a>Missing</a>", "href"), "missing current attribute stays empty")

local html = [[<main><ul id="main"><li>Header</li><li>A</li><li>B</li></ul>]]
    .. [[<div id="list"><a href="/1">One</a><a href="/2">Two</a></div>]]
    .. [[<div class="c wrap"><li>C</li></div><div class="c"><wrap><li>Wrong</li></wrap></div>]]
    .. [[<section class="group"><a>A1</a><a>A2</a><a>A3</a></section>]]
    .. [[<section class="group"><a>B1</a><a>B2</a><a>B3</a></section>]]
    .. [[<p class="text-center padding-large"><a href="/next">下一章</a></p>]]
    .. [[<a href="/catalog">点击阅读</a><a href="/wrong"><span>点击阅读</span></a>]]
    .. [[</main>]]

array_equal({ "<li>A</li>", "<li>B</li>" }, elements(html, "id.main@li!0"),
    "real search list omits its heading")
array_equal({ [[<a href="/1">One</a>]], [[<a href="/2">Two</a>]] }, elements(html, "id.list@a"),
    "real catalog list chains an id selector with a CSS tag")
array_equal({ "<li>C</li>" }, elements(html, "class.c wrap@li"),
    "a spaced class name does not become a descendant selector")
array_equal({ "<a>A3</a>", "<a>A1</a>", "<a>B3</a>", "<a>B1</a>" },
    elements(html, "class.group@a.-1:0:-1:99"), "indexes retain requested order and remove duplicates per parent")
array_equal({ "<a>A2</a>", "<a>B2</a>" }, elements(html, "class.group@a!0:-1"),
    "negative exclusions apply inside each parent")
array_equal({ "<a>A1</a>", "<a>B1</a>" }, elements(html, ".group@a.0"),
    "CSS may start a chained list rule")
array_equal({}, elements(html, "id.list@a.99"), "out-of-range indexes are empty")
equal("A1\nB1", parse(html, ".group@a.0@text"), "mixed value chains join selected parents")
equal("/catalog", parse(html, "text.点击阅读@href"), "text selectors match own text rather than ancestor text")
equal("/next", parse(html, "p.text-center.padding-large@tag.a:contains(下一章)@href"),
    "the corpus mixed next-chapter selector resolves its link")
equal("/1", parse([[<a class="book" href="/1">One</a>]], "class.book@href"),
    "default selection includes the current root element")
equal("One", parse([[<a href="/1">One</a>]], "tag.a@text"),
    "default tag selection includes the current root element")
equal("One", parse(html, "#list a@text"), "existing scalar CSS still returns its first match")

for _, rule in ipairs({ "tag.a[0,1]", "tag.a[1:3]", "tag.a!0::1" }) do
    local values, err = engine:parseElements(html, rule, {})
    equal(nil, values, "unsupported index returns no partial output")
    equal("UNSUPPORTED_RULE", err and err.code, "unsupported indexes stay explicit")
end
local values, err = engine:parse(html, "id.list@a@js:result", {})
equal(nil, values, "mixed chains never execute script")
equal("UNSUPPORTED_RULE", err and err.code, "script rejection remains explicit")

local english_source = [[<article class="grow"><h2><a>English</a><a>Title</a></h2>]]
    .. [[<div>Author</div><div>Summary</div><div><span>Fiction</span><span>Other</span></div></article>]]
    .. [[<section class="listshadow1"><div class="text-danger"><h2>Book</h2></div>]]
    .. [[<div class="text-danger">Author</div><div class="text-danger">Classic</div>]]
    .. [[<div class="text-danger">Adventure</div></section>]]
equal("Fiction", parse(english_source, "@css:.grow>div:nth-child(4) span:first-child@text"),
    "live English source search kind uses first-child")
array_equal({ "English", "Title" }, parse(english_source, "@css:.grow h2>a:nth-child(n)@text", {}, true),
    "live English source search name accepts nth-child n")
array_equal({ "Classic", "Adventure" },
    parse(english_source, "@css:.listshadow1 .text-danger:nth-child(n+3)@text", {}, true),
    "live English source detail kind starts at the third sibling")
equal("Book", parse(english_source, "@css:.listshadow1 .text-danger:first-child h2@text"),
    "live English source details retain the first heading")
array_equal({ "Classic", "Adventure" },
    parse(english_source, ".listshadow1 > div:nth-of-type(n + 3)@text", {}, true),
    "type positions use the same bounded n-offset syntax")
for _, rule in ipairs({ "a:nth-child(2n+1)@text", "a:first-child(2)@text" }) do
    local selected, select_error = engine:parse(english_source, rule, {})
    equal(nil, selected, "unsupported positional expression returns no partial output")
    equal("PARSE_ERROR", select_error and select_error.code, "unsupported positional expression stays explicit")
end

local sf_detail = [[<main><a href="/Novel/1/MainIndex/">点击阅读</a>]]
    .. [[<p class="comment-text"><font color="blue"><b>Notice</b></font></br>Follow<br/>More</p>]]
    .. [[<p data-example="</br>">Example</p><script>var example = "</br>";</script>]]
    .. [[<!-- literal </br> --></main>]]
equal("https://book.sfacg.com/Novel/1/MainIndex/", parse(sf_detail, "text.点击阅读@href", {
    baseUrl = "https://book.sfacg.com/Novel/1/",
}), "real SF detail structure accepts its closing br without losing the catalog link")
equal([[<font color="blue"><b>Notice</b></font><br>Follow<br/>More]],
    parse(sf_detail, ".comment-text@html"), "closing br becomes a real line break in extracted content")
equal("</br>", parse(sf_detail, "p[data-example]@data-example"), "attribute text is not normalized as a tag")
equal([[var example = "</br>";]], parse(sf_detail, "script@html"), "raw script text is not normalized as markup")
local invalid, invalid_error = engine:parse("<div><span>Text</div></span>", "text", {})
equal(nil, invalid, "genuinely mismatched tags remain rejected")
equal("PARSE_ERROR", invalid_error and invalid_error.code, "mismatched tags retain their error code")

array_equal({ "One", "Two" }, elements(html, "#list a@text"),
    "existing CSS element-list text extraction remains supported")
array_equal({ "/1", "/2" }, elements(html, "#list a@href"),
    "existing CSS element-list URL extraction remains supported")

local bare_css = [[<main><h1>Heading</h1><div>Content</div>]]
    .. [[<section><a>First</a><a>Second</a></section><x-card>Custom</x-card></main>]]
equal("Heading", parse(bare_css, "h1"), "bare heading rules remain CSS selectors")
equal("Content", parse(bare_css, "div"), "bare container rules remain CSS selectors")
equal("First", parse(bare_css, "a:first-child"), "bare CSS pseudo selectors are not mistaken for attributes")
array_equal({ "First", "Second" }, parse(bare_css, "a", {}, true), "bare CSS selectors retain list output")
equal("Custom", parse(bare_css, "x-card"), "custom HTML tag names remain CSS selectors")
local attributes = [[<a alt="Cover" title="Book" content="Summary" value="Selected" id="entry" book-key="custom">Link</a>]]
for attribute, expected in pairs({ alt="Cover", title="Book", content="Summary", value="Selected", id="entry" }) do
    equal(expected, parse(attributes, attribute), "common bare attributes remain current-node extractors")
end
equal("custom", parse(attributes, "@book-key"), "arbitrary attributes remain available through explicit at syntax")

return assertion_count
