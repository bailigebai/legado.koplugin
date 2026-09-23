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

local reading_stages = {
    fetch="请求网页正文", clean="整理正文", body_write="保存章节缓存", html_write="生成阅读文档",
    reader_open="打开阅读器", cache_read="读取章节缓存", catalog_read="读取目录缓存", catalog_write="保存目录缓存",
}
local reading_reasons = {
    ["书源不存在"]="书源不存在，请重新导入书源或为本书切换书源。",
    ["阅读功能尚未初始化"]="阅读功能尚未初始化，请重启 KOReader 后重试。",
    reader_ui_startup="阅读界面初始化失败，尚未确认文件损坏。请保留本页位置和本次 KOReader 日志。",
    reader_engine_open="KOReader 打开文档失败，请保留本页位置和本次 KOReader 日志，以区分文件与阅读组件问题。",
}

local function diagnostic_text(error, compatibility, reading)
    local code = safe_token(type(error) == "table" and error.code, "UNKNOWN_ERROR")
    local status = type(error) == "table" and type(error.details) == "table" and tonumber(error.details.status) or nil
    local explanation = "请求或解析失败，请检查书源配置。"
    local details = type(error) == "table" and type(error.details) == "table" and error.details or {}
    local storage_reasons = {
        full = "设备存储空间不足，请释放空间后重试。", readonly = "数据目录不可写，请检查设备连接和文件权限。",
        busy = "数据库正被占用，请稍后重试。", locked = "数据库正被占用，请稍后重试。",
        cantopen = "无法打开数据库，请检查数据目录。", ioerr = "设备读写失败，请检查存储状态。",
        corrupt = "数据库损坏，请保留原文件以便恢复。", notadb = "数据库格式异常，请保留原文件以便恢复。",
        error = "数据库执行失败，请记录本页错误代码和插件版本。",
        constraint = "数据库保存未通过检查，请记录本页错误代码和插件版本。",
    }
    if code == "STORAGE_ERROR" then
        explanation = storage_reasons[details.sqlite_code] or "本地数据读写失败，请检查存储空间和数据目录权限。"
    elseif code == "RESPONSE_TOO_LARGE" then explanation = "书源文件过大，导入上限为 5 MiB。"
    elseif code == "UNSUPPORTED_RULE" then explanation = "此规则需要尚未支持的脚本或网页能力，可返回选择其它分类或书源。"
    elseif code == "PARSE_ERROR" then explanation = reading and "网页正文或目录无法按当前书源规则解析，可重试或切换书源。"
        or "内容不是有效的书源 JSON，请检查网址是否返回了网页或错误提示。" end
    if reading and details.stage == "reader_open" then
        explanation = "KOReader 未能打开生成的阅读文档，请重试并确认使用当前插件版本。"
    elseif reading and details.stage == "html_write" then
        explanation = "生成本地阅读文档失败，请检查剩余空间和数据目录写入权限。"
    end
    if reading and reading_reasons[details.reason] then explanation=reading_reasons[details.reason] end
    local lines = { "错误代码：" .. code, "说明：" .. explanation }
    if reading and reading_stages[details.stage] then lines[#lines+1] = "阶段："..reading_stages[details.stage] end
    if reading and type(details.location)=='string' and details.location:match('^[%w_%-]+%.lua:%d+$') then
        lines[#lines+1] = "位置："..details.location
    end
    if code == "STORAGE_ERROR" then
        if details.operation == "read" then lines[#lines + 1] = "阶段：读取本地数据库"
        elseif details.operation == "write" then lines[#lines + 1] = "阶段：保存本地数据库" end
        if storage_reasons[details.sqlite_code] then lines[#lines + 1] = "数据库代码：" .. details.sqlite_code end
    end
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
        app = options.app, cover_loader = options.cover_loader,
        library_screen_factory = options.library_screen_factory or function(opts) return require("legado.ui.library_screen").new(opts) end,
        controllers = {},
        cover_grid_factory = options.cover_grid_factory or function(grid_options) return require("legado.ui.cover_grid").new(grid_options) end,
        closed_widgets = setmetatable({}, { __mode = "k" }),
        keyboard_widgets = setmetatable({}, { __mode = "k" }),
        view_widgets = setmetatable({}, { __mode = "k" }),
        owned_widgets = setmetatable({}, { __mode = "k" }),
        reader_resume_checks = setmetatable({}, { __mode = "k" }),
    }, Presenter)
end

function Presenter:_independentReader()
    local session=self.app and self.app.reader_session
    local document=session and (session.active and session.active.document or session.ui and session.ui.current_document)
    if document and document.backend=='immersive' and not document.closed then return document end
end

function Presenter:_resumeReaderWhenVisible(document)
    if not document or self.reader_resume_checks[document] then return end
    local ui=self.ui_manager
    if not ui or not ui.scheduleIn or not ui.getTopmostVisibleWidget then return end
    local function check()
        self.reader_resume_checks[document]=nil
        if self:_independentReader()==document and ui:getTopmostVisibleWidget()==document.widget then
            document:resumeReading()
        end
    end
    self.reader_resume_checks[document]=check
    -- KOReader sends CloseWidget before removing the widget from its window stack.
    ui:scheduleIn(0,check)
end

function Presenter:_ownWidget(widget,document)
    document=document or self:_independentReader()
    if not document or document.closed or document.backend~='immersive' or widget==document.widget then return widget end
    local paused,err=document:pauseReading()
    if not paused then return nil,err end
    local owned=self.owned_widgets[widget]
    if not owned then
        owned={};self.owned_widgets[widget]=owned
        local original=widget.onCloseWidget
        widget.onCloseWidget=function(instance,...)
            owned.closed=true
            local ok,result=true,nil
            if original then ok,result=pcall(original,instance,...) end
            self:_resumeReaderWhenVisible(owned.document)
            if not ok then error(result,0) end
            return result
        end
    end
    owned.document,owned.closed=document,false
    self.closed_widgets[widget]=nil
    return widget
end

function Presenter:_show(widget)
    local ok,owned,err=pcall(self._ownWidget,self,widget)
    if not ok then return nil,{code='UI_ERROR',message='插件页面初始化失败：'..tostring(owned)} end
    if not owned then return nil,err end
    if widget.item_table and not widget.close_callback then
        widget.close_callback = function() return self:_closeWidget(widget) end
    end
    if self.ui_manager and type(self.ui_manager.show) == "function" then
        local shown,show_error=pcall(self.ui_manager.show,self.ui_manager,widget)
        if not shown then
            self.closed_widgets[widget]=true
            return nil,{code='UI_ERROR',message='插件页面显示失败：'..tostring(show_error)}
        end
    end
    if widget.kind == "library_screen" and self.ui_manager and type(self.ui_manager.setDirty) == "function" then
        self.ui_manager:setDirty(nil, "full")
    end
    return widget
end

function Presenter:_closeWidget(widget)
    if widget == nil or self.closed_widgets[widget] then return false end
    self.closed_widgets[widget] = true
    local owned=self.owned_widgets[widget]
    if self.ui_manager and type(self.ui_manager.close) == "function" and not (owned and owned.closed) then
        local ok=pcall(self.ui_manager.close,self.ui_manager,widget)
        if not ok then return false end
    end
    return true
end

function Presenter:showNativeStatistics(statistics,document)
    document=document or self:_independentReader()
    if document and document.backend=='immersive' then
        local paused,err=document:pauseReading();if not paused then return nil,err end
    end
    local wrapped=setmetatable({}, {__mode='k'})
    local watch
    local function callbacks(object)
        if type(object)~='table' then return end
        local seen=wrapped[object] or {};wrapped[object]=seen
        for _,key in ipairs{'callback','callback_return'} do
            local original=object[key]
            if type(original)=='function' and seen[key]~=original then
                local handler=function(...)
                    local ok,result,err=pcall(original,...)
                    watch()
                    if not ok then return self:_info('KOReader 阅读统计暂不可用。','阅读统计') end
                    return result,err
                end
                object[key],seen[key]=handler,handler
            end
        end
    end
    watch=function()
        local widget=statistics.kv
        if type(widget)~='table' then return end
        self:_ownWidget(widget,document)
        callbacks(widget)
        for _,row in ipairs(widget.kv_pairs or {}) do callbacks(row) end
        return widget
    end
    local ok,result=pcall(statistics.onShowTimeRange,statistics)
    if not ok then return self:_info('KOReader 阅读统计暂不可用。','阅读统计') end
    return watch() or result
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
    local widget
    local wrapped = setmetatable({}, { __mode = "k" })
    local function prepare(items)
        for _, item in ipairs(items or {}) do
            if type(item.callback) == "function" and not wrapped[item] then
                local callback = item.callback
                item.callback = function(...)
                    selected = true
                    local ok, result = pcall(callback, ...)
                    if not ok then return false end
                    return result
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
        if selected then selected = false; self:_closeWidget(widget); return false end
        if closed then return false end
        closed = true
        return close_model()
    end
    widget = construct(self.menu, options)
    widget._legado_prepare_items = prepare
    self:_closeWidget(self.view_widgets[view])
    self.view_widgets[view] = widget
    return self:_show(widget)
end

function Presenter:_info(text, title)
    local widget=construct(self.info_message, { text = text or "", title = title })
    local shown=self:_show(widget)
    -- A failed pause/save must not hide the error explaining that failure.
    if not shown and self.ui_manager and self.ui_manager.show then self.ui_manager:show(widget) end
    return shown or widget
end

local function close_view(view)
    if view and type(view.close) == "function" then view:close()
    elseif view and type(view.cancel) == "function" then view:cancel() end
end

function Presenter:_hideLibrary()
    local widget = self.library_widget
    self.library_widget = nil
    if widget then
        if type(widget.closeForReplacement) == "function" then self.closed_widgets[widget] = true; widget:closeForReplacement()
        else self:_closeWidget(widget) end
    end
end

function Presenter:_ensureBackdrop()
    if self:_independentReader() then return end
    if self.backdrop or not self.app or not self.app.storage then return end
    local FileManager=optional('apps/filemanager/filemanager')
    local chooser=FileManager and FileManager.instance and FileManager.instance.file_chooser
    self.return_path=chooser and chooser.path or self.return_path
        or (G_reader_settings and G_reader_settings:readSetting('home_dir')) or '/mnt/us/documents'
    self.backdrop=self.library_screen_factory{title='Legado · 书源阅读',compact=true,items={},navigation={},
        ui_manager=self.ui_manager,secondary=true,empty_text='正在切换页面，请稍候…',
        actions={{text='回到书架',callback=function() return self.app:openBookshelf() end}},
        on_request_close=function() self:_confirmExit();return true end}
    self.backdrop.name='LegadoBackground'
    self:_show(self.backdrop)
end

function Presenter:_confirmExit()
    if self.exit_dialog and not self.closed_widgets[self.exit_dialog] then return end
    local Confirm=optional('ui/widget/confirmbox')
    if not Confirm then return self:_info('无法打开退出确认，请先留在书架。') end
    local dialog
    dialog=Confirm:new{text='退出 Legado 书源阅读，返回 KOReader？',ok_text='退出',cancel_text='留在书架',
        ok_callback=function()
            if self.app.reader_session then
                local saved,err=self.app.reader_session:close()
                if not saved then return self:_info(diagnostic_text(err),'阅读进度保存失败') end
                self.app.reader_mode_request=nil
            end
            self:_closeWidget(dialog)
            self:_leaveLibrary()
            local FileManager=optional('apps/filemanager/filemanager')
            if FileManager then
                if FileManager.instance then
                    local chooser=FileManager.instance.file_chooser
                    if chooser and chooser.changeToPath then chooser:changeToPath(self.return_path) end
                elseif FileManager.showFiles then FileManager:showFiles(self.return_path) end
            end
            local background=self.backdrop;self.backdrop=nil
            if background then background:closeForReplacement() end
        end,
        cancel_callback=function() self.closed_widgets[dialog]=true;self.exit_dialog=nil end}
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(instance,...)
        if on_close then on_close(instance,...) end
        self.closed_widgets[dialog]=true;self.exit_dialog=nil
    end
    self.exit_dialog=dialog
    return self:_show(dialog)
end

function Presenter:_leaveLibrary(keep)
    self:_hideLibrary()
    for view in pairs(self.controllers) do if view ~= keep then close_view(view) end end
    self.controllers, self.library_view, self.library_subpage = {}, nil, nil
end

function Presenter:_navigation()
    local items = {}
    if self.app then
        for _,entry in ipairs({{"书架", "openBookshelf"}, {"阅读回顾", "openReadingReview"}, {"发现", "openDiscovery"}}) do
            items[#items+1] = {text=entry[1], callback=function() return self.app[entry[2]](self.app) end}
        end
    end
    return items
end

function Presenter:_library(view, options)
    self:_ensureBackdrop()
    self.library_view = view
    self.library_subpage = options.subpage
    self.controllers[view] = true
    local display = {}
    for key,value in pairs(options) do display[key] = value end
    display.ui_manager, display.compact = self.ui_manager, true
    local covers_enabled = view.covers_enabled ~= false
        and (not self.app or not self.app.settings or self.app.settings:get("covers_enabled") ~= false)
    display.cover_loader = covers_enabled and (self.cover_loader or (self.app and self.app.cover_loader) or view.cover_loader) or nil
    display.navigation = options.navigation or self:_navigation()
    local local_back = options.on_back
    local back = local_back or view._back
    if not back and (view.kind=='bookshelf' or view.kind=='home') then
        display.on_request_close=function() self:_confirmExit();return true end
    end
    display.on_back = function()
        self:_hideLibrary()
        if not local_back then self.controllers[view] = nil; close_view(view) end
        if back then return back() end
        if self.app then return self.app:openBookshelf() end
        return self:_leaveLibrary()
    end
    display.on_close = display.on_back
    display.on_error=function(err)
        local location=type(err)=='string' and err:match('([%w_%-]+%.lua:%d+)') or nil
        return self:_info('操作未完成，已保留当前页面。'..(location and ('\n位置：'..location) or ''),'Legado')
    end
    local all, page = options.items or {}, math.max(1, options.page or 1)
    local size = options.page_size or (options.mode == "detail" and 1 or options.mode == "grid" and 12 or options.mode == "cards" and 3 or 8)
    local pages = options.already_paginated and math.max(1, options.page_count or 1) or math.max(1, math.ceil(#all / size))
    page = math.min(page, pages)
    local slice = {}
    if options.already_paginated then slice = all
    else for i=(page-1)*size+1, math.min(page*size,#all) do slice[#slice+1]=all[i] end end
    local original_prev, original_next = options.on_prev, options.on_next
    local function render(p)
        if view.kind == "search" then view.result_page = p end
        local next_options = {}
        for key,value in pairs(options) do next_options[key] = value end
        next_options.page = p
        return self:_library(view, next_options)
    end
    display.items, display.page, display.page_count = slice, page, pages > 1 and pages or nil
    display.on_prev = not options.already_paginated and page > 1 and function() return render(page-1) end or original_prev
    display.on_next = not options.already_paginated and page < pages and function() return render(page+1) end or original_next
    if not options.secondary then
        local primary, more = {}, {}
        for index,action in ipairs(options.actions or {}) do
            if index == 1 then primary[1] = action else more[#more+1] = action end
        end
        if view.kind=='bookshelf' or view.kind=='home' then
            more[#more+1]={text='检查更新',callback=function() return self:_checkUpdates(view) end}
            more[#more+1]={text='编辑分类',callback=function() return self:_editCategories(function()
                if view.kind=='home' then return self:_home(view) end
                return self:_shelf(view,1)
            end) end}
            if view.kind == 'bookshelf' then
                if view.batch_select then
                    more[#more+1] = {text='批量分类',callback=function()
                        local selected = {}
                        local selected_count = 0
                        for id, enabled in pairs(view.selected_books or {}) do
                            if enabled then selected[id] = true; selected_count = selected_count + 1 end
                        end
                        if selected_count == 0 then return self:_info('请先选择要分类的书籍。', '批量分类') end
                        local books = {}
                        for _, book in ipairs(view.storage and view.storage.listShelf and view.storage:listShelf() or {}) do
                            if selected[book.id] then
                                local copy = {}
                                for key, value in pairs(book) do
                                    if key == 'custom_categories' and type(value) == 'table' then
                                        copy[key] = {}
                                        for index, name in ipairs(value) do copy[key][index] = name end
                                    else copy[key] = value end
                                end
                                books[#books + 1] = copy
                            end
                        end
                        return self:_editCategories(function() return self:_shelf(view, page) end, nil, books)
                    end}
                    more[#more+1] = {text='退出批量选择',callback=function()
                        view.batch_select, view.selected_books = false, {}
                        return self:_shelf(view, page)
                    end}
                else
                    more[#more+1] = {text='批量选择',callback=function()
                        view.batch_select, view.selected_books = true, view.selected_books or {}
                        return self:_shelf(view, page)
                    end}
                end
            end
        end
        if self.app then
            for _,entry in ipairs({{"阅读回顾","openReadingReview"},{"书源管理","openSources"},{"下载管理","openDownloads"},{"设置","openSettings"},{"关于","openAbout"}}) do
                if type(self.app[entry[2]]) == "function" then
                    more[#more+1] = {text=entry[1],callback=function() return self.app[entry[2]](self.app) end}
                end
            end
        end
        if #more > 0 then
            primary[#primary+1] = {text="更多",callback=function()
                return self:_library(view,{title="更多操作",items=more,subpage="more",secondary=true,
                    on_back=function()
                        if view.kind == "book_detail" then return self:_detail(view) end
                        if view.kind == "search" then return self:_search_results(view) end
                        if view.kind == "bookshelf" then return self:_shelf(view,page) end
                        return render(page)
                    end})
            end}
        end
        display.actions = primary
    end
    local widget = self.library_screen_factory(display)
    self:_show(widget)
    self:_hideLibrary()
    self.library_widget, self.view_widgets[view] = widget, widget
    return widget
end

function Presenter:_bookItem(book, alternatives, back)
    return {book=book, title=book.name or "未命名书籍", subtitle=book.author,
        intro=book.intro, cover_url=book.cover_url, source_count=#(alternatives or {book}),
        callback=function()
            local parent = self.library_view
            if parent and type(parent.cancel) == "function" then parent:cancel() end
            if not self.detail_factory then return book end
            local detail = self.detail_factory(book, alternatives or {book})
            detail._source_books = alternatives or {book}
            detail._back = back
            return self:_detail(detail)
        end}
end

function Presenter:_home(view)
    local model, items = view:page(), {}
    for _,book in ipairs(model.recent or {}) do
        items[#items+1] = self:_bookItem(book, {book}, function() return self:_home(view) end)
    end
    local actions = {}
    for _,action in ipairs(model.actions or {}) do
        if action.text == "搜索" then actions[#actions+1]={text="搜索添加",callback=action.callback}
        elseif action.text == "下载管理" or action.text == "设置" then actions[#actions+1]=action end
    end
    return self:_library(view, {title="书源阅读", subtitle="最近阅读 · 独立图书库", items=items, mode="cards",
        actions=actions, navigation=self.app and self:_navigation() or model.actions,
        empty_text="还没有最近阅读的书，搜索书名即可从各书源找书。"})
end

function Presenter:_shelf(view, page)
    -- The screen owns cover requests; shelf storage remains the plugin's SQLite library.
    local model = view:page(page or 1, "text", 12)
    local items = {}
    for _,item in ipairs(model.items or {}) do
        local book_item=self:_bookItem(item.book, {item.book}, function() return self:_shelf(view,model.page) end)
        book_item.subtitle,book_item.intro,book_item.source_count=nil,nil,nil
        if view.batch_select then
            local selected = view.selected_books and view.selected_books[item.book.id] == true
            book_item.title = (selected and '✓ ' or '□ ') .. book_item.title
            book_item.callback = function()
                view.selected_books = view.selected_books or {}
                view.selected_books[item.book.id] = not view.selected_books[item.book.id]
                return self:_shelf(view,model.page)
            end
        end
        items[#items+1]=book_item
    end
    local categories={}
    for _,entry in ipairs({{"全部","all"},{"在读","reading"},{"未读","unread"}}) do
        categories[#categories+1]={text=entry[1],active=(model.reading_state or "all")==entry[2],callback=function()
            view:setFilter(entry[2],view.category)
            return self:_shelf(view,1)
        end}
    end
    categories[#categories+1]={text=model.category or "分类",active=model.category~=nil,callback=function()
        local choices={{title="全部分类",callback=function() view:setFilter(view.reading_state,nil); return self:_shelf(view,1) end}}
        for _,category in ipairs(model.categories or {}) do
            choices[#choices+1]={title=category.name,subtitle=tostring(category.count).." 本",callback=function()
                view:setFilter(view.reading_state,category.name)
                return self:_shelf(view,1)
            end}
        end
        return self:_library(view,{title="书架分类",items=choices,secondary=true,subpage="shelf_categories",
            on_back=function() return self:_shelf(view,model.page) end})
    end}
    local local_mode=view.source_mode=='local'
    local subtitle = model.warning or (tostring(model.total or #items)..' 本'..(local_mode and '本地书籍' or '收藏'))
    if view.batch_select then
        local selected_count = 0
        for _, enabled in pairs(view.selected_books or {}) do if enabled then selected_count = selected_count + 1 end end
        subtitle = subtitle .. ' · 已选 ' .. tostring(selected_count) .. ' 本'
    end
    return self:_library(view,{title=local_mode and '本地书架' or '书架',subtitle=subtitle,items=items,mode="grid",
        header_action={text=local_mode and '书源书架' or '本地书架',callback=function()
            view.source_mode=local_mode and 'sources' or 'local'; view:setFilter('all',nil)
            return self:_shelf(view,1)
        end},
        grid_columns=4,grid_rows=3,categories=categories,already_paginated=true,page=model.page,page_count=model.page_count,
        batch_select=view.batch_select, selected_books=view.selected_books, storage=view.storage,
        actions={{text=local_mode and '添加目录' or '搜索添加',callback=local_mode and function()
            if self.app then return self.app:openSettings() end
        end or view.on_search or function() if self.app then return self.app:openSearch() end end}},
        on_prev=model.page>1 and function() return self:_shelf(view,model.page-1) end or nil,
        on_next=model.page<model.page_count and function() return self:_shelf(view,model.page+1) end or nil,
        empty_text=local_mode and '还没有本地书籍，点击“添加目录”选择存放小说的文件夹。' or (model.category or (model.reading_state and model.reading_state~="all"))
            and "这个分类还没有书，可切换分类或搜索添加。" or "书架还是空的，点击“搜索添加”收藏第一本书。"})
end

function Presenter:_search_results(view)
    local items, actions = {}, {}
    for _,group in ipairs(view.results or {}) do
        items[#items+1]=self:_bookItem(group.book,group.alternatives,function() return self:_search_results(view) end)
    end
    local progress = view.progress or {}
    local status = string.format("已找到 %d 本 · 完成 %d/%d 书源",#items,progress.completed or 0,progress.total or 0)
    if view.explore_source then status="分类第 "..tostring(view.page or 1).." 页 · "..#items.." 本" end
    if view.loading then
        status=status.." · "..(view.explore_source and "加载中…" or "搜索中…")
        actions[#actions+1]={text="停止",callback=function() view:cancel(); return self:_search_results(view) end}
    elseif view.cancelled then status=status.." · 已停止" end
    if view.error then status=status.." · "..safe_token(view.error.code,"REQUEST_ERROR") end
    if #(view.errors or {})>0 then
        status=status.." · 失败 "..#view.errors
        actions[#actions+1]={text="失败详情",callback=function()
            local failures={}
            for _,err in ipairs(view.errors) do failures[#failures+1]={title=(err.source_name or "书源").." · "..safe_token(err.code,"REQUEST_ERROR"),enabled=false} end
            return self:_library(view,{title="搜索诊断",items=failures,subpage="search_diagnostics",on_back=function() return self:_search_results(view) end})
        end}
    end
    if not view.loading then actions[#actions+1]={text="重试",callback=function() return self:_runSearch(view,view.keyword,view.source_ids,view.page or 1) end} end
    if self.app then actions[#actions+1]={text="搜索书名",callback=function() return self.app:openSearch() end} end
    local empty = view.loading and "正在各书源查找，找到后会自动显示封面和简介。" or "未找到匹配书籍，可换个书名或检查已启用的书源。"
    if view.error then empty=diagnostic_text(view.error) end
    return self:_library(view,{title=view.explore_source and (view.title or "分类图书") or ("搜索 · "..tostring(view.keyword or "")),
        subtitle=status,items=items,mode="cards",subpage="search_results",actions=actions,empty_text=empty,page=view.result_page,
        on_prev=not view.loading and (view.page or 1)>1 and function() return self:_runSearch(view,view.keyword,view.source_ids,view.page-1) end or nil,
        on_next=not view.loading and view.has_more and function() return self:_runSearch(view,view.keyword,view.source_ids,view.page+1) end or nil})
end

function Presenter:_runSearch(view, keyword, ids, page)
    if view.alive == false or view.loading then return false end
    self.library_view, view.result_page = view, 1
    local submitting, scheduled = true, false
    view.onUpdate = function()
        if submitting or view.alive == false or self.library_view ~= view then return end
        if self.ui_manager and type(self.ui_manager.scheduleIn) == "function" then
            if scheduled then return end
            scheduled = true
            self.ui_manager:scheduleIn(6, function()
                scheduled = false
                if view.alive ~= false and self.library_view == view and self.library_subpage == "search_results" then self:_search_results(view) end
            end)
        elseif self.library_subpage == "search_results" then self:_search_results(view) end
    end
    view:submit(keyword,ids,page or 1)
    submitting = false
    return self:_search_results(view)
end

function Presenter:_search(view)
    if view.initial_keyword then
        local keyword = view.initial_keyword
        view.initial_keyword = nil
        return self:_runSearch(view, keyword, nil, 1)
    end
    local dialog
    local function submit(value)
        local keyword=value
        if (keyword==nil or keyword=="") and dialog and type(dialog.getInputText)=="function" then keyword=dialog:getInputText() end
        if type(keyword)~="string" or keyword:match("^%s*$") then return self:_info("请输入书名","搜索") end
        if not self:_closeWidget(dialog) then return false end
        return self:_runSearch(view,keyword,nil,1)
    end
    dialog=construct(self.input_dialog,{title="搜索全部启用书源",input_hint="搜索书名",input_type="string",
        buttons={{{text="取消",callback=function() if not self:_closeWidget(dialog) then return false end; close_view(view); if self.app then return self.app:openHome() end end},
            {text="搜索",is_enter_default=true,callback=submit}}}})
    return self:_showInput(dialog)
end

function Presenter:_categories(view, source)
    local categories,err=view.service:exploreCategories(source)
    local items={}
    for index,category in ipairs(categories or {}) do
        items[#items+1]={title=category.title..(category.error and " · 当前不支持" or ""),
            subtitle=category.error and safe_token(category.error.code,"UNSUPPORTED_RULE") or nil,
            enabled=category.url~=nil and category.error==nil,
            callback=function()
                if category.error or not category.url then return false end
                local search=require("legado.ui.search").new({service=view.service,explore_source=source.id or source.bookSourceUrl,category_index=index,title=category.title})
                search._back=function() return self:_categories(view,source) end
                return self:_runSearch(search,nil,nil,1)
            end}
    end
    return self:_library(view,{title=source.bookSourceName or "站点分类",subtitle=err and "该书源的分类规则暂不支持" or "选择分类查看图书",
        items=items,empty_text=err and diagnostic_text(err) or "此书源未提供分类。可以通过搜索书名查找。",
        actions=self.app and {{text="搜索书名",callback=function() return self.app:openSearch() end}} or {},
        on_back=function() return self:_discovery(view) end})
end

function Presenter:_discovery(view)
    local items={}
    for _,source in ipairs(view.sources or {}) do
        if source.enabled~=false and source.enabledExplore~=false then
            local has_categories = (type(source.exploreUrl)=="string" and source.exploreUrl:match("%S")) or type(source.exploreUrl)=="table"
            items[#items+1]={title=source.bookSourceName or "书源",subtitle=has_categories and "查看站点分类" or "未提供分类，可搜索书名",
                callback=function() return self:_categories(view,source) end}
        end
    end
    return self:_library(view,{title="发现",subtitle="站点 → 分类 → 图书",items=items,
        empty_text=view.empty_text or "暂无启用的站点，请到书源管理导入或启用书源。"})
end

local function import_summary(report, err)
    if err or not report or report.error or (report.rejected or 0) > 0 then
        return "导入失败\n" .. diagnostic_text(err or (report and report.error))
    end
    local counts = { usable = 0, partial = 0, unsupported = 0 }
    for _, result in ipairs(report.compatibility or {}) do
        if counts[result.status] then counts[result.status] = counts[result.status] + 1 end
    end
    local text = string.format("导入完成：新增 %d，更新 %d\n初步兼容 %d，部分兼容 %d，不支持 %d",
        report.imported or 0, report.updated or 0, counts.usable, counts.partial, counts.unsupported)
    if #(report.warnings or {}) > 0 then text = text .. "\n警告：HTTP 地址不安全" end
    return text
end

function Presenter:_sources(view)
    local model = type(view.viewModel) == "function" and view:viewModel() or { sources = view:list() }
    local items, imports = {}, {}
    for _, source in ipairs(model.sources or {}) do
        local status = source.enabled == false and "已停用" or "已启用"
        local group = tostring(source.bookSourceGroup or "")
        items[#items + 1] = { title = tostring(source.bookSourceName or "未命名书源"),
            subtitle = "收藏 " .. tostring(source.shelf_count or 0) .. " · " .. status .. (group ~= "" and (" · " .. group) or ""), callback = function()
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
                        self:_info(import_summary(result, err), "更新书源")
                    end)
                end },
                { text = "删除书源", callback = function() local deleted = view:delete(source.id); if deleted == true then return self:_sources(view) end; return deleted end },
            }
            return self:_library(view, { title = tostring(source.bookSourceName or "书源"), items = actions, on_back = function() return self:_sources(view) end })
        end }
    end
    if #items == 0 then
        items[1] = { text = model.empty_text or "暂无书源", enabled = false }
        for _, action in ipairs(model.empty_actions or {}) do
            if type(action.callback) == "function" then items[#items + 1] = action end
        end
    end
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
    imports[#imports + 1] = { text = "从本地 JSON 导入", callback = function()
        return input_dialog("导入书源", "JSON 文件路径", function(path)
            local report = view:importLocal(path)
            self:_sources(view)
            return self:_info(import_summary(report), "导入书源")
        end)
    end }
    imports[#imports + 1] = { text = "从网址导入", callback = function()
        return input_dialog("导入书源", "HTTPS 或 HTTP 地址", function(url)
            return view:importUrl(url, function(report, err)
                self:_sources(view)
                self:_info(import_summary(report, err), "导入书源")
            end)
        end)
    end }
    local subtitle = "已导入 " .. tostring(#(model.sources or {})) .. " 个书源"
    return self:_library(view, { title = "书源管理", subtitle = subtitle, items = items, actions = imports })
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
            local function cancel_once(close_widget)
                if closed or completed then return false end
                closed = true
                if type(view.cancel) == "function" then
                    pcall(view.cancel, view)
                elseif handle and type(handle.cancel) == "function" then
                    pcall(handle.cancel, handle)
                end
                if close_widget and progress then self:_closeWidget(progress) end
                return true
            end
            progress = construct(self.menu, { title = "诊断中", item_table = {
                { text = "search：等待中", enabled = false },
                { text = "result：等待中", enabled = false },
                { text = "catalog：等待中", enabled = false },
                { text = "content：等待中", enabled = false },
                { text = "取消诊断", callback = function() return cancel_once(true) end },
            }, close_callback = function() return cancel_once(false) end })
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

function Presenter:_settingsRecoveryItems(view, redraw, warning)
    local status = type(view.status) == "function" and view:status() or {}
    if not status.recovery_required then return {} end
    local items = { { text = warning or "设置文件损坏，普通保存已锁定", enabled = false } }
    items[#items + 1] = { text = "重试读取", callback = function()
        local retried, err = view:retryRecovery()
        if not retried then
            return self:_info("设置文件仍无法读取（" .. safe_token(type(err) == "table" and err.code, "RECOVERY_REQUIRED") .. "）", "设置恢复")
        end
        if redraw then return redraw() end
        return self:_info("设置文件已重新读取", "设置恢复")
    end }
    items[#items + 1] = { text = "备份后重置", callback = function()
        local dialog
        local function reset(value)
            if (value == nil or value == "") and dialog and type(dialog.getInputText) == "function" then value = dialog:getInputText() end
            if value ~= "重置" then return self:_info("请输入“重置”以确认", "设置恢复") end
            if not self:_closeWidget(dialog) then return false end
            local backup, err = view:resetCorrupt()
            if not backup then
                return self:_info("设置重置失败（" .. safe_token(type(err) == "table" and err.code, "STORAGE_ERROR") .. "）", "设置恢复")
            end
            return self:_info("设置已重置，备份：" .. tostring(backup), "设置恢复")
        end
        dialog = construct(self.input_dialog, { title = "备份后重置设置", input_hint = "输入“重置”确认",
            input_type = "string", buttons = { { { text = "取消", callback = function() return self:_closeWidget(dialog) end },
                { text = "确认重置", is_enter_default = true, callback = reset } } } })
        return self:_showInput(dialog)
    end }
    return items
end

function Presenter:_readerProgressSettings(view, back)
    local values = view:refresh()
    local names = {hidden='隐藏',bar='仅进度条',details='进度条＋章节百分比和时间'}
    local widget
    local function save(key,value)
        local saved,err=view:set(key,value)
        if saved==nil then return self:_info('设置保存失败（'..safe_token(err and err.code,'STORAGE_ERROR')..'）') end
        self:_readerProgressSettings(view,back)
        if view.footer_unavailable then return self:_info('KOReader 已整体停用底部状态栏，请先在原生阅读设置中启用状态栏。') end
    end
    local modes,fonts,heights,items={},{},{},{}
    for _, item in ipairs(self:_settingsRecoveryItems(view, function() return self:_readerProgressSettings(view, back) end)) do
        items[#items + 1] = item
    end
    for _,mode in ipairs({'hidden','bar','details'}) do
        modes[#modes+1]={text=names[mode],checked_func=function() return view.values.progress_bar_mode==mode end,
            callback=function() return save('progress_bar_mode',mode) end}
    end
    for size=8,22,2 do
        fonts[#fonts+1]={text=tostring(size),checked_func=function() return view.values.progress_bar_font_size==size end,
            callback=function() return save('progress_bar_font_size',size) end}
    end
    for _,height in ipairs({16,20,24,28,32,40,48}) do
        heights[#heights+1]={text=tostring(height),checked_func=function() return view.values.progress_bar_height==height end,
            callback=function() return save('progress_bar_height',height) end}
    end
    self:_closeWidget(self.settings_widget)
    items[#items + 1] = {text='阅读进度：'..(values.progress_bar == false and '停用' or '启用'),callback=function()
        return save('progress_bar',values.progress_bar == false)
    end}
    items[#items + 1] = {text='显示：'..(names[values.progress_bar_mode] or names.details),sub_item_table=modes}
    items[#items + 1] = {text='百分比和时间字号：'..tostring(values.progress_bar_font_size or 12),sub_item_table=fonts}
    items[#items + 1] = {text='最小栏高：'..tostring(values.progress_bar_height or 24),sub_item_table=heights}
    items[#items + 1] = {text='时间为本章预计剩余阅读时间',enabled=false}
    items[#items + 1] = {text='字号较大时自动撑高，避免遮挡',enabled=false}
    widget=construct(self.menu,{title='底部进度栏',item_table=items,close_callback=function()
        if not self:_closeWidget(widget) then return false end
        if back then return back() end
    end})
    self.settings_widget=widget
    return self:_show(widget)
end

function Presenter:_readerChromeSettings(view, back)
    local names = {time='时间',title='书名',chapter_page='本章当前页 / 总页数',chapter='当前章节',progress='小说进度',off='关闭'}
    local positions = {{'tl','左上'},{'tc','顶部居中'},{'tr','右上'},{'bl','左下'},{'br','右下'}}
    local items,widget = {}
    for _, item in ipairs(self:_settingsRecoveryItems(view, function() return self:_readerChromeSettings(view, back) end)) do
        items[#items + 1] = item
    end
    for _,entry in ipairs(positions) do
        local key,choices = 'reader_corner_'..entry[1],{}
        for _,value in ipairs({'time','title','chapter_page','chapter','progress','off'}) do
            choices[#choices+1] = {text=names[value],checked_func=function() return view.values[key]==value end,
                callback=function()
                    local saved,err=view:set(key,value)
                    if saved==nil then return self:_info('设置保存失败（'..safe_token(err and err.code,'STORAGE_ERROR')..'）') end
                    self:_closeWidget(widget)
                    return self:_readerChromeSettings(view,back)
                end}
        end
        items[#items+1] = {text=entry[2]..'：'..(names[view.values[key]] or '关闭'),sub_item_table=choices}
    end
    for _,entry in ipairs{{'reader_header_font_size','页眉字号'},{'reader_footer_font_size','页脚字号'}} do
        local choices={}
        for _,size in ipairs{8,9,10,11,12,14,16,18} do
            choices[#choices+1]={text=tostring(size),callback=function()
                local saved,err=view:set(entry[1],size)
                if not saved then return self:_info(diagnostic_text(err)) end
                return self:_readerChromeSettings(view,back)
            end}
        end
        items[#items+1]={text=entry[2]..'：'..tostring(view.values[entry[1]] or 12),sub_item_table=choices}
    end
    items[#items+1]={text='底部进度栏',callback=function()
        return self:_readerProgressSettings(view,function() return self:_readerChromeSettings(view,back) end)
    end}
    self:_closeWidget(self.settings_widget)
    widget=construct(self.menu,{title='页眉页脚设置',item_table=items,close_callback=function()
        if not self:_closeWidget(widget) then return false end
        if back then return back() end
        if self.ui_manager and self.ui_manager.setDirty then self.ui_manager:setDirty(nil,'ui') end
    end})
    self.settings_widget=widget
    return self:_show(widget)
end

function Presenter:_checkUpdates(view)
    local app=self.app
    if not app or not app.service or not app.service.checkUpdates then return self:_info('更新服务尚未就绪。') end
    local books,err=app.storage:listShelf()
    if not books then return self:_info(diagnostic_text(err)) end
    local menu,handle,timer,closed,done
    local report={total=#books,checked=0,updated=0,failed=0}
    local function draw()
        timer=nil
        if closed then return end
        local title=done and '检查更新完成' or '正在检查更新'
        local items={{text=string.format('已检查 %d / %d',report.checked,report.total),enabled=false},
            {text=string.format('有更新 %d 本 · 失败 %d 本',report.updated,report.failed),enabled=false}}
        if menu.switchItemTable then menu:switchItemTable(title,items,1)
        else menu.title,menu.item_table=title,items;if menu.updateItems then menu:updateItems() end end
        if self.ui_manager.setDirty then self.ui_manager:setDirty(menu,'ui') end
    end
    local function cancel_timer()
        if timer and self.ui_manager.unschedule then self.ui_manager:unschedule(timer) end
        timer=nil
    end
    menu=construct(self.menu,{title='正在检查更新',item_table={{text='正在读取书架…',enabled=false}},close_callback=function()
        if closed then return end
        closed=true;cancel_timer()
        if handle and handle.cancel then handle:cancel() end
        self:_closeWidget(menu)
        if view.kind=='home' then return self:_home(view) end
        return self:_shelf(view,1)
    end})
    self:_show(menu)
    local ok,result=pcall(app.service.checkUpdates,app.service,books,function(value)
        if closed then return end
        report,done=value,true;cancel_timer();draw()
    end,function(value)
        if closed then return end
        report=value
        if not timer and self.ui_manager.scheduleIn then timer=draw;self.ui_manager:scheduleIn(6,timer) end
    end)
    if not ok or not result then
        done=true;cancel_timer()
        if not closed then self:_info('更新检查未能启动；书架已保留。') end
    else handle=result end
    return menu
end

function Presenter:showLicenseDialog(continuation)
    local license = self.app and self.app.license
    if not license then return self:_info("授权服务尚未初始化。", "需要授权") end
    if license:isAuthorized() then return continuation and continuation() or true end
    local dialog, attempt, closed
    local messages = {
        invalid_key = "短密钥格式无效。",
        key_not_found = "没有找到该密钥，请核对后重试。",
        bound_to_other_device = "该密钥已绑定其他设备。",
        wrong_device = "授权设备不匹配，未解锁。",
        rate_limited = "请求过于频繁，请稍后使用同一密钥重试。",
        invalid_signature = "授权签名校验失败，未解锁。",
        save_failed = "授权保存失败，请检查存储空间后重试。",
        timeout = "连接授权服务器超时。",
        dns_error = "无法解析授权服务器地址。",
        tcp_error = "无法连接授权服务器，请检查当前网络是否能访问授权地址。",
        tcp_timeout = "连接授权服务器超时（TCP 连接阶段）。",
        tls_error = "无法建立安全连接，请检查 Kindle 日期和时间。",
        tls_timeout = "安全连接握手超时，请检查网络后重试。",
        tls_unavailable = "安全证书组件不可用，请检查 KOReader 安装。",
        wifi_off = "Wi-Fi 尚未开启，请联网后重试。",
        offline = "Wi-Fi 尚未连接成功或连接已取消，请联网后重试。",
        server_error = "授权服务器暂时异常，请稍后使用同一密钥重试。",
        activation_rejected = "授权服务器拒绝了本次激活。",
        invalid_receipt = "授权凭据格式错误，未解锁。",
        invalid_response = "授权服务器返回的数据无效，未解锁。",
        response_too_large = "授权服务器返回的数据超出安全限制，未解锁。",
        redirect_refused = "授权地址发生重定向，已停止请求。",
        proxy_not_supported = "当前代理设置不支持安全激活，请直接连接 Wi-Fi 后重试。",
        background_unavailable = "后台联网组件不可用，请重启 KOReader 后重试。",
        network_unavailable = "KOReader 联网组件不可用，请重启后重试。",
    }
    local function cancel()
        local current = attempt
        attempt = nil
        if not current then return end
        if current.handle then pcall(current.handle.cancel, current.handle) end
        if current.busy then self:_closeWidget(current.busy) end
    end
    local function finish(current, ok, reason)
        if closed or attempt ~= current then return end
        attempt = nil
        if current.busy then self:_closeWidget(current.busy) end
        if ok and license:isAuthorized() then
            closed = true
            self:_closeWidget(dialog)
            return continuation and continuation() or true
        end
        return self:_info(messages[reason] or "激活未完成，请联网后用同一密钥重试。", "授权失败")
    end
    dialog = construct(self.input_dialog, {
        title = "密钥激活",
        description = "免费书架最多添加 5 本，添加更多书籍需要密钥。\n阅读小票和阅读回顾数据展示也需要密钥。\n咸鱼搜索：kindle推箱子\n找到傅俊康，购买获取。\n沿用已有短密钥；激活后可离线使用。",
        input = "", input_hint = "XXXX-XXXX-XXXX", input_type = "text", text_type = "password",
        buttons = {{
            { text = "取消", callback = function() closed=true;cancel();return self:_closeWidget(dialog) end },
            { text = "联网激活", is_enter_default = true, callback = function()
                if closed or attempt then return end
                local key = license.normalizeKey(dialog:getInputText())
                if not key then return self:_info("请输入 12 位短密钥，例如 XXXX-XXXX-XXXX。", "授权失败") end
                local current = {}
                attempt = current
                local function cancel_current() if attempt == current then cancel() end end
                current.busy = construct(self.info_message, {
                    text = "正在联网验证密钥…\n点按此提示或返回可取消。", dismiss_callback = cancel_current,
                })
                local on_close = current.busy.onCloseWidget
                current.busy.onCloseWidget = function(instance, ...)
                    if current.busy_closed then return end
                    current.busy_closed = true
                    self.closed_widgets[instance] = true
                    current.busy = nil
                    cancel_current()
                    if on_close then return on_close(instance, ...) end
                end
                current.busy.onSuspend = cancel_current
                local shown = self:_show(current.busy)
                if not shown then cancel();return end
                local called, handle = pcall(license.activateAsync, license, key, function(ok, reason)
                    return finish(current, ok, reason)
                end)
                if not called or not handle then return finish(current, nil, "background_unavailable") end
                if attempt == current then current.handle = handle end
            end },
        }},
    })
    local on_close, disposed = dialog.onCloseWidget, false
    dialog.onCloseWidget = function(instance, ...)
        if disposed then return end
        disposed = true
        self.closed_widgets[instance] = true
        closed = true
        cancel()
        if on_close then return on_close(instance, ...) end
    end
    dialog.onSuspend = function() cancel() end
    return self:_showInput(dialog)
end

function Presenter:_editCategories(back,book,books)
    if not self.app or not self.app.storage or not self.app.settings then return self:_info('分类存储尚未初始化。') end
    local categories=require('legado.lib.shelf_categories').new(self.app.storage,self.app.settings)
    local menu
    local function refresh() self:_closeWidget(menu);return self:_editCategories(back,book,books) end
    local names,err=categories:list();if not names then return self:_info(diagnostic_text(err)) end
    local items={{text='添加分类',callback=function()
        local dialog
        dialog=construct(self.input_dialog,{title='添加一个分类',input='',input_type='string',buttons={{{text='取消',callback=function() self:_closeWidget(dialog) end},
            {text='添加',callback=function(value)
                value=type(value)=='string' and value or (dialog.getInputText and dialog:getInputText()) or ''
                local saved,e=categories:add(value)
                if not saved then return self:_info(e and e.message or '分类保存失败。') end
                self:_closeWidget(dialog);return refresh()
            end}}}})
        return self:_showInput(dialog)
    end}}
    for _,name in ipairs(names) do
        local selected=false
        if books then
            selected = #books > 0
            for _, candidate in ipairs(books) do
                local found=false
                for _, value in ipairs(candidate.custom_categories or {}) do if value==name then found=true;break end end
                if not found then selected=false;break end
            end
        else
            for _,value in ipairs(book and book.custom_categories or {}) do if value==name then selected=true end end
        end
        items[#items+1]={text=(book and (selected and '✓ ' or '□ ') or '')..name,callback=function()
            if books then
                local updated={}
                for _, candidate in ipairs(books) do
                    local categories_for_book, found = {}, false
                    for _, value in ipairs(candidate.custom_categories or {}) do
                        if value == name then found = true else categories_for_book[#categories_for_book + 1] = value end
                    end
                    if not selected then categories_for_book[#categories_for_book + 1] = name end
                    candidate.custom_categories = categories_for_book
                    updated[#updated + 1] = candidate
                end
                local saved,e=self.app.storage:updateBooks(updated)
                if not saved then return self:_info(diagnostic_text(e)) end
                return refresh()
            elseif book then
                local updated={}
                for _,value in ipairs(book.custom_categories or {}) do if value~=name then updated[#updated+1]=value end end
                if not selected then updated[#updated+1]=name end
                local saved,e=self.app.storage:updateBook(book.id,{custom_categories=updated})
                if not saved then return self:_info(diagnostic_text(e)) end
                book.custom_categories=updated
                return refresh()
            end
            local Confirm=optional('ui/widget/confirmbox')
            return self:_show(construct(Confirm,{text='删除分类“'..name..'”？书籍会保留。',ok_text='删除分类',ok_callback=function()
                local saved,e=categories:remove(name)
                if not saved then return self:_info(e and e.message or '删除未完成，请重试；书籍已保留。') end
                return refresh()
            end}))
        end}
    end
    menu=construct(self.menu,{title=book and '选择分类' or '编辑分类',item_table=items,
        close_callback=function() self:_closeWidget(menu);if back then return back() end end})
    return self:_show(menu)
end

function Presenter:_readerBackgroundSettings(view)
    local menu
    local function refresh() self:_closeWidget(menu);return self:_readerBackgroundSettings(view) end
    local function save(key,value)
        local saved,err=view:set(key,value)
        if saved==nil then return self:_info(diagnostic_text(err)) end
        if view.on_background_change then
            local ok,e=view.on_background_change()
            if not ok and e then self:_info(e,'阅读背景') end
        end
        return refresh()
    end
    local items={{text='图片或目录：'..((view.settings:get('reader_background') or '')~='' and view.settings:get('reader_background') or '空白'),callback=function()
        local dialog
        dialog=construct(self.input_dialog,{title='阅读背景图片或目录',input=view.settings:get('reader_background') or '',input_type='string',
            input_hint='例如 /mnt/us/pictures；目录按文件名选第一张图片',buttons={{{text='取消',callback=function() self:_closeWidget(dialog) end},
            {text='保存',callback=function(value)
                value=type(value)=='string' and value or (dialog.getInputText and dialog:getInputText()) or ''
                value=value:match('^%s*(.-)%s*$')
                if value~='' then local path,e=require('legado.lib.reader_background').resolve(value);if not path then return self:_info(e) end end
                self:_closeWidget(dialog);return save('reader_background',value)
            end}}}})
        return self:_showInput(dialog)
    end},{text='浏览图片 / 目录',callback=function()
        local PathChooser=optional('ui/widget/pathchooser')
        if not PathChooser then return self:_info('文件选择器不可用。') end
        return self:_show(PathChooser:new{path='/mnt/us',select_file=true,select_directory=true,show_files=true,
            file_filter=function(file) return file:lower():match('%.png$') or file:lower():match('%.jpe?g$') or file:lower():match('%.webp$') end,
            onConfirm=function(path)
                local resolved,e=require('legado.lib.reader_background').resolve(path)
                if not resolved then return self:_info(e) end
                return save('reader_background',path)
            end})
    end}}
    for _,entry in ipairs{{'reader_background_scale','图片大小',{25,50,75,100,125,150,200}},
        {'reader_background_y','上下位置（0 顶 / 100 底）',{0,25,50,75,100}},
        {'reader_background_x','左右偏移（负数向左）',{-100,-50,-25,-10,0,10,25,50,100}}} do
        local choices={}
        for _,value in ipairs(entry[3]) do choices[#choices+1]={text=value..'%',callback=function() return save(entry[1],value) end} end
        items[#items+1]={text=entry[2]..'：'..view.settings:get(entry[1])..'%',sub_item_table=choices}
    end
    items[#items+1]={text='恢复空白背景',callback=function() return save('reader_background','') end}
    menu=construct(self.menu,{title='阅读背景',item_table=items})
    return self:_show(menu)
end

function Presenter:_settings(view)
    if view.chrome_only then return self:_readerChromeSettings(view) end
    local values = type(view.refresh) == "function" and view:refresh() or view.values or {}
    local items = {}
    local status = type(view.status) == "function" and view:status() or {}
    for _, item in ipairs(self:_settingsRecoveryItems(view, nil, "设置文件损坏，正在使用安全默认值，普通保存已锁定")) do
        items[#items + 1] = item
    end
    if view.temporary_reader_mode then
        items[#items+1]={text='阅读模式已切换，仅本次运行有效；恢复设置后可永久保存',enabled=false}
    end
    if status.recovery_required then
        -- Recovery controls are added above so nested settings pages use the same path.
    elseif status.initial_write_failed then
        items[#items + 1] = { text = "设置持久化暂不可用，修改后将重试保存", enabled = false }
    end
    local function editable(text, key, hint)
        items[#items + 1] = { text = text, callback = function()
            local dialog
            local function accept(value)
                if (value == nil or value == "") and dialog and type(dialog.getInputText) == "function" then value = dialog:getInputText() end
                if tonumber(value) == nil then return self:_info("请输入数字", "设置") end
                if not self:_closeWidget(dialog) then return false end
                local saved, err = view:set(key, value)
                if saved == nil then return self:_info("设置保存失败（" .. safe_token(type(err) == "table" and err.code, "STORAGE_ERROR") .. "）", "设置") end
                return self:_settings(view)
            end
            dialog = construct(self.input_dialog, { title = "修改设置", input_hint = hint, input_type = "number", buttons = {
                { { text = "取消", callback = function() return self:_closeWidget(dialog) end },
                    { text = "确定", is_enter_default = true, callback = accept } },
            } })
            return self:_showInput(dialog)
        end }
    end
    editable("请求超时：" .. tostring(values.timeout or 20) .. " 秒", "timeout", "1–20 秒")
    editable("并发书源：" .. tostring(values.concurrency or 2), "concurrency", "2–3")
    editable("预取章节：" .. tostring(values.prefetch or 3), "prefetch", "0–10")
    items[#items+1]={text="书架布局：每页 4 × 3 本",enabled=false}
    local cache_usage
    if view.cache_usage then
        local ok, result = pcall(view.cache_usage)
        if ok and type(result) == "table" then cache_usage = result end
    end
    items[#items + 1] = { text = string.format("缓存：%.1f MiB（%d 个文件）", (cache_usage and cache_usage.bytes or 0) / 1048576, cache_usage and cache_usage.files or 0), enabled = false }
    editable("缓存上限：" .. tostring(values.cache_limit_mb or 500) .. " MiB", "cache_limit_mb", "50–8192 MiB，且不小于清理阈值")
    editable("自动清理阈值：" .. tostring(values.cache_cleanup_threshold_mb or 300) .. " MiB", "cache_cleanup_threshold_mb", "50–缓存上限 MiB")
    editable("清理后保留：" .. tostring(values.cache_retain_mb or 200) .. " MiB", "cache_retain_mb", "50–清理阈值 MiB")
    if view.cache_cleanup then items[#items + 1] = { text = "立即按策略清理缓存", callback = function()
        local ok, result = pcall(view.cache_cleanup)
        if not ok or type(result) ~= "table" then return self:_info("缓存清理失败，请检查存储空间或权限。") end
        return self:_info(string.format("已清理 %d 个缓存文件，当前 %.1f MiB。", result.removed or 0, (result.bytes or 0) / 1048576))
    end } end
    editable("搜索超时：" .. tostring(values.search_timeout or 10) .. " 秒", "search_timeout", "1–20 秒")
    if view.on_margins then
        local choices={}
        for i,name in ipairs{'最窄','较窄','适中','较宽','最宽'} do
            choices[#choices+1]={text=name,callback=function()
                local ok,err=view.on_margins(i)
                if not ok then return self:_info(type(err)=='table' and diagnostic_text(err) or tostring(err)) end
            end}
        end
        items[#items+1]={text='左右留白（本书，两侧对称）',sub_item_table=choices}
    end
    if view.on_layout then
        items[#items+1]={text='阅读设置（字体、字号、页边距）',callback=function()
            self:_closeWidget(self.settings_widget)
            return view.on_layout()
        end}
    end
    items[#items+1]={text='无感阅读：'..(values.immersive_reader==true and '开启' or '关闭'),
        enabled=not (view.document and view.document.is_local),callback=function()
            if view.on_toggle_reader then
                self:_closeWidget(self.settings_widget)
                return view.on_toggle_reader()
            end
            local saved,err=view:set('immersive_reader',values.immersive_reader~=true)
            if saved==nil then return self:_info(diagnostic_text(err),'保存失败') end
            return self:_settings(view)
        end}
    local function save(key,value)
        local result,err=view:set(key,value)
        if result==nil then return self:_info('设置保存失败（'..safe_token(err and err.code,'STORAGE_ERROR')..'）') end
        return self:_settings(view)
    end
    items[#items+1]={text='底部进度栏',callback=function()
        return self:_readerProgressSettings(view,function() return self:_settings(view) end)
    end}
    items[#items+1]={text='阅读背景',callback=function() return self:_readerBackgroundSettings(view) end}
    items[#items+1]={text='侧边目录位置：'..((values.side_toc_position or 'left')=='right' and '右侧' or '左侧'),callback=function()
        local next_position=(values.side_toc_position or 'left')=='right' and 'left' or 'right'
        return save('side_toc_position',next_position)
    end}
    items[#items+1] = {text='页眉页脚设置',callback=function()
        return self:_readerChromeSettings(view,function() return self:_settings(view) end)
    end}
    local modes={sources='书源书架',['local']='本地书架',mixed='混合书架'}
    items[#items+1]={text='默认书架来源：'..(modes[values.shelf_source] or modes.sources),callback=function()
        return save('shelf_source',values.shelf_source=='sources' and 'local' or values.shelf_source=='local' and 'mixed' or 'sources')
    end}
    items[#items+1]={text='维护自定义分类',callback=function() return self:_editCategories(function() return self:_settings(view) end) end}
    if view.on_sources then items[#items+1]={text='设置书源',callback=function() self:_closeWidget(self.settings_widget); return view.on_sources() end} end
    if view.local_library then
        items[#items+1]={text='添加本地目录',callback=function()
            local PathChooser=optional('ui/widget/pathchooser')
            if not PathChooser then return self:_info('本地目录选择器不可用，请检查 KOReader 版本。') end
            local chooser
            local function reopen(message)
                local function run()
                    if message then self:_info(message, '本地目录') end
                    if view.alive ~= false then self:_settings(view) end
                end
                if self.ui_manager and self.ui_manager.scheduleIn then self.ui_manager:scheduleIn(0, run) else run() end
            end
            self:_closeWidget(self.settings_widget)
            chooser=PathChooser:new{select_file=false,select_directory=true,show_files=false,
                path=(G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting('home_dir')) or view.local_library:directories()[1] or '/mnt/us/documents',
                onConfirm=function(path)
                    local saved,err=view.local_library:addDirectory(path)
                    if not saved then reopen('目录添加失败（'..safe_token(err and err.code,'STORAGE_ERROR')..'）'); return end
                    view.local_directories_changed=true
                    reopen()
                end}
            return self:_show(chooser)
        end}
        for _,path in ipairs(view.local_library:directories()) do
            items[#items+1]={text='目录：'..path,callback=function()
                local ConfirmBox=optional('ui/widget/confirmbox')
                if not ConfirmBox then return false end
                return self:_show(ConfirmBox:new{text='从本地书架移除此目录？文件会保留。',ok_callback=function()
                    local removed,err=view.local_library:removeDirectory(path)
                    if not removed then return self:_info('保存失败（'..safe_token(err and err.code,'STORAGE_ERROR')..'）') end
                    view.local_directories_changed=true
                    return self:_settings(view)
                end})
            end}
        end
    end
    if view.clear_cache then items[#items+1]={text='清理阅读缓存',callback=function()
        local ConfirmBox=optional('ui/widget/confirmbox')
        if not ConfirmBox then return false end
        return self:_show(ConfirmBox:new{text='清理已下载的章节缓存？当前正在读的书、书架、阅读进度、本地文件及导出的 EPUB 会保留。',
            ok_callback=function()
                local count,err=view.clear_cache()
                if count==nil then return self:_info(err and err.code=='DOWNLOAD_ACTIVE' and '请先暂停或完成下载，再清理缓存。' or '缓存清理失败，请检查存储空间或权限。') end
                return self:_info('已清理 '..tostring(count)..' 个缓存文件。')
            end})
    end} end
    for _, action in ipairs(view.actions or {}) do items[#items + 1] = { text = action.text, callback = action.callback } end
    self:_closeWidget(self.settings_widget)
    local widget
    widget=self:_modelMenu(view, { title = "设置", item_table = items, close_callback=function()
        if not self:_closeWidget(widget) then return false end
        if view.on_close then return view.on_close(view.local_directories_changed) end
    end })
    self.settings_widget=widget
    return widget
end

function Presenter:_readingResult(result, err, detail)
    local failure = err
    if not failure and type(result) == "table" and type(result.code) == "string" then failure = result end
    if not failure and type(result)=="string" then failure=result end
    if type(failure)=="string" then
        failure={code="READ_ERROR",details={reason=reading_reasons[failure] and failure or nil}}
    end
    if detail and failure then
        detail._reading_error=failure
        local stage=type(failure)=="table" and type(failure.details)=="table" and reading_stages[failure.details.stage]
        local reason=type(failure)=="table" and type(failure.details)=="table" and failure.details.reason
        local label=reason=='reader_ui_startup' and '界面初始化失败' or reason=='reader_engine_open' and '文档打开失败'
            or (reading_reasons[reason] and reason) or safe_token(type(failure)=="table" and failure.code,"READ_ERROR")
        detail._reading_status="阅读失败 · "..(stage and (stage.." · ") or "")..label
        return self:_detail(detail)
    end
    if failure then
        local code = safe_token(type(failure) == "table" and failure.code, "READ_ERROR")
        return self:_info("阅读失败（" .. code .. "）\n"..diagnostic_text(failure,nil,true), "阅读")
    end
    return result
end

function Presenter:_startReading(action, detail)
    local callback_called, callback_result, sealed = false, nil, false
    local result,err,progress_view
    local step,label,visible=1,'读取目录',false
    local function restore()
        if detail then return self:_detail(detail) end
        local adapter=self.app and self.app.reader_session and self.app.reader_session.ui
        local document=adapter and adapter.current_document
        if document and not document.closed then
            if self.ui_manager then self.ui_manager:setDirty(nil,'full') end
        elseif self.app then return self.app:openBookshelf() end
    end
    local function cancel()
        if sealed or callback_called then return end
        sealed=true
        if result and type(result)=='table' and result.cancel then result:cancel() end
        if detail and detail._cancelReading then detail:_cancelReading() end
        self:_hideLibrary(); self.library_view=nil; self.controllers[progress_view]=nil
        return restore()
    end
    progress_view={kind='reading_progress',close=cancel}
    local function render()
        if callback_called or sealed then return end
        visible=true
        return self:_library(progress_view,{title='正在准备章节',subtitle=label,items={},
            empty_text='完成后自动进入阅读',navigation={},secondary=true,progress=(step-1)/4,
            actions={{text='取消',callback=cancel}},on_back=cancel})
    end
    local function progress(value,text)
        step,label=value,text
        if visible then render() end
    end
    local function complete(value, err)
        if sealed or callback_called then return callback_result end
        callback_called = true
        if self.library_view==progress_view then self:_hideLibrary(); self.library_view=nil end
        self.controllers[progress_view]=nil
        if not detail and (err or type(value)=='string' or (type(value)=='table' and value.code)) then restore() end
        callback_result = self:_readingResult(value, err, detail)
        return callback_result
    end
    -- Start first, then show the progress surface only when the operation is
    -- actually asynchronous. Cached chapter switches otherwise pay for an
    -- unnecessary full-screen redraw before the reader can be reused.
    result, err = action(complete,progress)
    if callback_called then return callback_result or result end
    if err ~= nil or type(result) == "string"
        or (type(result) == "table" and type(result.code) == "string") then return complete(result,err) end
    if err == nil and result ~= nil then render() end
    return self:_readingResult(result, err, detail)
end

function Presenter:_catalog(view)
    local page_size = 15
    local page = math.max(1, tonumber(view.display_page) or math.ceil((view.current_index or 1) / page_size))
    local page_count = math.max(1, math.ceil(#(view.items or {}) / page_size))
    local page_items = {}
    for offset = (page - 1) * page_size + 1, math.min(page * page_size, #(view.items or {})) do page_items[#page_items + 1] = view.items[offset] end
    local items = {}
    for _, item in ipairs(page_items) do
        items[#items + 1] = { title = tostring(item.index) .. ". " .. item.title .. (item.cached and " ✓" or ""), callback = function()
            self:_hideLibrary(); self.library_view = nil
            return self:_startReading(function(complete) return view:select(item.position, complete) end, view._detail)
        end }
    end
    view.on_update = function() if self.library_view == view then return self:_catalog(view) end end
    local can_load_more = type(view.load_more) == "function" and view.catalog_complete == false and not view.loading
    local actions = {
        { text = "上20页", enabled = page > 1, callback = function() view.display_page = math.max(1, page - 20); return self:_catalog(view) end },
        { text = view.reverse and "顺序" or "倒叙", callback = function() view:setOrder(not view.reverse); view.display_page = 1; return self:_catalog(view) end },
        { text = "下20页", enabled = page < page_count, callback = function() view.display_page = math.min(page_count, page + 20); return self:_catalog(view) end },
    }
    return self:_library(view, { title = "目录", subtitle = view.error or view.status, items = items, mode = "list", grid_columns = 2, page = page,
        page_count = page_count, page_size = page_size, already_paginated = true, actions = actions,
        empty_text = view.loading and "正在准备目录…" or "目录为空", navigation = {}, secondary = true,
        on_prev = page > 1 and function() view.display_page = page - 1; return self:_catalog(view) end or nil,
        on_next = page < page_count and function() view.display_page = page + 1; return self:_catalog(view) end
            or can_load_more and function() return view:load_more() end or nil,
        next_enabled = page < page_count or can_load_more,
        load_more = can_load_more,
        on_back = function() self:_hideLibrary(); close_view(view); if view._back then return view._back() end end })
end

function Presenter:_reader_sources(view)
    local items={}
    for _,row in ipairs(view.results or {}) do
        local candidate=row.book
        local chapter_count=row.chapter_count and ((row.catalog_complete and '' or '至少 ')..row.chapter_count..' 章') or '章节数统计中'
        if row.catalog_error then chapter_count='目录暂不可用' end
        items[#items+1]={title=row.source_name or candidate.source_name or '书源',
            subtitle=(candidate.author or '')..' · '..chapter_count,callback=function()
                view:close()
                if view.detail then return view.on_select(view,candidate,nil,row) end
                return self:_startReading(function(done) return view.on_select(view,candidate,done,row) end)
            end}
    end
    local progress=view.progress or {}
    local status=string.format('同书名同作者 · %d 站 · 已查 %d/%d',#items,progress.completed or 0,progress.total or 0)
    if view.loading then status=status..' · 正在统计章节' end
    local empty=view.loading and '正在各站点精确匹配，每 6 秒更新结果…' or '没有找到同书名、同作者的可用站点。'
    if view.error then empty=view.error.code=='INVALID_INPUT' and view.error.message or diagnostic_text(view.error) end
    return self:_library(view,{title='切换站点书源',subtitle=status,items=items,mode='list',secondary=true,
        navigation={},actions={},empty_text=empty,
        on_back=function()
            self:_hideLibrary();self.library_view=nil;close_view(view)
            if view._back then return view._back() end
            if not view.document and self.app then return self.app:openBookshelf() end
            if self.ui_manager then self.ui_manager:setDirty(nil,'full') end
        end})
end

local function review_book(view)
    local book={}
    for key,value in pairs(view.book or {}) do book[key]=value end
    for key,value in pairs(view.info or {}) do book[key]=value end
    return book
end

function Presenter:_readingBack(view)
    if view.kind=='book_detail' then return self:_detail(view) end
    self:_hideLibrary()
    if view._back then return view._back() end
    if view.document then self.library_view=nil;if self.ui_manager then self.ui_manager:setDirty(nil,'full') end;return true end
    if self.app then return self.app:openBookshelf() end
end

function Presenter:_closeReceipt()
    local widget=self.receipt_widget;self.receipt_widget=nil
    if widget then
        if widget.closeForReplacement then widget:closeForReplacement() else self:_closeWidget(widget) end
    end
end

function Presenter:_readingReceipt(view, selected, back)
    if not (self.app and self.app.isLicensed and self.app:isLicensed()) then
        return self:showLicenseDialog(function() return self:_readingReceipt(view, selected, back) end)
    end
    local H=require('legado.lib.reading_history')
    local book=selected or review_book(view)
    local storage=self.app and self.app.storage
    local document=view.document
    if document and document.flushProgress then pcall(document.flushProgress,document) end
    local progress,err
    if storage and storage.getProgress then progress,err=storage:getProgress(book.id) end
    if err then return self:_info(diagnostic_text(err),'阅读小票') end
    local model=H.book(book,progress or {})
    model.kind='receipt'
    local function native(object,method,...)
        if not object or type(object[method])~='function' then return end
        local ok,value=pcall(object[method],object,...);if ok then return value end
    end
    local live_book=document and (document.book or document.reading_state and document.reading_state.book)
    local current=not live_book or live_book.id==book.id
    local context=current and native(document,'getReadingContext')
    if type(context)=='table' then
        for _,key in ipairs{'chapter_title','chapter_page','chapter_pages','chapter_fraction',
            'chapter_remaining','book_remaining'} do model[key]=context[key] end
    elseif current and document and document.reader then
        local r=document.reader
        local page=native(r,'getCurrentPage')
        model.chapter_pages=native(r.toc,'getChapterPageCount',page) or native(r.document,'getPageCount')
        local done=native(r.toc,'getChapterPagesDone',page)
        model.chapter_page=done and done+1 or page
        if model.chapter_page and model.chapter_pages and model.chapter_pages>0 then model.chapter_fraction=model.chapter_page/model.chapter_pages end
        model.chapter_title=native(r.toc,'getTocTitleByPage',page) or model.chapter_title
        local statistics=r.statistics
        local average=statistics and statistics.settings and statistics.settings.is_enabled and tonumber(statistics.avg_time)
        if average and average==average and average>0 and average<math.huge then
            local left=native(r.toc,'getChapterPagesLeft',page,true) or native(r.document,'getTotalPagesLeft',page)
            model.chapter_remaining=left and left*average
            if book.is_local then
                left=native(r.document,'getTotalPagesLeft',page);model.book_remaining=left and left*average
            end
        end
    end
    local settings=self.app and self.app.settings
    local function setting(key,default) return settings and settings:get(key) or default end
    local function rebuild() return self:_readingReceipt(view,book,back) end
    local function save(field,value)
        local saved,save_error=H.setReview(storage,book,field,value)
        if not saved then return self:_info(diagnostic_text(save_error),'保存失败') end
        return rebuild()
    end
    local function edit(kind)
        local menu,items
        local function choose(key,value)
            local saved,save_error=settings and settings:set(key,value)
            if not saved then return self:_info(diagnostic_text(save_error or {code='STORAGE_ERROR'}),'保存失败') end
            self:_closeWidget(menu);return rebuild()
        end
        if kind=='style' then
            items={}
            for _,entry in ipairs(require('legado.lib.receipt_styles').list) do
                items[#items+1]={text=entry[2],callback=function() return choose('receipt_style',entry[1]) end}
            end
        else
            items={}
            for _,entry in ipairs({{'receipt_width','宽度',{50,60,65,70,75,80,85,90,95}}, {'receipt_height','高度',{55,60,65,70,75,80,85,90,95}}}) do
                local choices={}
                for _,value in ipairs(entry[3]) do choices[#choices+1]={text=value..'%',callback=function() return choose(entry[1],value) end} end
                items[#items+1]={text=entry[2]..'：'..setting(entry[1],entry[1]=='receipt_width' and 75 or 90)..'%',sub_item_table=choices}
            end
        end
        menu=construct(self.menu,{title=kind=='style' and '小票样式' or '小票尺寸',item_table=items})
        return self:_show(menu)
    end
    local function comment(value)
        local dialog
        dialog=construct(self.input_dialog,{title='编辑阅读短评',input=value or '',text=value or '',multiline=true,
            input_type='string',buttons={{{text='取消',callback=function() return self:_closeWidget(dialog) end},
                {text='保存',callback=function(text)
                    text=type(text)=='string' and text or (dialog.getInputText and dialog:getInputText()) or ''
                    local result,save_error=H.setReview(storage,book,'comment',text)
                    if not result then return self:_info(diagnostic_text(save_error),'保存失败') end
                    self:_closeWidget(dialog);return rebuild()
                end}}}})
        return self:_showInput(dialog)
    end
    model.on_rating=function(value) return save('rating',value) end
    model.on_status=function(value) return save('status',value) end
    local widget=require('legado.ui.receipt_screen').new{reading_model=model,ui_manager=self.ui_manager,
        with_background=view.kind~='reading_receipt' or not document,
        background_path=setting('receipt_background',''),
        width_percent=setting('receipt_width',75),height_percent=setting('receipt_height',90),style=setting('receipt_style','classic'),
        cover_loader=self.cover_loader or self.app and self.app.cover_loader,
        on_edit=edit,on_comment=comment,on_back=function()
            self:_closeReceipt()
            if back then return back() end
            return self:_readingBack(view)
        end}
    self:_show(widget);self:_closeReceipt();self.receipt_widget=widget
    return widget
end

function Presenter:_receiptBackground(refresh)
    local settings=self.app and self.app.settings
    if not settings then return self:_info('设置尚未初始化。','小票背景') end
    local dialog
    local function save(value)
        value=type(value)=='string' and value or (dialog.getInputText and dialog:getInputText()) or ''
        value=value:match('^%s*(.-)%s*$')
        if value~='' then
            local image,err=require('legado.ui.receipt_screen').loadBackground(value)
            if not image then return self:_info(err,'小票背景') end
            image:free()
        end
        local saved,err=settings:set('receipt_background',value)
        if saved==nil then return self:_info(diagnostic_text(err),'保存失败') end
        self:_closeWidget(dialog)
        return refresh()
    end
    local function browse()
        local PathChooser=optional('ui/widget/pathchooser')
        if not PathChooser then return self:_info('文件选择器不可用，请填写图片完整路径。') end
        return self:_show(PathChooser:new{title='长按图片文件以选择',select_directory=false,select_file=true,
            path=(G_reader_settings and G_reader_settings:readSetting('home_dir')) or '/mnt/us/documents',
            file_filter=function(file)
                local ext=tostring(file):lower():match('%.([^%.]+)$')
                return ext=='png' or ext=='jpg' or ext=='jpeg' or ext=='webp' or ext=='gif' or ext=='bmp'
            end,
            onConfirm=save})
    end
    dialog=construct(self.input_dialog,{title='小票背景图片路径',input=settings:get('receipt_background') or '',
        input_hint='留空使用白色背景，如 /mnt/us/pictures/background.jpg',input_type='string',
        buttons={{{text='选择图片',callback=browse},{text='恢复白色背景',callback=function() return save('') end}},
            {{text='取消',callback=function() return self:_closeWidget(dialog) end},{text='保存',callback=save}}}})
    return self:_showInput(dialog)
end

function Presenter:_readingReview(view)
    if not (self.app and self.app.isLicensed and self.app:isLicensed()) then
        return self:showLicenseDialog(function() return self:_readingReview(view) end)
    end
    local H=require('legado.lib.reading_history')
    local now=os.time()
    local today=os.date('*t',now)
    local context=view._reading_context
    if not context then
        context={tab='overview',year=today.year,month=today.month,calendar_year=today.year,
            selected_day=os.date('%Y-%m-%d',now),books_page=1,day_page=1}
        view._reading_context=context
    end
    local report,err=H.collect(self.app and self.app.storage,view.book and view.book.id)
    if not report then return self:_info(diagnostic_text(err),'阅读回顾') end
    local function refresh() return self:_readingReview(view) end
    local model,page,pages
    if context.tab=='daily' then
        model=H.calendar(report,context.calendar_year,context.month,context.selected_day,now)
        context.selected_day=model.selected_day
        local records=model.day_books
        pages=math.max(1,math.ceil(#records/3))
        context.day_page=math.min(context.day_page,pages)
        page=context.day_page
        model.day_books={}
        for i=(page-1)*3+1,math.min(page*3,#records) do model.day_books[#model.day_books+1]=records[i] end
        model.on_day=function(date) context.selected_day=date;context.day_page=1;return refresh() end
        model.on_period_change=function(delta)
            local date=os.date('*t',os.time{year=context.calendar_year,month=context.month+delta,day=1,hour=12})
            if date.year<1970 or date.year>9998 then return false end
            context.calendar_year,context.month=date.year,date.month
            context.selected_day=string.format('%04d-%02d-01',date.year,date.month)
            context.day_page=1
            return refresh()
        end
    elseif context.tab=='books' then
        pages=math.max(1,math.ceil(#report.records/6))
        context.books_page=math.min(context.books_page,pages)
        page=context.books_page
        model={records={},total_records=#report.records}
        for i=(page-1)*6+1,math.min(page*6,#report.records) do model.records[#model.records+1]=report.records[i] end
    else
        model=H.overview(report,context.year,now)
        model.on_period_change=function(delta) context.year=math.max(1970,math.min(9998,context.year+delta));return refresh() end
    end
    model.kind=context.tab
    model.on_book=function(book) return self:_readingReceipt(view,book,refresh) end
    local categories={}
    for _,tab in ipairs{{'累计时长','overview'},{'每日时长','daily'},{'阅读书籍','books'}} do
        categories[#categories+1]={text=tab[1],active=context.tab==tab[2],callback=function() context.tab=tab[2];return refresh() end}
    end
    local function turn(delta)
        local key=context.tab=='daily' and 'day_page' or 'books_page'
        context[key]=math.max(1,math.min(pages,context[key]+delta))
        return refresh()
    end
    return self:_library(view,{title='阅读回顾',subtitle=view.book and view.book.name or '全部书籍',
        reading_model=model,items={},categories=categories,subpage='reading_review',navigation={},secondary=true,
        actions=context.tab=='books' and {{text='小票背景图片',callback=function() return self:_receiptBackground(refresh) end}} or {},
        already_paginated=true,page=page or 1,page_count=pages or 1,
        on_prev=page and page>1 and function() return turn(-1) end or nil,
        on_next=page and page<pages and function() return turn(1) end or nil,
        on_back=function() return self:_readingBack(view) end})
end

function Presenter:_detail(view)
    local book={}
    for key,value in pairs(view.book or {}) do book[key]=value end
    for key,value in pairs(view.info or {}) do book[key]=value end
    local saved_progress
    if self.app and self.app.storage and type(self.app.storage.getProgress) == "function" then
        local ok, value = pcall(self.app.storage.getProgress, self.app.storage, book.id)
        if ok then saved_progress = value end
    end
    local has_progress = type(saved_progress) == "table"
        and (saved_progress.fraction ~= nil or saved_progress.chapter_index ~= nil
            or saved_progress.chapter_uid ~= nil or saved_progress.updated_at ~= nil)
    local read_label = has_progress and "继续阅读" or "开始阅读"
    local actions={
        {text=read_label,callback=function()
            view._reading_status,view._reading_error=nil,nil
            self:_hideLibrary()
            self.library_view=nil
            return self:_startReading(function(complete,progress)
                return view:startReading(complete,progress)
            end,view)
        end},
        {text="加入书架",callback=function() return self:_addToShelf(view) end},
        {text="移出书架",callback=function()
            local removed,err=view:removeFromShelf()
            view._notice=removed and "已移出书架" or ("移出失败 · "..safe_token(type(err)=="table" and err.code,"STORAGE_ERROR"))
            return self:_detail(view)
        end},
        {text="查看目录",callback=function()
            view._notice="目录加载中…"
            self:_detail(view)
            return view:loadCatalog(function(catalog,err)
                if view.alive==false or self.library_view~=view or self.library_subpage~="detail" then return end
                if err then view._notice="目录加载失败 · "..safe_token(err.code,"PARSE_ERROR"); return self:_detail(view) end
                if catalog then
                    catalog._detail=view
                    catalog._back=function() return self:_detail(view) end
                    return self:_catalog(catalog)
                end
            end)
        end},
        {text="阅读回顾",callback=function() return self:_readingReview(view) end},
        {text="阅读小票",callback=function() return self:_readingReceipt(view) end},
        {text="切换站点书源",enabled=self.app~=nil,callback=function()
            return self.app:openReaderSourceSites(nil,nil,view)
        end},
        {text="编辑分类",callback=function()
            return self:_editCategories(function() view.book.custom_categories=book.custom_categories;return self:_detail(view) end,book)
        end},
        {text="下载整本",callback=function()
            local task,err=view:startDownload()
            view._notice=type(task)=="table" and "已加入下载队列" or ("下载失败 · "..safe_token(type(err)=="table" and err.code,"DOWNLOAD_ERROR"))
            return self:_detail(view)
        end},
        {text=view.info_error and "详情诊断" or "完整简介",callback=function()
            if view.info_error then
                local report=type(view.compatibility)=="function" and view:compatibility() or view.compatibility
                return self:_info(diagnostic_text(view.info_error,report),"书源诊断")
            end
            local TextViewer=optional("ui/widget/textviewer")
            return self:_show(construct(TextViewer or self.info_message,{text=book.intro or "暂无简介",title=book.name or "简介"}))
        end},
    }
    if book.is_local then actions={actions[1],actions[5],actions[6],actions[#actions]} end
    if view.info_error then table.insert(actions,2,table.remove(actions)) end
    if view._reading_error then
        table.insert(actions,2,{text="阅读诊断",callback=function()
            return self:_info(diagnostic_text(view._reading_error,nil,true),"阅读诊断")
        end})
    end
    local more_actions = {}
    for index = 2, #actions do more_actions[#more_actions + 1] = actions[index] end
    local function show_more()
        return self:_library(view, { title = "书籍菜单", items = more_actions,
            subpage = "detail_more", secondary = true,
            on_back = function() return self:_detail(view) end })
    end
    local status=view._reading_status or view._notice or (view.info_error and ("详情加载失败 · "..safe_token(view.info_error.code,"PARSE_ERROR")))
        or (view.loading_info and "详情加载中…") or book.source_name or "图书详情"
    local item=self:_bookItem(book,view.alternatives)
    item.callback=nil
    item.subtitle=table.concat({book.author or "未知作者",book.kind or "",book.last_chapter or ""}," · ")
    local widget=self:_library(view,{title="书籍详情",subtitle=status,items={item},mode="detail",subpage="detail",
        header_action={text="更多",callback=show_more},actions=actions})
    if not view.info and not view.info_error and not view._presenter_info_started and type(view.loadInfo)=="function" then
        view._presenter_info_started=true
        view:loadInfo(function(info,err)
            if info then
                for _,candidate in ipairs(view._source_books or {}) do
                    if candidate.id==info.id then for key,value in pairs(info) do candidate[key]=value end end
                end
            end
            if err then view.info_error=err end
            if view.alive~=false and self.library_view==view and self.library_subpage=="detail" then self:_detail(view) end
        end)
    end
    return self.library_widget or widget
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
            local action_menu
            action_menu = construct(self.menu, { title = "下载操作", item_table = actions,
                close_callback = function()
                    if not self:_closeWidget(action_menu) then return false end
                    return self:_downloads(view)
                end,
            })
            return self:_show(action_menu)
        end }
    end
    if #items == 0 then items[1] = { text = "暂无下载记录", enabled = false } end
    items[#items + 1] = { text = "刷新", callback = function() return self:_downloads(view) end }
    return items
end

function Presenter:_downloads(view)
    view:refresh()
    local widget
    widget = self:_modelMenu(view, { title = "下载管理", item_table = download_items(self, view),close_callback=function()
        self:_closeWidget(widget);view:close()
        if self.app then return self.app:openBookshelf() end
    end })
    view.on_refresh = function(current)
        if not current.alive or self.closed_widgets[widget] then return end
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

function Presenter:_addToShelf(view)
    local saved,err=view:addToShelf()
    if not saved and type(err)=="table" and err.code=="LICENSE_REQUIRED" then
        return self:showLicenseDialog(function() return self:_addToShelf(view) end)
    end
    view._notice=saved and "已加入书架" or ("收藏失败 · "..safe_token(type(err)=="table" and err.code,"STORAGE_ERROR"))
    return self:_detail(view)
end

function Presenter:show(view)
    if type(view)=="table" and view.kind=="license_required" then
        return self:showLicenseDialog(view.continuation)
    end
    self:_closeReceipt()
    self:_ensureBackdrop()
    self:_leaveLibrary(view)
    if type(view) ~= "table" then return self:_info("界面不可用") end
    if view.kind == "side_toc" and view.side then
        local widget, err = view.side:show(true)
        if not widget then return self:_info((err and err.message) or "侧边目录显示失败", "目录") end
        self.library_view, self.library_widget = view, widget
        self.view_widgets[view] = widget
        local shown, show_error = self:_show(widget)
        if not shown then return self:_info((show_error and show_error.message) or "侧边目录显示失败", "目录") end
        return widget
    end
    if view.kind == "home" then return self:_home(view) end
    if view.kind == "bookshelf" then return self:_shelf(view, 1, "cover") end
    if view.kind == "search" then return self:_search(view) end
    if view.kind == "discovery" then return self:_discovery(view) end
    if view.kind == "source_manager" then return self:_sources(view) end
    if view.kind == "settings" then return self:_settings(view) end
    if view.kind == "catalog" then return self:_catalog(view) end
    if view.kind == "reader_sources" then return self:_reader_sources(view) end
    if view.kind == "reader_source_sites" then return self:_reader_sources(view) end
    if view.kind == "reading_review" then return self:_readingReview(view) end
    if view.kind == "reading_receipt" then return self:_readingReceipt(view) end
    if view.kind == "book_detail" then return self:_detail(view) end
    if view.kind == "downloads" then return self:_downloads(view) end
    if view.kind == "compatibility_report" then return self:_compatibility(view) end
    return self:_info(view.text or view.empty_text or view.error or "", view.title)
end

return Presenter
