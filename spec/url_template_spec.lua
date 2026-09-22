local assertx = require("assertions")
local RuleEngine = require("legado.lib.rule_engine")
local SafeFunctions = require("legado.lib.safe_functions")
local UrlTemplate = require("legado.lib.url_template")

local rules = RuleEngine.new({
    safe_functions = SafeFunctions.functions,
    url_resolver = SafeFunctions.resolve_url,
})
local templates = UrlTemplate.new({ rule_engine = rules })

local request, request_error = templates:build(
    "https://books.test/search?q={{urlEncode(key)}}&page={{page}}",
    { key = "A b", page = 3 })
assertx.equal(nil, request_error, "GET template builds")
assertx.equal("GET", request.method, "GET method default")
assertx.equal("https://books.test/search?q=A%20b&page=3", request.url, "safe key/page expansion")

local post, post_error = templates:build(
    'https://books.test/search,{"method":"POST","body":"q={{urlEncode(key)}}&page={{page}}","headers":{"X-Source":"safe"}}',
    { key = "A b", page = 2 })
assertx.equal(nil, post_error, "common POST template builds")
assertx.equal("POST", post.method, "common form method")
assertx.equal("q=A%20b&page=2", post.body, "POST body template expansion")
assertx.equal("safe", post.headers["X-Source"], "POST headers retained")

assertx.equal(
    "https://books.test/catalog/next?page=2",
    templates:resolve("https://books.test/catalog/index.html", "next?page=2"),
    "relative URLs resolve against the current page")

local pages, page_error = templates:paginate(
    "https://books.test/list?page={{page}}&q={{urlEncode(key)}}", "term", 2, 3)
assertx.equal(nil, page_error, "pagination helper succeeds")
assertx.equal(3, #pages, "pagination count")
assertx.equal("https://books.test/list?page=2&q=term", pages[1].url, "first pagination URL")
assertx.equal("https://books.test/list?page=4&q=term", pages[3].url, "last pagination URL")

local rejected, rejected_error = templates:build("https://books.test/{{openFile(key)}}", { key = "secret" })
assertx.equal(nil, rejected, "executable template rejected")
assertx.equal("UNSUPPORTED_RULE", rejected_error.code, "template error remains structured")

return 15
