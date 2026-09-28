require("library_screen_stub")
local assertx = require("assertions")
local App = require("legado.ui.app")
local Downloads = require("legado.ui.downloads")
local Presenter = require("legado.ui.presenter")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local tasks = {
    { id = "active", kind = "cache", book = { name = "下载中" }, status = "running", completed = 2, total = 5, current = "c2" },
    { id = "failed", book = { name = "失败书" }, status = "failed", completed = 1, total = 3, failed = 1 },
    { id = "done", book = { name = "完成书" }, status = "completed", completed = 4, total = 4, final_path = "downloads/done.epub",
      published_diagnostic = { code = "STORAGE_ERROR", message = "EPUB published with a cleanup warning" } },
    { id = "old", book = { name = "中断书" }, status = "interrupted", completed = 1, total = 2 },
    { id = "offline-done", kind = "cache", book = { name = "离线书" }, status = "completed", completed = 5, total = 5 },
    { id = "partial", kind = "cache", end_index = 18, book = { name = "部分缓存" }, status = "queued", completed = 0, total = 18 },
}
local calls = {}
local manager = {
    list = function() return tasks end,
    enqueue = function(_, book) calls[#calls + 1] = "enqueue:" .. book.id; return { id = "new", status = "queued" } end,
    enqueueCache = function(_, book) calls[#calls + 1] = "cache:" .. book.id; return { id = "cached", kind = "cache", status = "queued" } end,
    cancel = function(_, id) calls[#calls + 1] = "cancel:" .. id; return true end,
    retry = function(_, id) calls[#calls + 1] = "retry:" .. id; return true end,
    resume = function(_, id) calls[#calls + 1] = "resume:" .. id; return true end,
    open = function(_, id) calls[#calls + 1] = "open:" .. id; return "opened" end,
}

do
    local view = Downloads.new({ manager = manager })
    equal("downloads", view.kind, "download manager view has stable kind")
    equal(6, #view.items, "download history is listed")
    truthy(view.items[1].text:find("2/5", 1, true), "active progress is visible")
    truthy(view.items[1].text:find("40%%"), "cache task shows a percentage")
    truthy(view.items[1].text:find("章节缓存", 1, true), "cache task is distinguished from EPUB export")
    truthy(view.items[6].text:find("第 1 至 18 章", 1, true), "partial cache range is visible")
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
    equal("cached", detail:startCache().id, "book detail can queue chapter caching")
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
    local offline_actions = menu.item_table[5].callback()
    menu.close_callback()
    equal("返回书架阅读", offline_actions.item_table[1].text, "completed chapter cache leads back to the shelf")
    truthy(type(menu.close_callback) == "function", "download menu exposes lifecycle close callback")
    menu.close_callback()
    equal(false, view.alive, "presenter close callback invalidates stale actions")

    local detail = App.new({ download_manager = manager }):createBookDetail({
        id = "book-presenter", source_id = "source-ui", name = "详情下载",
    })
    local detail_menu = presenter:show(detail)
    for _,item in ipairs(detail_menu.actions) do
        if item.text=="更多" then item.callback(); break end
    end
    local download_action
    for _, item in ipairs(shown[#shown].item_table) do
        if item.text == "导出 EPUB" then download_action = item; break end
    end
    truthy(download_action, "detail More menu exposes the whole-book download action")
    local cache_action
    for _, item in ipairs(shown[#shown].item_table) do
        if item.text == "缓存整本（离线阅读）" then cache_action = item; break end
    end
    truthy(cache_action, "detail More menu exposes in-app offline caching")
    download_action.callback()
    equal("string", type(shown[#shown].subtitle), "queued task result is rendered as a user-facing message, not a table")

    local local_detail = App.new({ download_manager = manager }):createBookDetail({
        id = "local-book", source_id = "local", name = "本地文件", is_local = true,
    })
    local local_menu = presenter:show(local_detail)
    for _, item in ipairs(local_menu.actions) do
        if item.text == "更多" then item.callback(); break end
    end
    for _, item in ipairs(shown[#shown].item_table) do
        truthy(item.text ~= "导出 EPUB" and item.text ~= "缓存整本（离线阅读）",
            "local documents do not show source-download actions")
    end
end

do
    local shown, selected = {}, nil
    local ui = { show = function(_, widget) shown[#shown + 1] = widget end }
    local range_manager = { enqueueCache = function(_, _, _, ending)
        selected = ending; return { id = "partial", status = "queued" }
    end }
    local app = App.new({ download_manager = range_manager })
    local detail = app:createBookDetail({ id = "range-book", source_id = "range-source", name = "选章缓存" })
    local chapters = {}
    for index = 1, 45 do chapters[index] = { uid = "c" .. index, index = index, title = "第" .. index .. "章" } end
    detail.catalog_lookup = function() return chapters end
    local presenter = Presenter.new({ app = app, ui_manager = ui,
        input_dialog = { new = function(_, options) return options end } })
    local detail_menu = presenter:show(detail)
    for _, action in ipairs(detail_menu.actions) do
        if action.text == "更多" then action.callback(); break end
    end
    local partial
    for _, action in ipairs(shown[#shown].items) do
        if action.text == "缓存部分章节" then partial = action; break end
    end
    truthy(partial, "detail offers a partial chapter cache action")
    partial.callback()
    local catalog_menu = shown[#shown]
    equal("选择缓存截至章节", catalog_menu.title, "partial cache opens chapter selector")
    local jump
    for _, action in ipairs(catalog_menu.actions or {}) do
        if action.text == "跳转章节" then jump = action; break end
    end
    truthy(jump, "chapter selector supports fast jump")
    jump.callback()
    shown[#shown].buttons[1][2].callback("37")
    catalog_menu = shown[#shown]
    equal(3, catalog_menu.page, "jump opens the requested chapter page")
    catalog_menu.items[7].callback()
    equal(37, selected, "selected chapter is passed as the inclusive range end")
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
    menu.item_table[1].callback()
    menu.close_callback()
    local actions = shown[#shown]
    actions.close_callback()
    equal(true, view.alive, "leaving download actions restores the list model")
    truthy(view.refresh_action, "returning to downloads retains its refresh timer")
    shown[#shown].close_callback()
    local scheduled_count = #scheduled
    scheduled[scheduled_count].callback()
    equal(scheduled_count, #scheduled, "dismissed download menu cannot renew its refresh timer")
end

do
    local scheduled, refreshed = {}, 0
    local task = { id = "restart", book = { name = "重新下载" }, status = "failed", completed = 0, total = 2 }
    local manager = {
        list = function() return { task } end,
        retry = function()
            task.status = "queued"
            return true
        end,
    }
    local scheduler = { scheduleIn = function(_, _, callback)
        scheduled[#scheduled + 1] = callback
    end }
    local view = Downloads.new({ manager = manager, scheduler = scheduler,
        on_refresh = function() refreshed = refreshed + 1 end })
    equal(0, #scheduled, "failed-only list starts without a polling timer")
    truthy(view:retry("restart"), "failed task can be retried")
    equal(1, refreshed, "retry immediately refreshes the visible progress list")
    equal(1, #scheduled, "retry starts progress polling for a previously idle list")
    task.status, task.completed = "running", 1
    scheduled[1]()
    truthy(view.items[1].text:find("1/2", 1, true), "restarted polling follows retry progress")
    view:close()
end

do
    local shown, closed = {}, {}
    local task = { id = "popup-retry", book = { name = "待重试" }, status = "failed" }
    local manager = { list = function() return { task } end,
        retry = function() task.status = "queued"; return true end }
    local presenter = Presenter.new({ menu = { new = function(_, options) return options end },
        ui_manager = {
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function(_, widget) closed[widget] = true end,
        } })
    local view = Downloads.new({ manager = manager })
    local list = presenter:show(view)
    local popup = list.item_table[1].callback()
    equal("重试", popup.item_table[1].text, "failed task offers retry")
    popup.item_table[1].callback()
    truthy(closed[popup], "running retry closes the stale action popup")
    truthy(shown[#shown].item_table[1].text:find("等待中", 1, true),
        "retry returns to a list with the new task status")
    shown[#shown].close_callback()
    equal(false, view.alive, "closing the refreshed download list releases its view")
end

do
    local shown, closed, opened, returned = {}, {}, 0, 0
    local task = { id = "ready-epub", kind = "epub", book = { name = "已导出" },
        status = "completed", final_path = "downloads/ready.epub" }
    local manager = { list = function() return { task } end,
        open = function() opened = opened + 1; return "reader opened" end }
    local presenter = Presenter.new({ menu = { new = function(_, options) return options end },
        ui_manager = {
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function(_, widget) closed[widget] = true end,
        } })
    local view = Downloads.new({ manager = manager })
    view._back = function() returned = returned + 1 end
    local list = presenter:show(view)
    local popup = list.item_table[1].callback()
    popup.item_table[1].callback()
    popup.close_callback() -- KOReader calls this after the selected item callback.
    equal(1, opened, "completed EPUB opens once")
    truthy(closed[popup] and closed[list], "opening EPUB closes both download menus")
    equal(false, view.alive, "opening EPUB releases download refresh state")
    equal(2, #shown, "download list does not reopen over the EPUB reader")
    equal(0, returned, "opening EPUB does not navigate back to the shelf")
end

do
    local shown, closed, returned = {}, {}, 0
    local task = { id = "ready-cache", kind = "cache", book = { name = "已缓存" }, status = "completed" }
    local view = Downloads.new({ manager = { list = function() return { task } end } })
    view._back = function() returned = returned + 1 end
    local presenter = Presenter.new({ menu = { new = function(_, options) return options end },
        ui_manager = {
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function(_, widget) closed[widget] = true end,
        } })
    local list = presenter:show(view)
    local popup = list.item_table[1].callback()
    popup.item_table[1].callback()
    popup.close_callback()
    equal(1, returned, "completed cache returns through the original shelf path")
    truthy(closed[popup] and closed[list], "returning to the shelf closes both download menus")
    equal(false, view.alive, "returning to the shelf releases download refresh state")
    equal(2, #shown, "download list does not reopen over the shelf")
end

do
    local shown = {}
    local task = { id = "broken-epub", kind = "epub", book = { name = "打开失败" },
        status = "completed", final_path = "downloads/broken.epub" }
    local view = Downloads.new({ manager = { list = function() return { task } end,
        open = function() return nil, { code = "STORAGE_ERROR" } end } })
    local presenter = Presenter.new({ menu = { new = function(_, options) return options end },
        info_message = { new = function(_, options) options.kind = "info"; return options end },
        ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end,
            close = function() end } })
    local list = presenter:show(view)
    local popup = list.item_table[1].callback()
    popup.item_table[1].callback()
    popup.close_callback()
    equal("info", shown[#shown].kind, "failed EPUB open shows an error instead of navigating")
    equal(true, view.alive, "failed EPUB open keeps download management available")
    equal(4, #shown, "late menu close does not reopen another list over the error")
end

return count
