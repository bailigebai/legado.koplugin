local A = require("assertions")
local Json = require("legado.lib.json_codec")
local RuleEngine = require("legado.lib.rule_engine")
local Safe = require("legado.lib.safe_functions")
local Service = require("legado.lib.book_service")
local Templates = require("legado.lib.url_template")
local Models = require("legado.lib.models")
local count = 0
local function eq(a, b, why) count = count + 1; A.equal(a, b, why) end
local source = { id = "fixture", bookSourceUrl = "https://fiction.test/", bookSourceName = "Fiction",
    searchUrl = "/search?q={{key}}", ruleSearch = { bookList = "$.books[*]", name = "$.name", bookUrl = "$.url" } }
local requests, pending = {}, {}
local rules = RuleEngine.new({ json_decoder = Json, html_parser = require("legado.vendor.htmlparser"),
    safe_functions = Safe.functions, url_resolver = Safe.resolve_url })
local service = Service.new({ storage = { listSources = function() return { source } end,
    getSource = function() return source end }, rule_engine = rules, url_template = Templates.new({ rule_engine = rules }),
    request_engine = { execute = function(_, request, callback)
        requests[#requests + 1] = request; pending[#pending + 1] = callback
        return { cancel = function() return true end }
    end } })

source.exploreUrl = { { title = " Top ", url = "/top?page={{page}}", style = { layout_flexGrow = 1 } },
    { title = "Heading", url = "" }, { title = "Broken", url = "@js:java.ajax('https://bad.test')" } }
local categories = assert(service:exploreCategories(source))
eq("Top", categories[1].title, "static table categories are normalized")
eq(" Top ", source.exploreUrl[1].title, "parsing does not mutate stored source definitions")
eq(nil, categories[2].url, "empty URL is a heading")
eq("UNSUPPORTED_RULE", categories[3].error.code, "one dynamic URL is diagnosed independently")
source.exploreUrl = '[{"title":"Heading","url":null,"style":{"layout_flexGrow":1}},{"title":"Top","url":"/top"},{"title":"Broken","url":12}]'
categories = assert(service:exploreCategories(source))
eq(nil, categories[1].url, "Legado JSON null URLs are headings")
eq("/top", categories[2].url, "valid categories survive a malformed sibling")
eq("INVALID_INPUT", categories[3].error.code, "malformed sibling carries its own diagnostic")
source.exploreUrl = "Top::/top?page={{page}}&&Broken::@js:result"
categories = assert(service:exploreCategories(source))
eq("/top?page={{page}}", categories[1].url, "mixed static text preserves the usable category")
eq("UNSUPPORTED_RULE", categories[2].error.code, "mixed text does not execute script categories")
local failure
service:explore(source.id, 2, 1, function(_, err) failure = err end)
eq("UNSUPPORTED_RULE", failure.code, "opening an unsupported category returns the precise reason")
eq(0, #requests, "unsupported category never reaches the network")

source.ruleExplore = { bookList = "", name = "@js:result" }
local result
service:explore(source.id, 1, 2, function(value, err) assert(not err); result = value end)
eq("https://fiction.test/top?page=2", requests[1].url, "fallback categories still expand page numbers")
pending[1]({ body = '{"books":[{"name":"Readable","url":"/one"}]}' })
eq("Readable", result.groups[1].book.name, "empty explore list falls back to the complete search rule")

for _, field in ipairs({ "coverUrl", "intro", "wordCount", "kind", "lastChapter" }) do
    source.ruleSearch[field] = "@js:result"
end
service:search("Readable", nil, 1, function(value, err) assert(not err); result = value end)
pending[#pending]({ body = '{"books":[{"name":"Readable","url":"/one"}]}' })
eq(1, #result.groups, "unsupported auxiliary fields cannot discard a recognizable book")
eq("", result.groups[1].book.cover_url, "unavailable cover becomes a placeholder")
eq("", result.groups[1].book.intro, "unavailable introduction remains empty")
eq(0, #result.errors, "auxiliary field incompatibility is not a failed source")
for _, field in ipairs({ "name", "author", "bookUrl" }) do
    local previous = source.ruleSearch[field]
    source.ruleSearch[field] = "@js:result"
    service:search("Readable", nil, 1, function(value) result = value end)
    pending[#pending]({ body = '{"books":[{"name":"Readable","url":"/one"}]}' })
    eq("UNSUPPORTED_RULE", result.errors[1].code, "core " .. field .. " failure remains visible")
    source.ruleSearch[field] = previous
end
local seed = Models.book(source, { name = "Readable", url = "/one", intro = "Known intro" })
source.ruleBookInfo = { intro = "@js:result", coverUrl = "@js:result", tocUrl = "$.toc" }
service:getBookInfo(source, seed, function(value, err) assert(not err); result = value end)
pending[#pending]({ body = '{"toc":"/toc"}' })
eq("Known intro", result.intro, "detail keeps known metadata when auxiliary extraction fails")
eq("https://fiction.test/toc", result.toc_url, "valid catalog URL still resolves")
source.ruleBookInfo.tocUrl = "@js:result"
service:getBookInfo(source, seed, function(_, err) failure = err end)
pending[#pending]({ body = '{}' })
eq("UNSUPPORTED_RULE", failure.code, "catalog link failures remain core errors")

local file = assert(io.open(os.getenv("LEGADO_PLUGIN_ROOT") .. "/../sources/yuedu-260114.json", "rb"))
local collection = Json.decode(file:read("*a")); file:close()
local exceptions, parsed, diagnosed = 0, 0, 0
for _, real_source in ipairs(collection) do
    local ok, value, err = pcall(service.exploreCategories, service, real_source)
    if not ok then exceptions = exceptions + 1
    elseif value then parsed = parsed + 1
    elseif err and (err.code == "INVALID_INPUT" or err.code == "UNSUPPORTED_RULE") then diagnosed = diagnosed + 1 end
end
eq(919, #collection, "regression reads the actual imported collection")
eq(0, exceptions, "all real explore definitions return data or a structured error")
eq(#collection, parsed + diagnosed, "every discovery source has a diagnosable outcome")
return count
