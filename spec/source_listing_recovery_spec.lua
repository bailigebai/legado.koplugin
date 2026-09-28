require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local SourceManager = require("legado.ui.source_manager")

local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

local available = false
local source = { id = "source-1", bookSourceName = "原有书源", enabled = true,
    enabledExplore = true, exploreUrl = "分类::https://example.test/list" }
local records = { source }
local storage = {
    listSources = function()
        if not available then return nil, { code = "STORAGE_ERROR" } end
        return records
    end,
    listShelf = function() return {} end,
}
local manager = SourceManager.new({ storage = storage })
eq("STORAGE_ERROR", manager:viewModel().load_error and manager:viewModel().load_error.code,
    "source manager model distinguishes storage failure from an empty import list")

local shown, source_returns, discovery_returns = {}, 0, 0
local presenter = Presenter.new({ ui_manager = {
    show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end,
} })
local app = App.new({ storage = storage, source_manager = manager,
    book_service = { exploreCategories = function() return {} end },
    show = function(view) return presenter:show(view) end })
presenter.app = app
local function last() return shown[#shown] end

app:openSources(function() source_returns = source_returns + 1 end)
eq("书源读取失败 · STORAGE_ERROR", last().items[1].text,
    "source management shows the read error instead of saying there are no sources")
eq("重新读取书源", last().items[2].text, "source management provides a retry action")
eq(nil, last().actions[1], "source management does not offer imports while storage is unreadable")
last().items[2].callback()
eq("书源读取失败 · STORAGE_ERROR", last().items[1].text,
    "failed source management retry remains on the error page")
available = true
local stale_source_retry = last().items[2].callback
stale_source_retry()
eq("原有书源", last().items[1].title, "source management reloads the saved source")
eq("从本地 JSON 导入", last().actions[1].text, "imports return after source storage recovers")
last().on_back()
eq(1, source_returns, "source management returns to its originating shelf")
local shown_after_source_exit = #shown
stale_source_retry()
eq(shown_after_source_exit, #shown, "stale source retry cannot reopen a page after exit")

available = false
app:openDiscovery(function() discovery_returns = discovery_returns + 1 end)
eq("书源读取失败 · STORAGE_ERROR", last().empty_text,
    "discovery reports storage failure instead of asking to import sources")
eq("重新读取书源", last().actions[1].text, "discovery offers retry on the same page")
last().actions[1].callback()
eq("书源读取失败 · STORAGE_ERROR", last().empty_text,
    "failed discovery retry keeps the error visible")
available = true
local stale_discovery_retry = last().actions[1].callback
stale_discovery_retry()
eq("原有书源", last().items[1].title, "discovery loads saved sources after recovery")
last().on_back()
eq(1, discovery_returns, "discovery returns to its originating shelf")
local shown_after_discovery_exit = #shown
stale_discovery_retry()
eq(shown_after_discovery_exit, #shown, "stale discovery retry cannot reopen a page after exit")

records = {}
app:openSources()
eq("暂无自行导入的书源", last().items[1].text,
    "successful empty source listing retains its ordinary empty state")
eq("从本地 JSON 导入", last().actions[1].text,
    "ordinary empty source management still permits importing")
local shown_after_source_reopen = #shown
stale_source_retry()
eq(shown_after_source_reopen, #shown,
    "retry from a previous source-manager session cannot replace a newly opened page")
app:openDiscovery()
eq("请先导入书源", last().empty_text, "ordinary empty discovery asks for sources")
eq(nil, last().actions[1], "ordinary empty discovery does not show a storage retry")

return count
