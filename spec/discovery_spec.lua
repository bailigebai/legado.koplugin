require("library_screen_stub")
local A = require("assertions")
local Json = require("legado.lib.json_codec")
local RuleEngine = require("legado.lib.rule_engine")
local Safe = require("legado.lib.safe_functions")
local Service = require("legado.lib.book_service")
local Templates = require("legado.lib.url_template")
local Search = require("legado.ui.search")
local count = 0
local function eq(a, b, why) count = count + 1; A.equal(a, b, why) end
local source = {
    id = "https://fiction.test/", bookSourceUrl = "https://fiction.test/", bookSourceName = "Fiction",
    exploreUrl = "Popular::/popular?page={{page}}&&New::/new\nHeading",
    ruleExplore = { bookList = "$.books[*]", name = "$.name", bookUrl = "$.url" },
}
local sources = { source }
local requests, pending = {}, {}
local rules = RuleEngine.new({ json_decoder = Json, html_parser = require("legado.vendor.htmlparser"),
    safe_functions = Safe.functions, url_resolver = Safe.resolve_url })
local service = Service.new({
    storage = { getSource = function(_, id) if id == source.id then return source end end,
        listSources = function() return sources end },
    rule_engine = rules, url_template = Templates.new({ rule_engine = rules }),
    request_engine = { execute = function(_, request, callback)
        requests[#requests + 1] = request
        local entry = { callback = callback }; pending[#pending + 1] = entry
        return { cancel = function() entry.cancelled = true; return true end }
    end },
})
eq("function", type(service.exploreCategories), "discovery exposes parsed categories")
local categories = assert(service:exploreCategories(source))
eq(3, #categories, "Legado newline and double-ampersand categories")
eq("Popular", categories[1].title, "category title is preserved")
eq("/popular?page={{page}}", categories[1].url, "page templates are preserved")
eq(nil, categories[3].url, "section headings are not requests")
local result
service:explore(source.id, 1, 2, function(value, err) assert(not err); result = value end)
eq("https://fiction.test/popular?page=2", requests[1].url, "discovery expands page and resolves source URL")
pending[1].callback({ body = '{"books":[{"name":"Sample","url":"/book/1"}]}', final_url = requests[1].url })
eq("Sample", result.groups[1].book.name, "discovery uses production source rules")
eq("https://fiction.test/book/1", result.groups[1].book.url, "discovered books open as normal book models")
local called = 0
local handle = service:explore(source.id, 1, 3, function() called = called + 1 end)
handle:cancel()
pending[2].callback({ body = '{"books":[]}' })
eq(0, called, "cancelled discovery cannot update the view")
local invalid
service:explore(source.id, 3, 1, function(_, err) invalid = err end)
eq("INVALID_INPUT", invalid.code, "headings cannot trigger requests")
eq(2, #requests, "invalid category makes no network request")
source.enabled = false
service:explore(source.id, 1, 1, function(_, err) invalid = err end)
eq("INVALID_INPUT", invalid.code, "disabled source cannot run discovery")
source.enabled = true
source.exploreUrl = '[{"title":"Top","url":"/top"},{"title":"Section"}]'
eq("/top", assert(service:exploreCategories(source))[1].url, "JSON category list supported")
source.exploreUrl = '[{"title":"Bad","url":12}]'
local bad, err = service:exploreCategories(source)
eq(nil, bad, "non-string URL rejected")
eq("INVALID_INPUT", err.code, "malformed category explained")
source.exploreUrl = '@js:result'
bad, err = service:exploreCategories(source)
eq("UNSUPPORTED_RULE", err.code, "script categories are explicit incompatibilities")

local page_calls, callbacks = {}, {}
local view = Search.new({ service = { search = function(_, keyword, ids, page, callback)
    page_calls[#page_calls + 1] = { keyword, ids, page }; callbacks[#callbacks + 1] = callback
    return { cancel = function() return true end }
end } })
view:submit("Book", { "one" }, 1)
callbacks[1]({ groups = { { book = { name = "One" } } }, page = 1 })
eq(1, view.page, "search records current result page")
view:changePage(1)
eq(2, page_calls[2][3], "next page reuses the same query")
eq("one", page_calls[2][2][1], "pagination preserves selected sources")
callbacks[2]({ groups = {}, page = 2 })
eq(false, view.has_more, "empty page disables forward paging")
eq(false, view:changePage(1), "cannot request another empty page")
view:changePage(-1)
eq(1, page_calls[3][3], "previous page remains available")
view:close()
callbacks[3]({ groups = { { book = { name = "Stale" } } }, page = 1 })
eq(0, #view.results, "closed search ignores late pages")

local receive_page, requested_page
local paging = Search.new({ service = { search = function(_, _, _, page, callback)
    requested_page, receive_page = page, callback
    return { cancel = function() return true end }
end } })
paging:submit("Book", nil, 1)
receive_page({ groups = { { book = { name = "First" } } }, page = 1 })
paging:changePage(1)
local cancelled_page = receive_page
paging:cancel()
eq(1, paging.page, "cancelled pagination keeps the displayed result page")
eq("First", paging.results[1].book.name, "cancelled pagination keeps the displayed books")
cancelled_page({ groups = {}, page = 2 })
eq(1, paging.page, "late cancelled response cannot change the page")
paging:changePage(1)
eq(2, requested_page, "retrying forward after cancellation does not skip a page")
receive_page(nil, { code = "TIMEOUT" })
eq(2, paging.page, "failed request records its target page for retry")
eq("TIMEOUT", paging.error.code, "failed page exposes its request error")

local Presenter = require("legado.ui.presenter")
local shown, closed = {}, {}
local widget = { new = function(_, options) return options end }
local presenter = Presenter.new({ menu = widget, input_dialog = widget, info_message = widget,
    ui_manager = { show = function(_, item) shown[#shown + 1] = item end,
        close = function(_, item) closed[item] = true end } })
source.exploreUrl = "Popular::/popular"
local menu = presenter:show({ kind = "discovery", service = service, sources = { source } })
eq("Fiction", menu.item_table[1].text, "discovery menu shows available sources")
menu.item_table[1].callback()
local kinds = shown[#shown]
eq("Popular", kinds.item_table[1].text, "source opens its discovery categories")
kinds.item_table[1].callback()
local progress = shown[#shown]
pending[#pending].callback({ body = '{"books":[{"name":"Sample","url":"/book/1"}]}', final_url = requests[#requests].url })
local results_menu = shown[#shown]
eq(true, closed[progress], "completed discovery closes loading panel")
eq("Sample", results_menu.item_table[1].text, "discovery result is a selectable book")
eq("下一页", results_menu.item_table[#results_menu.item_table].text, "native results expose pagination")
results_menu.item_table[#results_menu.item_table].callback()
pending[#pending].callback({ body = '{"books":[]}', final_url = requests[#requests].url })
eq(true, closed[results_menu], "pagination retires the previous menu")

local source_menu = presenter:show({ kind = "source_manager", list = function() return {} end,
    importLocal = function() return { imported = 3, updated = 1, rejected = 0, compatibility = {
        { status = "usable" }, { status = "partial" }, { status = "unsupported" }, { status = "usable" },
    } } end })
source_menu.item_table[2].callback()
shown[#shown].buttons[1][2].callback("fixture.json")
local summary = shown[#shown].text
eq(true, summary:find("3", 1, true) ~= nil and summary:find("1", 1, true) ~= nil, "import summary reports committed counts")
return count
