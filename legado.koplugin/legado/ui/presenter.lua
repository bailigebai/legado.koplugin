local Presenter = {}
Presenter.__index = Presenter

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

local function construct(class, options)
    if class and type(class.new) == "function" then return class:new(options) end
    return options
end

local function safe_token(value, fallback)
    local token = tostring(value or ""):gsub("[^%w_%-%.]", "")
    return token ~= "" and token or fallback
end

local function diagnostic_text(error, compatibility)
    local code = safe_token(type(error) == "table" and error.code, "UNKNOWN_ERROR")
    local status = type(error) == "table" and type(error.details) == "table" and tonumber(error.details.status) or nil
    local lines = { "错误代码：" .. code, "说明：请求或解析失败，请检查书源配置。" }
    if status then lines[#lines + 1] = "状态码：" .. tostring(status) end
    if type(compatibility) == "table" then
        lines[#lines + 1] = "兼容性：" .. safe_token(compatibility.status, "unknown")
        for _, issue in ipairs(compatibility.issues or {}) do
            lines[#lines + 1] = safe_token(issue.field, "rule") .. "：" .. safe_token(issue.code, "UNSUPPORTED")
        end
    end
    return table.concat(lines, "\n")
end

function Presenter.new(options)
    options = options or {}
    return setmetatable({
        ui_manager = options.ui_manager or optional("ui/uimanager"),
        menu = options.menu or optional("ui/widget/menu"),
        info_message = options.info_message or optional("ui/widget/infomessage"),
        input_dialog = options.input_dialog or optional("ui/widget/inputdialog"),
        detail_factory = options.detail_factory,
        cover_grid_factory = options.cover_grid_factory or function(grid_options) return require("legado.ui.cover_grid").new(grid_options) end,
        closed_widgets = setmetatable({}, { __mode = "k" }),
        keyboard_widgets = setmetatable({}, { __mode = "k" }),
    }, Presenter)
end

function Presenter:_show(widget)
    if self.ui_manager and type(self.ui_manager.show) == "function" then self.ui_manager:show(widget) end
    return widget
end

function Presenter:_closeWidget(widget)
    if widget == nil or self.closed_widgets[widget] then return false end
    self.closed_widgets[widget] = true
    if self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(widget) end
    return true
end

function Presenter:_showInput(widget)
    self:_show(widget)
    if widget and not self.keyboard_widgets[widget] and type(widget.onShowKeyboard) == "function" then
        self.keyboard_widgets[widget] = true
        widget:onShowKeyboard()
    end
    return widget
end

function Presenter:_modelMenu(view, options)
    local selected, closed = false, false
    local wrapped = setmetatable({}, { __mode = "k" })
    local function prepare(items)
        for _, item in ipairs(items or {}) do
            if type(item.callback) == "function" and not wrapped[item] then
                local callback = item.callback
                item.callback = function(...)
                    selected = true
                    return callback(...)
                end
                wrapped[item] = true
            end
        end
        return items
    end
    prepare(options.item_table)
    local close_model = options.close_callback or function()
        if type(view.close) == "function" then return view:close() end
    end
    options.close_callback = function()
        if selected then selected = false; return false end
        if closed then return false end
        closed = true
        return close_model()
    end
    local widget = construct(self.menu, options)
    widget._legado_prepare_items = prepare
    return self:_show(widget)
end

function Presenter:_info(text, title)
    return self:_show(construct(self.info_message, { text = text or "", title = title }))
end

function Presenter:_shelf(view, page, mode)
    local model = view:page(page or 1, mode or "text")
    if model.mode == "cover" then
        local grid
        local function replace_grid(next_page, next_mode)
            if grid then
                if type(grid.closeForReplacement) == "function" then grid:closeForReplacement()
                else
                    grid.alive = false
                    for _, cell in ipairs(grid.cells or {}) do cell.item.on_update = nil end
                    if self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(grid) end
                end
            end
            return self:_shelf(view, next_page, next_mode)
        end
        grid = self.cover_grid_factory({
            model = model,
            on_select = function(book) if self.detail_factory then return self:show(self.detail_factory(book, { book })) end; return book end,
            on_prev = model.page > 1 and function() return replace_grid(model.page - 1, "cover") end or nil,
            on_next = model.page < model.page_count and function() return replace_grid(model.page + 1, "cover") end or nil,
            on_toggle = function() return replace_grid(model.page, "text") end,
            on_close = function() return view:close() end,
        })
        return self:_show(grid)
    end
    local items = {}
    for _, item in ipairs(model.items) do
        local label = item.title
        if item.subtitle and item.subtitle ~= "" then label = label .. " — " .. item.subtitle end
        if model.mode == "cover" then label = label .. "（" .. item.cover_text .. "）" end
        items[#items + 1] = { text = label, callback = function()
            if self.detail_factory then return self:show(self.detail_factory(item.book, { item.book })) end
            return item.book
        end }
    end
    if #items == 0 then items[#items + 1] = { text = model.empty_text or "书架为空", enabled = false } end
    items[#items + 1] = { text = "上一页", enabled = model.page > 1, callback = function() return self:_shelf(view, model.page - 1, model.mode) end }
    items[#items + 1] = { text = "下一页", enabled = model.page < model.page_count, callback = function() return self:_shelf(view, model.page + 1, model.mode) end }
    items[#items + 1] = { text = model.mode == "text" and "封面模式" or "文字模式", callback = function()
        return self:_shelf(view, model.page, model.mode == "text" and "cover" or "text")
    end }
    return self:_modelMenu(view, { title = "书架", item_table = items, is_popout = false })
end

function Presenter:_search_results(view)
    local items = {}
    for _, group in ipairs(view.results or {}) do
        local book = group.book
        items[#items + 1] = { text = (book.name or "未命名") .. (book.author ~= "" and (" — " .. book.author) or ""), callback = function()
            if self.detail_factory then return self:show(self.detail_factory(book, group.alternatives)) end
            if #group.alternatives <= 1 then return book end
            local alternatives = {}
            for _, candidate in ipairs(group.alternatives) do
                alternatives[#alternatives + 1] = { text = candidate.source_name ~= "" and candidate.source_name or "书源", callback = function() return candidate end }
            end
            return self:_show(construct(self.menu, { title = "选择书源", item_table = alternatives }))
        end }
    end
    if #items == 0 then items[1] = { text = "没有搜索结果", enabled = false } end
    if #(view.errors or {}) > 0 then
        items[#items + 1] = { text = "部分书源失败（查看详情）", callback = function()
            local lines = {}
            for _, err in ipairs(view.errors) do lines[#lines + 1] = (err.source_name or "书源") .. "：" .. (err.message or "失败") end
            return self:_info(table.concat(lines, "\n"), "搜索诊断")
        end }
    end
    return self:_modelMenu(view, {
        title = "搜索结果",
        item_table = items,
    })
end

function Presenter:_search(view)
    local dialog
    local function submit(value)
        local keyword = value
        if (keyword == nil or keyword == "") and dialog and type(dialog.getInputText) == "function" then keyword = dialog:getInputText() end
        if type(keyword) ~= "string" or keyword:match("^%s*$") then return self:_info("请输入书名", "搜索") end
        if not self:_closeWidget(dialog) then return false end
        view.onUpdate = function()
            if view.alive and not view.loading then
                if view.progress_widget and self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(view.progress_widget) end
                view.progress_widget = nil
                self:_search_results(view)
            end
        end
        local function start(ids)
            local handle = view:submit(keyword, ids, 1)
            if view.loading == false then return handle end
            local progress
            local closed = false
            local function close_progress(close_widget)
                if closed then return false end
                closed = true
                if type(view.cancel) == "function" then view:cancel() elseif type(view.close) == "function" then view:close() end
                if view.progress_widget == progress then view.progress_widget = nil end
                if close_widget and self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(progress) end
                return true
            end
            progress = construct(self.menu, { title = "搜索", item_table = {
                { text = "搜索中…", enabled = false },
                { text = "取消", callback = function() return close_progress(true) end },
            }, close_callback = function() return close_progress(false) end })
            view.progress_widget = progress
            return self:_show(progress)
        end
        local choices = type(view.sourceChoices) == "function" and view:sourceChoices() or {}
        if #choices == 0 then return start(nil) end
        local items = { { text = "全部已启用书源", callback = function() return start(nil) end } }
        for _, source in ipairs(choices) do
            items[#items + 1] = { text = source.name, callback = function() return start({ source.id }) end }
        end
        return self:_show(construct(self.menu, { title = "选择搜索书源", item_table = items }))
    end
    dialog = construct(self.input_dialog, {
        title = "搜索", input_hint = "搜索书名", input_type = "string",
        buttons = { { { text = "取消", callback = function() if self:_closeWidget(dialog) then return view:close() end; return false end }, { text = "搜索", is_enter_default = true, callback = submit } } },
    })
    return self:_showInput(dialog)
end

function Presenter:_sources(view)
    local items = {}
    for _, source in ipairs(view:list()) do
        local status = source.enabled == false and "已停用" or "已启用"
        local group = tostring(source.bookSourceGroup or "")
        items[#items + 1] = { text = tostring(source.bookSourceName or "未命名书源") .. " · " .. status .. (group ~= "" and (" · " .. group) or ""), callback = function()
            local actions = {
                { text = source.enabled == false and "启用书源" or "停用书源", callback = function() view:toggle(source.id); return self:_sources(view) end },
                { text = "兼容性报告", callback = function()
                    if type(view.compatibilityReport) == "function" then
                        local compatibility_view = view:compatibilityReport(source.id)
                        if compatibility_view then return self:show(compatibility_view) end
                    end
                    local report = view:compatibility(source.id) or { status = "unsupported", issues = {} }
                    local lines = { "状态：" .. tostring(report.status) }
                    for _, issue in ipairs(report.issues or {}) do lines[#lines + 1] = tostring(issue.field or "规则") .. "：" .. tostring(issue.code or "不支持") end
                    return self:_info(table.concat(lines, "\n"), "兼容性报告")
                end },
                { text = "更新书源", callback = function()
                    return view:update(source.id, function(result, err)
                        self:_info(err and "书源更新失败" or "书源更新完成", "更新书源")
                    end)
                end },
                { text = "删除书源", callback = function() local deleted = view:delete(source.id); if deleted == true then return self:_sources(view) end; return deleted end },
            }
            return self:_show(construct(self.menu, { title = tostring(source.bookSourceName or "书源"), item_table = actions }))
        end }
    end
    if #items == 0 then items[1] = { text = "暂无书源，请导入 JSON", enabled = false } end
    local function input_dialog(title, hint, submit)
        local dialog
        local function accepted(value)
            if (value == nil or value == "") and dialog and type(dialog.getInputText) == "function" then value = dialog:getInputText() end
            if type(value) ~= "string" or value:match("^%s*$") then return self:_info("请输入有效内容", title) end
            if not self:_closeWidget(dialog) then return false end
            return submit(value)
        end
        dialog = construct(self.input_dialog, { title = title, input_hint = hint, input_type = "string", buttons = {
            { { text = "取消", callback = function() return self:_closeWidget(dialog) end }, { text = "确定", is_enter_default = true, callback = accepted } },
        } })
        return self:_showInput(dialog)
    end
    items[#items + 1] = { text = "从本地 JSON 导入", callback = function()
        return input_dialog("导入书源", "JSON 文件路径", function(path)
            local report = view:importLocal(path)
            return self:_info(report and not report.error and (report.rejected or 0) == 0 and "导入完成" or "导入失败", "导入书源")
        end)
    end }
    items[#items + 1] = { text = "从网址导入", callback = function()
        return input_dialog("导入书源", "HTTPS 或 HTTP 地址", function(url)
            return view:importUrl(url, function(report, err)
                local text
                if err or (report and report.error) or (report and tonumber(report.rejected) and report.rejected > 0) then text = "远程导入失败"
                elseif report and report.warnings and #report.warnings > 0 then text = "导入完成；警告：HTTP 地址不安全"
                else text = "导入完成" end
                self:_info(text, "导入书源")
            end)
        end)
    end }
    return self:_modelMenu(view, { title = "书源管理", item_table = items })
end

local function diagnostic_report_text(report)
    local lines = { "状态：" .. safe_token(type(report) == "table" and report.status, "unknown") }
    for _, step in ipairs(type(report) == "table" and report.steps or {}) do
        local line = tostring(step.name or "step") .. "：" .. safe_token(step.status, "unknown")
        local duration = tonumber(step.duration_ms)
        if duration and duration >= 0 then line = line .. " · " .. tostring(math.floor(duration)) .. " ms" end
        if tonumber(step.http_status) then line = line .. " · HTTP " .. tostring(math.floor(tonumber(step.http_status))) end
        if type(step.charset) == "string" and step.charset:match("^[%w._%-]+$") then line = line .. " · " .. step.charset end
        local counts = {}
        if type(step.field_counts) == "table" then
            for _, name in ipairs({ "results", "fields", "chapters", "pages" }) do
                local value = tonumber(rawget(step.field_counts, name))
                if value and value >= 0 then counts[#counts + 1] = name .. "=" .. tostring(math.floor(value)) end
            end
        end
        if #counts > 0 then line = line .. " · " .. table.concat(counts, ",") end
        if type(step.error) == "table" then line = line .. " · " .. safe_token(step.error.code, "UNKNOWN_ERROR") end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

function Presenter:_compatibility(view)
    local items = { { text = "状态：" .. tostring(view.status or "unsupported"), enabled = false } }
    for _, capability in ipairs(view.capabilities or {}) do
        items[#items + 1] = {
            text = tostring(capability.name) .. "：" .. (capability.supported and "支持" or "不支持"),
            enabled = false,
        }
    end
    for _, issue in ipairs(view.issues or {}) do
        items[#items + 1] = {
            text = tostring(issue.field or "rule") .. "：" .. safe_token(issue.code, "UNSUPPORTED"),
            enabled = false,
        }
    end
    items[#items + 1] = { text = "运行诊断", enabled = view.diagnostics ~= nil, callback = function()
        local dialog
        local function start(keyword)
            if (keyword == nil or keyword == "") and dialog and type(dialog.getInputText) == "function" then keyword = dialog:getInputText() end
            if type(keyword) ~= "string" or keyword:match("^%s*$") then return self:_info("请输入测试书名", "书源诊断") end
            if not self:_closeWidget(dialog) then return false end
            local progress, handle, result_widget
            local completed, closed = false, false
            local function finish(report)
                if closed then return end
                completed = true
                if progress and self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(progress) end
                result_widget = self:_info(diagnostic_report_text(report), "书源诊断")
            end
            handle = view:run(keyword, finish)
            if completed then return result_widget or handle end
            local function cancel_once()
                if closed or completed then return false end
                closed = true
                if type(view.cancel) == "function" then
                    pcall(view.cancel, view)
                elseif handle and type(handle.cancel) == "function" then
                    pcall(handle.cancel, handle)
                end
                if progress and self.ui_manager and type(self.ui_manager.close) == "function" then self.ui_manager:close(progress) end
                return true
            end
            progress = construct(self.menu, { title = "诊断中", item_table = {
                { text = "search：等待中", enabled = false },
                { text = "result：等待中", enabled = false },
                { text = "catalog：等待中", enabled = false },
                { text = "content：等待中", enabled = false },
                { text = "取消诊断", callback = cancel_once },
            }, close_callback = cancel_once })
            return self:_show(progress)
        end
        dialog = construct(self.input_dialog, { title = "书源诊断", input_hint = "测试书名", input_type = "string", buttons = {
            { { text = "取消", callback = function() return self:_closeWidget(dialog) end }, { text = "开始", is_enter_default = true, callback = start } },
        } })
        return self:_showInput(dialog)
    end }
    return self:_modelMenu(view, {
        title = "兼容性报告",
        item_table = items,
    })
end

function Presenter:_settings(view)
    local values = view.values or {}
    local items = {
        { text = "请求超时：" .. tostring(values.timeout or 20) .. " 秒", enabled = false },
        { text = "并发书源：" .. tostring(values.concurrency or 2), enabled = false },
        { text = "预取章节：" .. tostring(values.prefetch or 3), enabled = false },
        { text = "每页书籍：" .. tostring(values.shelf_page or 20), enabled = false },
    }
    for _, action in ipairs(view.actions or {}) do items[#items + 1] = { text = action.text, callback = action.callback } end
    return self:_show(construct(self.menu, { title = "设置", item_table = items }))
end

function Presenter:_catalog(view)
    local items = {}
    for _, item in ipairs(view.items or {}) do
        items[#items + 1] = { text = tostring(item.index) .. ". " .. item.title .. (item.cached and " ✓" or ""), callback = function() return item.chapter end }
    end
    if #items == 0 then items[1] = { text = "目录为空", enabled = false } end
    return self:_show(construct(self.menu, { title = "目录", item_table = items }))
end

function Presenter:_detail(view)
    local items = {}
    local info = view.info
    if info then
        items[#items + 1] = { text = "作者：" .. tostring(info.author or "未知"), enabled = false }
        items[#items + 1] = { text = "简介：" .. tostring(info.intro or "暂无"), enabled = false }
        items[#items + 1] = { text = "分类：" .. tostring(info.kind or "未分类"), enabled = false }
        items[#items + 1] = { text = "最新章：" .. tostring(info.last_chapter or "未知"), enabled = false }
    elseif view.info_error then
        items[#items + 1] = { text = "详情加载失败（书源诊断）", callback = function()
            local report = type(view.compatibility) == "function" and view:compatibility() or view.compatibility
            return self:_info(diagnostic_text(view.info_error, report), "书源诊断")
        end }
    else
        items[#items + 1] = { text = "详情加载中…", enabled = false }
    end
    local actions = {
        { text = "开始阅读", callback = function() return self:_info(view:startReading()) end },
        { text = "加入书架", callback = function() return view:addToShelf() end },
        { text = "移出书架", callback = function() return view:removeFromShelf() end },
        { text = "查看目录", callback = function()
            return view:loadCatalog(function(catalog, err)
                if err then self:_info("目录加载失败，可从书源诊断查看详情", "目录")
                elseif catalog then self:show(catalog) end
            end)
        end },
        { text = "切换书源", enabled = #(view.alternatives or {}) > 1, callback = function()
            local alternatives = {}
            for index, candidate in ipairs(view.alternatives or {}) do
                alternatives[#alternatives + 1] = { text = candidate.source_name or "书源", callback = function()
                    view:switchSource(index)
                    view._presenter_info_started = nil
                    return self:_detail(view)
                end }
            end
            return self:_show(construct(self.menu, { title = "切换书源", item_table = alternatives }))
        end },
        { text = "下载整本", callback = function()
            local task, err = view:startDownload()
            if type(task) == "table" then return self:_info("已加入下载队列", "下载整本") end
            if task == nil and err ~= nil then
                return self:_info("下载任务创建失败（" .. safe_token(type(err) == "table" and err.code, "UNKNOWN_ERROR") .. "）", "下载整本")
            end
            return self:_info(tostring(task or "下载任务创建失败"), "下载整本")
        end },
    }
    for _, item in ipairs(actions) do items[#items + 1] = item end
    if not info and not view.info_error and not view._presenter_info_started and type(view.loadInfo) == "function" then
        view._presenter_info_started = true
        view:loadInfo(function(_, err)
            if err then view.info_error = err end
            self:_detail(view)
        end)
    end
    return self:_modelMenu(view, {
        title = view.book.name or "图书详情",
        item_table = items,
    })
end

local function download_items(self, view)
    local items = {}
    for _, row in ipairs(view.items or {}) do
        local task = row.task
        items[#items + 1] = { text = row.text, callback = function()
            if not view.alive then return false end
            local actions = {}
            if task.status == "queued" or task.status == "running" or task.status == "cancelling" then
                actions[#actions + 1] = { text = "取消下载", callback = function() return view:cancel(task.id) end }
            elseif task.status == "failed" or task.status == "cancelled" then
                actions[#actions + 1] = { text = "重试", callback = function() return view:retry(task.id) end }
            elseif task.status == "interrupted" then
                actions[#actions + 1] = { text = "继续下载", callback = function() return view:resume(task.id) end }
            elseif task.status == "completed" then
                actions[#actions + 1] = { text = "打开 EPUB", callback = function() return view:open(task.id) end }
            end
            if #actions == 0 then actions[1] = { text = "暂无可用操作", enabled = false } end
            return self:_show(construct(self.menu, { title = "下载操作", item_table = actions }))
        end }
    end
    if #items == 0 then items[1] = { text = "暂无下载记录", enabled = false } end
    items[#items + 1] = { text = "刷新", callback = function() return self:_downloads(view) end }
    return items
end

function Presenter:_downloads(view)
    view:refresh()
    local widget = self:_modelMenu(view, { title = "下载管理", item_table = download_items(self, view) })
    view.on_refresh = function(current)
        if not current.alive then return end
        local items = download_items(self, current)
        if type(widget._legado_prepare_items) == "function" then items = widget._legado_prepare_items(items) end
        if type(widget.switchItemTable) == "function" then
            pcall(widget.switchItemTable, widget, "下载管理", items, current.navigation:index())
        else
            widget.item_table = items
            if type(widget.updateItems) == "function" then pcall(widget.updateItems, widget) end
        end
    end
    return widget
end

function Presenter:show(view)
    if type(view) ~= "table" then return self:_info("界面不可用") end
    if view.kind == "bookshelf" then return self:_shelf(view, 1, "text") end
    if view.kind == "search" then return self:_search(view) end
    if view.kind == "source_manager" then return self:_sources(view) end
    if view.kind == "settings" then return self:_settings(view) end
    if view.kind == "catalog" then return self:_catalog(view) end
    if view.kind == "book_detail" then return self:_detail(view) end
    if view.kind == "downloads" then return self:_downloads(view) end
    if view.kind == "compatibility_report" then return self:_compatibility(view) end
    return self:_info(view.text or view.empty_text or view.error or "", view.title)
end

return Presenter
