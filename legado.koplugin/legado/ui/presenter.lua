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

function Presenter.new(options)
    options = options or {}
    return setmetatable({
        ui_manager = options.ui_manager or optional("ui/uimanager"),
        menu = options.menu or optional("ui/widget/menu"),
        info_message = options.info_message or optional("ui/widget/infomessage"),
        input_dialog = options.input_dialog or optional("ui/widget/inputdialog"),
        detail_factory = options.detail_factory,
    }, Presenter)
end

function Presenter:_show(widget)
    if self.ui_manager and type(self.ui_manager.show) == "function" then self.ui_manager:show(widget) end
    return widget
end

function Presenter:_info(text, title)
    return self:_show(construct(self.info_message, { text = text or "", title = title }))
end

function Presenter:_shelf(view, page, mode)
    local model = view:page(page or 1, mode or "text")
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
    return self:_show(construct(self.menu, { title = "书架", item_table = items, is_popout = false }))
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
    return self:_show(construct(self.menu, { title = "搜索结果", item_table = items }))
end

function Presenter:_search(view)
    local dialog
    local function submit(value)
        local keyword = value
        if (keyword == nil or keyword == "") and dialog and type(dialog.getInputText) == "function" then keyword = dialog:getInputText() end
        if type(keyword) ~= "string" or keyword:match("^%s*$") then return self:_info("请输入书名", "搜索") end
        view.onUpdate = function() if view.alive and not view.loading then self:_search_results(view) end end
        local choices = type(view.sourceChoices) == "function" and view:sourceChoices() or {}
        if #choices == 0 then return view:submit(keyword, nil, 1) end
        local items = { { text = "全部已启用书源", callback = function() return view:submit(keyword, nil, 1) end } }
        for _, source in ipairs(choices) do
            items[#items + 1] = { text = source.name, callback = function() return view:submit(keyword, { source.id }, 1) end }
        end
        return self:_show(construct(self.menu, { title = "选择搜索书源", item_table = items }))
    end
    dialog = construct(self.input_dialog, {
        title = "搜索", input_hint = "搜索书名", input_type = "string",
        buttons = { { { text = "取消", callback = function() view:close() end }, { text = "搜索", is_enter_default = true, callback = submit } } },
    })
    return self:_show(dialog)
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
            return submit(value)
        end
        dialog = construct(self.input_dialog, { title = title, input_hint = hint, input_type = "string", buttons = {
            { { text = "取消" }, { text = "确定", is_enter_default = true, callback = accepted } },
        } })
        return self:_show(dialog)
    end
    items[#items + 1] = { text = "从本地 JSON 导入", callback = function()
        return input_dialog("导入书源", "JSON 文件路径", function(path)
            local report = view:importLocal(path)
            return self:_info(report and "导入完成" or "无法读取文件", "导入书源")
        end)
    end }
    items[#items + 1] = { text = "从网址导入", callback = function()
        return input_dialog("导入书源", "HTTPS 或 HTTP 地址", function(url)
            return view:importUrl(url, function(report, err)
                self:_info(err and "远程导入失败" or "导入完成", "导入书源")
            end)
        end)
    end }
    return self:_show(construct(self.menu, { title = "书源管理", item_table = items }))
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
    local items = {
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
                    return self:_detail(view)
                end }
            end
            return self:_show(construct(self.menu, { title = "切换书源", item_table = alternatives }))
        end },
        { text = "下载整本", callback = function() return self:_info(view:startDownload()) end },
    }
    return self:_show(construct(self.menu, { title = view.book.name or "图书详情", item_table = items }))
end

function Presenter:show(view)
    if type(view) ~= "table" then return self:_info("界面不可用") end
    if view.kind == "bookshelf" then return self:_shelf(view, 1, "text") end
    if view.kind == "search" then return self:_search(view) end
    if view.kind == "source_manager" then return self:_sources(view) end
    if view.kind == "settings" then return self:_settings(view) end
    if view.kind == "catalog" then return self:_catalog(view) end
    if view.kind == "book_detail" then return self:_detail(view) end
    return self:_info(view.text or view.empty_text or view.error or "", view.title)
end

return Presenter
