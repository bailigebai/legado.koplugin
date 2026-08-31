local assertx = require("assertions")
local App = require("legado.ui.app")
local Downloads = require("legado.ui.downloads")
local Presenter = require("legado.ui.presenter")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local tasks = {
    { id = "active", book = { name = "下载中" }, status = "running", completed = 2, total = 5, current = "c2" },
    { id = "failed", book = { name = "失败书" }, status = "failed", completed = 1, total = 3, failed = 1 },
    { id = "done", book = { name = "完成书" }, status = "completed", completed = 4, total = 4, final_path = "downloads/done.epub",
      published_diagnostic = { code = "STORAGE_ERROR", message = "EPUB published with a cleanup warning" } },
    { id = "old", book = { name = "中断书" }, status = "interrupted", completed = 1, total = 2 },
}
local calls = {}
local manager = {
    list = function() return tasks end,
    enqueue = function(_, book) calls[#calls + 1] = "enqueue:" .. book.id; return { id = "new", status = "queued" } end,
    cancel = function(_, id) calls[#calls + 1] = "cancel:" .. id; return true end,
    retry = function(_, id) calls[#calls + 1] = "retry:" .. id; return true end,
    resume = function(_, id) calls[#calls + 1] = "resume:" .. id; return true end,
    open = function(_, id) calls[#calls + 1] = "open:" .. id; return "opened" end,
}

do
    local view = Downloads.new({ manager = manager })
    equal("downloads", view.kind, "download manager view has stable kind")
    equal(4, #view.items, "download history is listed")
    truthy(view.items[1].text:find("2/5", 1, true), "active progress is visible")
    truthy(view.items[2].text:find("失败", 1, true), "failure state is visible")
    truthy(view.items[3].text:find("完成", 1, true), "completion state is visible")
    truthy(view.items[3].text:find("警告", 1, true), "published cleanup diagnostic is visible without marking failure")
    equal("active", view:focused().task.id, "physical focus starts at first task")
    truthy(view:onKey("Down"), "physical down key is handled")
    equal("failed", view:focused().task.id, "physical focus moves through download history")
    truthy(view:cancel("active"), "view delegates cancellation")
    truthy(view:retry("failed"), "view delegates retry")
    truthy(view:resume("old"), "view delegates interrupted resume")
    equal("opened", view:open("done"), "view delegates completed EPUB open")
    truthy(view:close(), "download view closes once")
    equal(false, view:close(), "download view close is idempotent")
    equal(false, view:retry("failed"), "closed view ignores stale touch callbacks")
end

do
    local app = App.new({ download_manager = manager })
    local view = app:openDownloads()
    equal("downloads", view.kind, "main menu opens live download manager view")
    local queued = app:startDownload({ id = "book-ui", source_id = "source-ui" })
    equal("new", queued.id, "detail download action enqueues through manager")
    local detail = app:createBookDetail({ id = "book-detail", source_id = "source-ui", name = "详情" })
    equal("new", detail:startDownload().id, "book detail uses the same download manager hook")
end

do
    local shown = {}
    local Menu = { new = function(_, options) return options end }
    local presenter = Presenter.new({ menu = Menu, ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end } })
    local view = Downloads.new({ manager = manager })
    local menu = presenter:show(view)
    equal("下载管理", menu.title, "presenter renders download management title")
    truthy(menu.item_table[1].text:find("下载中", 1, true), "presenter renders active task row")
    local actions = menu.item_table[1].callback()
    menu.close_callback()
    equal("下载操作", actions.title, "touching a task opens action menu")
    equal("取消下载", actions.item_table[1].text, "active task exposes cancel action")
    actions.item_table[1].callback()
    local failed_actions = menu.item_table[2].callback()
    menu.close_callback()
    equal("重试", failed_actions.item_table[1].text, "failed task exposes retry action")
    local done_actions = menu.item_table[3].callback()
    menu.close_callback()
    equal("打开 EPUB", done_actions.item_table[1].text, "completed task exposes open action")
    local interrupted_actions = menu.item_table[4].callback()
    menu.close_callback()
    equal("继续下载", interrupted_actions.item_table[1].text, "interrupted task exposes resume action")
    truthy(type(menu.close_callback) == "function", "download menu exposes lifecycle close callback")
    menu.close_callback()
    equal(false, view.alive, "presenter close callback invalidates stale actions")

    local detail = App.new({ download_manager = manager }):createBookDetail({
        id = "book-presenter", source_id = "source-ui", name = "详情下载",
    })
    local detail_menu = presenter:show(detail)
    local download_action
    for _, item in ipairs(detail_menu.item_table) do
        if item.text == "下载整本" then download_action = item; break end
    end
    truthy(download_action, "detail presenter exposes the whole-book download action")
    download_action.callback()
    equal("string", type(shown[#shown].text), "queued task result is rendered as a user-facing message, not a table")
end

do
    local scheduled, unscheduled, list_calls = {}, {}, 0
    local scheduler = {
        scheduleIn = function(_, delay, callback)
            local token = { delay = delay, callback = callback }
            scheduled[#scheduled + 1] = token; return nil
        end,
        unschedule = function(_, token) unscheduled[#unscheduled + 1] = token end,
    }
    local live_task = { id = "live", book = { name = "实时" }, status = "running", completed = 0, total = 2 }
    local live_manager = { list = function() list_calls = list_calls + 1; return { live_task } end }
    local view = Downloads.new({ manager = live_manager, scheduler = scheduler, refresh_interval = 3 })
    equal(1, #scheduled, "active download schedules one low-frequency refresh")
    equal(3, scheduled[1].delay, "download refresh uses the configured low-frequency interval")
    live_task.completed = 1
    scheduled[1].callback()
    truthy(view.items[1].text:find("1/2", 1, true), "scheduled refresh updates active progress")
    equal(2, #scheduled, "active progress schedules the next refresh only after the prior callback")
    local stale = scheduled[2].callback
    local calls_before_close = list_calls
    truthy(view:close(), "closing a live download view succeeds")
    equal(1, #unscheduled, "close unschedules the outstanding refresh action even when scheduleIn returns nil")
    equal(scheduled[2].callback, unscheduled[1], "KOReader unschedule receives the exact scheduled action function")
    stale()
    equal(calls_before_close, list_calls, "stale scheduled callbacks cannot refresh after close/back")
end

do
    local scheduled, shown = {}, {}
    local scheduler = { scheduleIn = function(_, _, callback)
        local token = { callback = callback }; scheduled[#scheduled + 1] = token; return token
    end, unschedule = function() end }
    local task = { id = "presented-live", book = { name = "菜单实时" }, status = "running", completed = 0, total = 2 }
    local view = Downloads.new({ manager = { list = function() return { task } end }, scheduler = scheduler })
    local presenter = Presenter.new({ menu = { new = function(_, options) return options end },
        ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end } })
    local menu = presenter:show(view)
    task.completed = 1
    scheduled[1].callback()
    truthy(menu.item_table[1].text:find("1/2", 1, true), "scheduled refresh updates the existing menu in place")
    equal(1, #shown, "scheduled refresh never opens a background popup")
    menu.close_callback()
end

return count
