-- Small compatibility adapter around KOReader's documented ReaderUI entry point.
-- The session owns only documents it opens through this adapter; it never observes
-- arbitrary ReaderUI instances.
local Errors = require("legado.lib.errors")
local ReaderChrome = require("legado.lib.reader_chrome")

local Adapter = {}
Adapter.__index = Adapter

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

function Adapter.new(options)
    options = options or {}
    return setmetatable({ ReaderUI = options.ReaderUI,
        on_exit = options.on_exit, on_toc = options.on_toc, on_settings = options.on_settings,
        on_sources = options.on_sources, on_book_search = options.on_book_search,
        on_source_sites = options.on_source_sites,
        on_chrome_settings = options.on_chrome_settings,
        on_review=options.on_review,on_receipt=options.on_receipt,on_statistics=options.on_statistics,
        on_toggle_reader=options.on_toggle_reader,on_book_info=options.on_book_info,on_add_to_shelf=options.on_add_to_shelf,
        ui_manager=options.ui_manager,
        settings = options.settings }, Adapter)
end

function Adapter:applyProgressBar(reader, enabled)
    local footer = reader and ((reader.view and reader.view.footer) or reader.footer)
    if not footer or not footer.settings then return false end
    local defaults=require('legado.lib.settings').DEFAULTS
    local function value(key)
        local v=self.settings and self.settings:get(key)
        if v==nil then return defaults[key] end
        return v
    end
    local mode=value('progress_bar_mode')
    if mode~='hidden' and mode~='bar' then mode='details' end
    if enabled==false or (enabled==nil and value('progress_bar')==false) then mode='hidden'
    elseif enabled==true and mode=='hidden' then mode='details' end
    if footer.settings.disabled then return mode=='hidden' end
    -- Copy: KOReader may share this table with its global defaults.
    local settings = {}; for k,v in pairs(footer.settings) do settings[k]=v end
    for _,name in pairs(footer.mode_index or {}) do settings[name]=false end
    settings.disable_progress_bar = mode=='hidden'
    settings.all_at_once,settings.additional_content=true,mode=='details'
    settings.chapter_progress_bar,settings.toc_markers=true,false
    settings.progress_bar_position='alongside'
    settings.bottom_horizontal_separator=false
    settings.reclaim_height=mode=='hidden'
    settings.progress_bar_lock_width=false
    local font_size=math.max(8,math.min(22,tonumber(value('progress_bar_font_size')) or 12))
    local height=math.max(16,math.min(48,tonumber(value('progress_bar_height')) or 24))
    local font_changed=settings.text_font_size~=font_size
    settings.text_font_size=font_size
    settings.container_height,settings.container_bottom_padding=height,2
    footer.settings = settings
    footer.reclaim_height=settings.reclaim_height
    -- Native additional-content generation handles page turns and mode switches.
    -- This ReaderFooter belongs to this plugin-opened document; global defaults are untouched.
    footer.additional_footer_content=mode=='details' and {function() return ReaderChrome.progressText(footer) end} or {}
    if font_changed and footer.updateFooterFont then footer:updateFooterFont() end
    local device=optional('device')
    local screen=device and device.screen
    local function scale(n) return screen and screen.scaleBySize and screen:scaleBySize(n) or n end
    local text_height=footer.footer_text and footer.footer_text:getSize().h or scale(font_size)
    footer.height=mode=='hidden' and 0 or math.max(scale(height),mode=='details' and text_height+scale(6) or 0)
    footer.bottom_padding=mode=='hidden' and 0 or scale(2)
    if footer.text_container then footer.text_container.dimen.h=footer.height end
    if footer.set_has_no_mode then footer:set_has_no_mode() end
    if footer.updateFooterTextGenerator then footer:updateFooterTextGenerator() end
    if footer.mode_list and footer.applyFooterMode then
        footer:applyFooterMode(mode=='hidden' and footer.mode_list.off or footer.mode_list.page_progress)
    elseif footer.view then
        footer.view.footer_visible=mode~='hidden'
    end
    if footer.refreshFooter then footer:refreshFooter(true, true) end
    return true
end

function Adapter.marginValues(width,font,scale)
    scale=scale or 1
    local values,previous={},math.floor(width/font)+1
    for i,base in ipairs{12,20,28,36,48} do
        local columns=math.max(1,math.min(math.floor((width-2*base*scale)/font),previous-1))
        values[i]=math.ceil((width-columns*font)/(2*scale))
        previous=columns
    end
    return values
end

function Adapter:applyMarginPreset(reader,index)
    if not reader or not reader.typeset or not reader.document then return nil,'排版尚未就绪' end
    local screen=optional('device').screen
    local size=reader.document:getFontSize()
    local margin=Adapter.marginValues(screen:getWidth(),size,screen:scaleBySize(100)/100)[index]
    if not margin then return nil,'无效的留白挡位' end
    local typeset=reader.typeset
    typeset.configurable.h_page_margins={margin,margin}
    typeset:onSetPageHorizMargins({margin,margin})
    return true
end

function Adapter:applyTouchZones(reader,proxy)
    if not reader.view then return end
    -- Only this reader instance changes. Keep top/bottom available to native menus.
    reader.view.getTapZones=function()
        return {ratio_x=.25,ratio_y=.12,ratio_w=.75,ratio_h=.76},
            {ratio_x=0,ratio_y=.12,ratio_w=.25,ratio_h=.76}
    end
    local module=reader.rolling or reader.paging
    if module and module.setupTouchZones then module:setupTouchZones() end
    if proxy and reader.registerTouchZones and self.on_toc then
        reader:registerTouchZones{{id='legado_sidebar',ges='tap',
            screen_zone=require('legado.ui.side_toc').ACTIVATION_ZONE,
            overrides={'tap_forward','tap_backward','readermenu_tap','readermenu_ext_tap',
                'readerconfigmenu_tap','readerconfigmenu_ext_tap','tap_link','readerhighlight_tap','tap_top_right_corner'},
            handler=function()
                if proxy.closed then return false end
                local ok=pcall(self.on_toc,proxy)
                return ok
            end}}
    end
end

function Adapter:_attachMenu(reader, proxy, callbacks)
    local menu, UIManager = reader.menu, optional('ui/uimanager')
    if not menu then return end
    local function close_menu()
        if menu.onTapCloseMenu then menu:onTapCloseMenu() end
    end
    local leaving = false
    local function bookshelf()
        if leaving then return true end
        leaving = true
        close_menu()
        local function exit()
            if reader.onClose then pcall(reader.onClose, reader, true) end
            if self.on_exit then pcall(self.on_exit, proxy) end
        end
        if UIManager and UIManager.scheduleIn then UIManager:scheduleIn(0, exit) else exit() end
        return true
    end
    local function toc()
        close_menu()
        if callbacks and callbacks.end_of_book and self.on_toc then local ok,result=pcall(self.on_toc,proxy); return ok and result or false end
        if reader.toc and reader.toc.onShowToc then local ok,result=pcall(reader.toc.onShowToc,reader.toc); return ok and result or false end
    end
    if callbacks and callbacks.end_of_book and reader.toc and self.on_toc then
        reader.toc.onShowToc = function() close_menu(); local ok,result=pcall(self.on_toc,proxy); return ok and result or false end
    end
    reader.onHome = bookshelf
    -- The native Back/CloseBook paths call this after closing the document.
    -- Keep generated chapter paths out of FileManager.
    if self.on_exit then reader.showFileManager=bookshelf end
    local function items()
        local entries = {
            {text='目录', callback=toc},
            {text='回到书架', callback=bookshelf},
            {text='设置', callback=function() close_menu(); if self.on_settings then local ok,result=pcall(self.on_settings,proxy); return ok and result or false end end},
            {text='阅读回顾', callback=function() close_menu(); if self.on_review then local ok,result=pcall(self.on_review,proxy); return ok and result or false end end},
            {text='切换站点书源', callback=function() close_menu(); if self.on_source_sites then local ok,result=pcall(self.on_source_sites,proxy); return ok and result or false end end},
            {text='页眉页脚设置', callback=function() close_menu(); if self.on_chrome_settings then local ok,result=pcall(self.on_chrome_settings,proxy); return ok and result or false end end},
            {text='当前书籍小票', callback=function() close_menu(); if self.on_receipt then local ok,result=pcall(self.on_receipt,proxy); return ok and result or false end end},
            {text='阅读统计', callback=function()
                close_menu()
                if callbacks and callbacks.flush then callbacks.flush(proxy) end
                if self.on_statistics then return self.on_statistics(proxy) end
            end},
        }
        if self.on_toggle_reader and callbacks and callbacks.end_of_book then
            entries[#entries+1]={text='无感阅读：启用',callback=function()
                close_menu();return self.on_toggle_reader(proxy)
            end}
        end
        return entries
    end
    local function inject()
        local tabs = menu.tab_item_table
        if type(tabs) ~= 'table' then return end
        for i=#tabs,1,-1 do if tabs[i].legado_reader then table.remove(tabs,i) end end
        local tab = items()
        tab.icon, tab.remember, tab.legado_reader = 'appbar.pageview', false, true
        table.insert(tabs,1,tab)
        -- Moon may redirect this button; our documents always return to this shelf.
        for _,entry in ipairs(tabs) do if entry.icon == 'appbar.filebrowser' then entry.callback=bookshelf end end
    end
    if type(menu.setUpdateItemTable) == 'function' then
        local original = menu.setUpdateItemTable
        menu.setUpdateItemTable = function(instance, ...) original(instance,...); inject() end
        inject()
        local location = menu._getTabIndexFromLocation
        menu.last_tab_index=1
        menu._getTabIndexFromLocation = function(instance, ges)
            if ges and ges.pos then return 1 end
            return location and location(instance,ges) or 1
        end
        local show=menu.onShowMenu
        if show then menu.onShowMenu=function(instance,index,...)
            local result=show(instance,index,...)
            local opened=instance.menu_container and instance.menu_container[1]
            if (index==nil or index==1) and opened and opened.switchMenuTab then opened:switchMenuTab(1) end
            return result
        end end
    elseif menu.registerToMainMenu then
        menu:registerToMainMenu({addToMainMenu=function(_,entries)
            entries.legado_reader={text='书源阅读', sorting_hint='main', sub_item_table=items()}
        end})
    end
end

local function failure(message)
    return Errors.new(Errors.STORAGE_ERROR, message, { stage = "reader_open" })
end

-- Only layout preferences may cross generated chapter boundaries. Take bottom
-- panel keys from KOReader's own option schema, not from arbitrary sidecar data.
local function reading_setting_keys(reader)
    local keys = {}
    for _, key in ipairs({ 'font_face', 'font_family_fonts', 'css',
        'style_tweaks', 'style_tweaks_enabled', 'book_style_tweak', 'book_style_tweak_enabled',
        'text_lang', 'text_lang_embedded_langs', 'hyphenation', 'hyph_trust_soft_hyphens',
        'hyph_soft_hyphens_only', 'hyph_force_algorithmic', 'floating_punctuation' }) do keys[key] = true end
    local options = reader.config and reader.config.options
    if options and options.prefix == 'copt' then
        for _, panel in ipairs(options) do
            for _, option in ipairs(panel.options or {}) do keys['copt_' .. option.name] = true end
        end
    end
    return keys
end

function Adapter:prepareChapter(state,chapter,body)
    return require('legado.lib.leko_reader_ui').prepare(self,state,chapter,body)
end
function Adapter:getPreparedChapterStatus(state)
    return require('legado.lib.leko_reader_ui').preparedStatus(self,state)
end

function Adapter:openChapter(payload,callbacks)
    local previous=self.current_document
    local ui=self.ui_manager or require('ui/uimanager')
    local events={};for key,value in pairs(callbacks or {}) do events[key]=value end
    events.ready=function(document)
        -- Show only queues repaint. Validate display before committing preference
        -- and session; rejected candidates are removed before the next UI tick.
        if not document.reuses_widget and ui:show(document.widget)==false then return nil,Errors.new(Errors.STORAGE_ERROR,'独立阅读页面无法显示。') end
        if callbacks and callbacks.ready then return callbacks.ready(document) end
        return true
    end
    local document,err=require('legado.lib.leko_reader_ui').open(self,payload,events)
    if not document then return nil,err end
    self.current_document=document
    if self.preparation_resume then local resume=self.preparation_resume;self.preparation_resume=nil;resume() end
    if previous and not previous.closed and previous.close then previous:close() end
    local dirty,dirty_error=pcall(ui.setDirty,ui,document.widget,'ui')
    if not dirty then document.widget:_error(dirty_error) end
    if previous then
        local old=previous.reading_state
        local direction=old and old.index>payload.state.index and 'backward' or 'forward'
        local animated,result,animation_error=pcall(document.animateEntry,document,direction,not old or old.index~=payload.state.index)
        if not animated or result==false or animation_error then
            document.widget:_finishAnimation(true)
            document.widget:_error(not animated and result or animation_error or '章节切换动画未完成。')
        end
    end
    if callbacks and callbacks.committed then callbacks.committed(document) end
    return document
end

function Adapter:openDocument(path, callbacks)
    local now=callbacks and callbacks.now or os.clock
    local function timing(stage,started) if callbacks and callbacks.timing then pcall(callbacks.timing,stage,started) end end
    local open_started=now()
    local previous_document=self.current_document
    local reader_ui = self.ReaderUI or optional("apps/reader/readerui")
    if not reader_ui or type(reader_ui.showReader) ~= "function" then
        return nil, failure("KOReader reader UI is unavailable")
    end
    self.ReaderUI=reader_ui
    local proxy = { is_legado_document = true,backend='native' }
    local ready_error, initialized, settled, after_open
    local old_do, old_manager = reader_ui.doShowReader, reader_ui.showFileManager
    local old_settings_handler = reader_ui.handleEvent
    local saved_settings_handler = rawget(reader_ui, 'handleEvent')
    local previous_instance = reader_ui.instance
    local observed_do, observed_manager, observed_settings
    local rollbacks = {}
    local function remember(object, keys)
        if not object then return end
        local saved = {}
        for _,key in ipairs(keys) do saved[key] = rawget(object,key) end
        rollbacks[#rollbacks+1] = function()
            for _,key in ipairs(keys) do object[key] = saved[key] end
        end
    end
    local function remember_array(array)
        if type(array) ~= 'table' then return end
        local saved = {}; for i,item in ipairs(array) do saved[i]=item end
        rollbacks[#rollbacks+1] = function()
            for i=#array,1,-1 do array[i]=nil end
            for i,item in ipairs(saved) do array[i]=item end
        end
    end
    local function restore_observers()
        if observed_do and reader_ui.doShowReader==observed_do then reader_ui.doShowReader=old_do end
        if observed_manager and reader_ui.showFileManager==observed_manager then reader_ui.showFileManager=old_manager end
        if observed_settings and reader_ui.handleEvent==observed_settings then reader_ui.handleEvent=saved_settings_handler end
        if reader_ui.after_open_callback==after_open then reader_ui.after_open_callback=nil end
    end
    local function startup_error(reason, cause)
        local err=failure('KOReader reader initialization failed')
        err.details.reason=reason
        if type(cause)=='string' then
            local file,line=cause:match('([%w_-]+%.lua):(%d+):')
            if file then err.details.location=file..':'..line end
        elseif type(cause)=='table' and type(cause.code)=='string' then
            err.code=cause.code
        end
        return err
    end
    local function failed(err)
        if settled then return end
        if self.current_document==proxy then
            self.current_document=previous_document and not previous_document.closed and previous_document or nil
        end
        settled,ready_error,proxy.closed=true,err,true
        restore_observers()
        if proxy.chrome then pcall(proxy.chrome.close,proxy.chrome) end
        for i=#rollbacks,1,-1 do pcall(rollbacks[i]) end
        local reader=proxy.reader
        if not reader then
            local current=reader_ui.instance
            if current and current~=previous_instance and current.document and current.document.file==path then reader=current end
        end
        if reader and reader.onClose then pcall(reader.onClose,reader,true) end
        -- The native coroutine's error handler normally restores input; we consumed its error.
        local device=optional('device')
        if device and device.setIgnoreInput then pcall(device.setIgnoreInput,device,false) end
        if device and device.input and device.input.inhibitInputUntil then pcall(device.input.inhibitInputUntil,device.input,.2) end
        local logger=optional('logger')
        if logger and logger.warn then pcall(logger.warn,'[Legado]',err.details.reason,err.details.location or '-') end
        if callbacks and callbacks.failure then pcall(callbacks.failure,err) end
    end
    local function ready()
        if settled then return end
        restore_observers()
        if callbacks and callbacks.ready then
            local ok,result,err=pcall(callbacks.ready,proxy)
            if not ok or result==false or (result==nil and type(err)=='table' and err.code) then
                return failed(startup_error('reader_ui_startup',not ok and result or err))
            end
        end
        self.current_document=proxy
        if previous_document and previous_document.backend=='immersive' and not previous_document.closed then previous_document:close() end
        settled=true
    end
    local function initialize(reader)
        local initialize_started=now()
        assert(reader,'reader unavailable')
        proxy.reader = reader
        proxy.close=function() if not proxy.closed and reader.onClose then return reader:onClose(true) end return true end
        remember(reader,{'onHome','showFileManager','onFlushSettings','onClose','handleEvent'})
        remember(reader.toc,{'onShowToc'})
        remember(reader.view,{'getTapZones','paintTo'})
        if reader.view and type(reader.view.paintTo)=='function' then
            local paint=reader.view.paintTo;local first_paint=true
            reader.view.paintTo=function(view,...)
                local result=paint(view,...)
                if first_paint then first_paint=false;timing('paint_drawn',open_started) end
                return result
            end
        end
        remember(reader.menu,{'setUpdateItemTable','_getTabIndexFromLocation','onShowMenu','last_tab_index'})
        if reader.menu then
            remember_array(reader.menu.tab_item_table)
            remember_array(reader.menu.registered_widgets)
            for _,tab in ipairs(reader.menu.tab_item_table or {}) do remember(tab,{'callback'}) end
        end
        self:_attachMenu(reader, proxy, callbacks)
        self:applyTouchZones(reader,proxy)
        if self.settings then self:applyProgressBar(reader) end
        proxy.flushProgress=function() if callbacks and callbacks.flush then return callbacks.flush(proxy) end end
        if callbacks and callbacks.read_settings then
            proxy.getReaderSettings = function()
                -- Native controls keep their latest values in modules until this event.
                -- Do not call saveSettings here: that flushes files and can reenter us.
                reader:handleEvent(require('ui/event'):new('SaveSettings'))
                local values = {}
                for key in pairs(reading_setting_keys(reader)) do values[key] = reader.doc_settings:readSetting(key) end
                return require('util').tableDeepCopy(values)
            end
        end
        proxy.getPagePosition = function()
            if proxy.closed or not reader.document then return nil end
            local total = reader.document.getPageCount and tonumber(reader.document:getPageCount())
                or reader.paging and tonumber(reader.paging.number_of_pages)
            local page = reader.getCurrentPage and tonumber(reader:getCurrentPage())
                or reader.paging and tonumber(reader.paging.current_page)
                or reader.document.getCurrentPage and tonumber(reader.document:getCurrentPage())
            if page and total and page >= 1 and total >= page then return page,total end
        end
        proxy.getProgressFraction = function()
            if reader.rolling and type(reader.rolling.getLastPercent) == "function" then
                return math.max(0, math.min(1, tonumber(reader.rolling:getLastPercent()) or 0))
            end
            local paging, document = reader.paging, reader.document
            if paging and type(paging.getLastPercent) == "function" then
                return math.max(0, math.min(1, tonumber(paging:getLastPercent()) or 0))
            end
            local pages = paging and tonumber(paging.number_of_pages)
            local page = paging and tonumber(paging.current_page)
            if not pages and document and type(document.getPageCount) == "function" then pages = tonumber(document:getPageCount()) end
            if not page and type(reader.getCurrentPage) == "function" then page = tonumber(reader:getCurrentPage()) end
            if not page and document and type(document.getCurrentPage) == "function" then page = tonumber(document:getCurrentPage()) end
            if pages and pages > 1 then
                return math.max(0, math.min(1, ((page or 1) - 1) / (pages - 1)))
            end
            return 0
        end
        proxy.setProgressFraction = function(_, fraction)
            fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
            local ok, result
            if reader.rolling and type(reader.rolling.onGotoPercent) == "function" then
                ok, result = pcall(reader.rolling.onGotoPercent, reader.rolling, fraction * 100)
            elseif reader.paging and type(reader.paging.onGotoPercentage) == "function" then
                ok, result = pcall(reader.paging.onGotoPercentage, reader.paging, fraction)
            else
                return nil, failure("KOReader progress restore API is unavailable")
            end
            if not ok then return nil, failure("KOReader progress restore failed", result) end
            return result == nil and true or result
        end
        if reader then
            local old_flush, old_close, old_handle = reader.onFlushSettings, reader.onClose, reader.handleEvent
            reader.onFlushSettings = function(instance, ...)
                if not proxy.closed and callbacks and callbacks.flush then pcall(callbacks.flush,proxy) end
                return old_flush and old_flush(instance, ...) or nil
            end
            reader.onClose = function(instance, ...)
                if proxy.closed then return end
                proxy.closed = true
                if self.current_document==proxy then self.current_document=nil end
                if proxy.chrome then proxy.chrome:close() end
                if callbacks and callbacks.close then pcall(callbacks.close,proxy) end
                return old_close and old_close(instance, ...) or nil
            end
            -- ReaderPaging emits EndOfBook through ReaderUI:handleEvent.  We
            -- intercept only our local generated document, and retain the
            -- original dispatch for the final chapter.
            proxy.forwardEnd = function()
                local Event = optional("ui/event")
                if old_handle and Event and type(Event.new) == "function" then return old_handle(reader, Event:new("EndOfBook")) end
            end
            reader.handleEvent = function(instance, event, ...)
                if event and callbacks then
                    if (event.handler == 'onSuspend' or event.handler == 'onReadingPaused') and callbacks.pause then callbacks.pause(proxy,event.handler=='onSuspend')
                    elseif (event.handler == 'onResume' or event.handler == 'onReadingResumed') and callbacks.resume then callbacks.resume(proxy) end
                end
                if event and event.handler == "onEndOfBook" and callbacks and callbacks.end_of_book then
                    callbacks.end_of_book(proxy)
                    return true
                end
                local result = old_handle and old_handle(instance, event, ...) or nil
                if not proxy.closed and event and callbacks and callbacks.page_update
                    and (event.handler == 'onPageUpdate' or event.handler == 'onPosUpdate' or event.handler == 'onDocumentRerendered') then
                    -- Native handlers must update the page and layout before we read them.
                    local page, total = proxy:getPagePosition()
                    callbacks.page_update(proxy, page, total)
                end
                return result
            end
        end
        proxy.chrome = ReaderChrome.new(reader, self.settings, proxy)
        if proxy.chrome then proxy.chrome:start() end
        initialized=true
        timing('native_adapter_init',initialize_started)
    end
    after_open=function(reader)
        if settled then return end
        local ok,cause=pcall(initialize,reader)
        if not ok then
            ready_error=startup_error('reader_ui_startup',cause)
            -- Abort ReaderUI:new; the path-scoped observer handles cleanup after unwinding.
            error(ready_error,0)
        end
        if not observed_do then ready() end
    end
    -- showReader schedules a coroutine, so pcall(showReader) alone misses its failures.
    -- Observe only this launch's file, and detach at its first terminal result.
    if callbacks and callbacks.read_settings and type(old_settings_handler) == 'function' then
        observed_settings = function(instance, event, ...)
            if event and event.handler == 'onReadSettings' and instance.document and instance.document.file == path then
                if callbacks.native_statistics and instance.statistics then
                    -- A novel is one statistics book. Native chapter-file records would double-count it.
                    remember(instance.statistics,{'onReaderReady'})
                    instance.statistics.onReaderReady=function() end
                    self.native_statistics=instance.statistics
                end
                -- Native doShowReader has closed the preceding chapter by now, so
                -- read its final saved values here, before any module reads settings.
                local values, err = callbacks.read_settings()
                if err then error(err, 0) end
                if type(values) == 'table' then
                    values = require('util').tableDeepCopy(values)
                    for key in pairs(reading_setting_keys(instance)) do
                        -- nil clears an older chapter override; false and 0 survive.
                        instance.doc_settings:saveSetting(key, values[key])
                    end
                end
                if reader_ui.handleEvent == observed_settings then reader_ui.handleEvent = saved_settings_handler end
            end
            return old_settings_handler(instance, event, ...)
        end
        reader_ui.handleEvent = observed_settings
    end
    if type(old_do)=='function' then
        -- Native showReader silently returns for missing files, without a completion event.
        local lfs=optional('libs/libkoreader-lfs')
        if lfs and type(lfs.attributes)=='function' then
            local ok,mode=pcall(lfs.attributes,path,'mode')
            if not ok or mode~='file' then
                failed(startup_error('reader_engine_open',not ok and mode or nil))
                return nil,ready_error
            end
        end
        observed_do=function(instance,file,...)
            if file~=path then return old_do(instance,file,...) end
            if callbacks and callbacks.can_open then
                local checked,current=pcall(callbacks.can_open)
                if not checked or not current then
                    failed(startup_error('reader_engine_open',Errors.new(Errors.CANCELLED,'阅读请求已取消。')))
                    return nil
                end
            end
            local engine_started=now()
            local ok,result=pcall(old_do,instance,file,...)
            timing('native_engine_open',engine_started)
            if not ok or not initialized then failed(ready_error or startup_error('reader_engine_open',not ok and result or nil))
            elseif not settled then ready() end
            return ok and result or nil
        end
        reader_ui.doShowReader=observed_do
    end
    if type(old_manager)=='function' then
        observed_manager=function(instance,file,...)
            if file~=path then return old_manager(instance,file,...) end
            failed(ready_error or startup_error('reader_engine_open'))
        end
        reader_ui.showFileManager=observed_manager
    end
    local ok,cause = pcall(reader_ui.showReader, reader_ui, path, nil, true, nil, after_open)
    if not ok then failed(ready_error or startup_error('reader_engine_open',cause)) end
    if ready_error then return nil, ready_error end
    return proxy
end

function Adapter:endOfBook(document)
    if document and type(document.forwardEnd) == "function" then return document.forwardEnd() end
    return false
end

return Adapter
