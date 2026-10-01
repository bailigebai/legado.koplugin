local Shelf = require("legado.ui.bookshelf")
local SearchView = require("legado.ui.search")
local SettingsView = require("legado.ui.settings")
local About = require("legado.ui.about")
local BookDetail = require("legado.ui.book_detail")
local Downloads = require("legado.ui.downloads")
local SideToc = require("legado.ui.side_toc")
local Models = require("legado.lib.models")
local ReadingHistory = require("legado.lib.reading_history")
local WeRead = require("legado.ui.weread")
local WeReadMapper = require('legado.lib.weread_mapper')

local App = {}
App.__index = App

function App.new(options)
    options = options or {}
    return setmetatable({
        version = options.version,
        storage = options.storage, service = options.book_service, source_manager = options.source_manager,
        settings = options.settings, settings_error = options.settings_error, appearance = options.appearance,
        reading_hook = options.reading_hook, download_hook = options.download_hook,
        reader_session = options.reader_session,
        download_manager = options.download_manager,
        weread_auth = options.weread_auth,
        weread_client = options.weread_client, weread_shelf_path = options.weread_shelf_path,
        weread_service = options.weread_service,
        ai_service = options.ai_service,
        cache_management = options.cache_management,
        presenter = options.presenter,
        default_download_cache_dir = options.default_download_cache_dir,
        validate_download_cache_dir = options.validate_download_cache_dir,
        scheduler = options.scheduler,
        cover_loader = options.cover_loader,
        fs = options.fs,
        local_library = options.local_library,
        native_statistics = options.native_statistics,
        license = options.license,
        show_native_statistics = options.show_native_statistics,
        show = options.show,
    }, App)
end

function App:_present(view)
    if type(self.show) == "function" then self.show(view) end
    return view
end

function App:openHome()
    return self:openBookshelf()
end

function App:openReadingReview(book, document, back)
    return self:_present({kind='reading_review',book=book,document=document,
        _back=back or (not document and function() return self:openBookshelf() end or nil)})
end

function App:openNativeStatistics(document)
    local session=self.reader_session
    if session then session:_statistics('checkpoint') end
    local statistics=session and session.ui and session.ui.native_statistics or self.native_statistics
    if statistics and self.show_native_statistics then return self.show_native_statistics(statistics,document) end
    if statistics and statistics.onShowTimeRange then return statistics:onShowTimeRange() end
    return self:_present({title='阅读统计',empty_text='请先在 KOReader 插件管理中启用“阅读统计”，打开一次统计页面后重试。'})
end

function App:isLicensed()
    return self.license and self.license:isAuthorized() == true
end

function App:toggleImmersiveReader(document)
    local session=self.reader_session
    local state=document and document.reading_state
    if not session or not state or document.closed or document.is_local or not self.settings then
        return nil,{code='INVALID_INPUT',message='当前页面不能切换阅读模式。'}
    end
    if self.reader_mode_request and self.reader_mode_request.document==document then return self.reader_mode_request.handle or true end
    local ok,fraction=pcall(document.getProgressFraction,document)
    if not ok or type(fraction)~='number' or fraction~=fraction or fraction<0 or fraction>1 then
        return nil,{code='STORAGE_ERROR',message='无法取得当前阅读位置，已保留原阅读模式。'}
    end
    local enabled=document.backend~='immersive'
    local request={document=document};self.reader_mode_request=request
    local completed,completion_result=false,nil
    local function complete(value,err)
        if completed then return completion_result end
        completed=true
        if self.reader_mode_request~=request then return false end
        self.reader_mode_request=nil
        completion_result=err and self:_present({title='阅读模式切换失败',
            text=(err.message or '新阅读页面未能打开。')..'\n已保留原阅读模式。'}) or value
        return completion_result
    end
    local opened,result,err=pcall(session.open,session,state.source,state.book,state.chapters,state.index,{
        backend=enabled and 'immersive' or 'native',restore_fraction=fraction,
        catalog_complete=state.catalog_complete,statistics_book_id=state.statistics_book_id,
        before_commit=function()
            local saved,save_error=self.settings:set('immersive_reader',enabled)
            if save_error and save_error.code=='RECOVERY_REQUIRED' then
                -- Keep the unreadable settings file intact. This preference is
                -- optional to reading; use an explicit session override only.
                session.preferred_backend=enabled and 'immersive' or 'native'
                self.reader_mode_temporary=true
                return true
            end
            if saved==nil or save_error then return nil,save_error or {code='STORAGE_ERROR',message='阅读模式设置保存失败。'} end
            session.preferred_backend=nil
            self.reader_mode_temporary=nil
            return true -- A successfully saved false is the native-mode preference.
        end,on_complete=complete})
    if not opened then
        -- pcall puts a thrown value in `result`, not `err`. Preserve structured
        -- reader failures so Kindle users can see the actual cause (font,
        -- pagination, or storage) instead of an unhelpful generic error.
        local thrown=result
        result=nil
        if type(thrown)=='table' then
            err=thrown
        else
            err={code='STORAGE_ERROR',message=tostring(thrown or '阅读模式切换未能启动。')}
        end
    end
    if not completed and (not result or err) then complete(nil,err or {code='STORAGE_ERROR',message='阅读模式切换未能启动。'}) end
    if not completed then request.handle=result end
    return completion_result or result
end

function App:exitReader(document)
    local from_weread=document and document.reading_state and document.reading_state.book
        and document.reading_state.book.source_id=='weread'
    if document and document.backend=='immersive' and not document.closed then
        local saved,err=document:close()
        if not saved then return nil,err end
    end
    if self.reader_session then
        self.reader_mode_request=nil
        local saved,err=self.reader_session:close()
        if not saved then return nil,err end
    end
    if from_weread then return self:openWeRead(function() return self:openBookshelf() end) end
    return self:openBookshelf(document and document.is_local and 'local' or nil)
end

function App:openReaderBookInfo(document)
    local state=document and document.reading_state
    local book=document and document.book or state and state.book
    if not book then return nil,{code='INVALID_INPUT',message='当前书籍信息不可用。'} end
    local detail=self:createBookDetail(book)
    detail.document=document
    detail._back=function() if self.scheduler then self.scheduler:setDirty(nil,'full') end end
    return self:_present(detail)
end

function App:addReaderToShelf(document)
    local state=document and document.reading_state
    local book=document and document.book or state and state.book
    if not book or not self.storage then return nil,{code='STORAGE_ERROR',message='书架尚未初始化。'} end
    local existing,err=self.storage:getBook(book.id)
    if err then return nil,err end
    local saved=existing
    if not saved then
        saved,err=self.storage:createBook(book)
    end
    if not saved and type(err)=='table' and err.code=='LICENSE_REQUIRED' then
        return self:_present({kind='license_required',continuation=function() return self:addReaderToShelf(document) end})
    end
    if not saved then return nil,err end
    self:_present({title='书架',text=existing and '本书已在书架中。' or '已加入书架。'})
    return saved
end

function App:openCurrentReceipt(document)
    local state=document and document.reading_state or self.reader_session and self.reader_session.active
    local book=document and document.book or state and state.book
    if book then return self:_present({kind='reading_receipt',book=book,document=document}) end
end

function App:createBookshelf(mode, restore)
    if not self.storage then return { title = "书架", empty_text = "书架尚未初始化" } end
    local page_size = self.settings and self.settings:get("shelf_page") or 20
    local covers_enabled = not self.settings or self.settings:get("covers_enabled") ~= false
    local view = Shelf.new({ storage = self.storage, settings = self.settings, page_size = page_size, covers_enabled = covers_enabled, cover_loader = self.cover_loader,
        is_cached = self.download_manager and function(book) return self.download_manager:isCached(book) end or nil,
        source_mode = mode or (self.settings and self.settings:get("shelf_source")) or "sources", local_library = self.local_library,
        on_search = function() return self:openSearch() end, on_sources = function() return self:openSources() end })
    if restore then
        view:setFilter(restore.reading_state, restore.category)
        view.start_page = restore.page
        view.batch_select = restore.batch_select
        view.selected_books = restore.selected_books
    end
    return view
end
function App:openBookshelf(mode, restore)
    return self:_present(self:createBookshelf(mode, restore))
end
function App:openSearch(keyword, back)
    if not self.service then return self:_present({ title = "搜索", error = "搜索服务尚未初始化", _back = back }) end
    local view = SearchView.new({
        service = self.service,
        source_provider = self.storage and function() return self.storage:listSources() end or nil,
    })
    view.initial_keyword = keyword
    view._back = back
    return self:_present(view)
end
function App:openSources(back)
    if self.source_manager then
        self.source_manager.on_search = function()
            return self:openSearch(nil, function() return self:openSources(back) end)
        end
    end
    if self.source_manager and type(self.source_manager.reopen) == "function" then self.source_manager:reopen() end
    local view = self.source_manager or { title = "书源管理", empty_text = "暂无书源" }
    view._back = back
    return self:_present(view)
end
function App:openDiscovery(back)
    if not self.service or not self.storage then return self:_present({ title = "发现", error = "书源服务尚未初始化", _back = back }) end
    local listed, err = self.storage:listSources()
    local read_error = type(listed) ~= "table" and (err or { code = "STORAGE_ERROR" }) or nil
    local sources = {}
    for _, source in ipairs(type(listed) == "table" and listed or {}) do
        sources[#sources + 1] = source
    end
    return self:_present({ kind = "discovery", service = self.service, sources = sources, _back = back,
        read_error = read_error, empty_text = #sources == 0 and not read_error and "请先导入书源" or nil })
end
function App:openReaderSourceSites(state, document, detail)
    local book=detail and detail.book or state and state.book
    if not book or not self.service or not self.storage then return nil end
    local view=require('legado.ui.source_matches').new{service=self.service,storage=self.storage,book=book,scheduler=self.scheduler}
    view.document,view.detail,view.loading=document,detail,true
    view._back=detail and function()
        local restored=self:createBookDetail(detail.book,detail.alternatives)
        restored.info,restored._back,restored.document=detail.info,detail._back,detail.document
        return self:_present(restored)
    end or nil
    view.onUpdate=function() if view.alive then self:_present(view) end end
    view.on_select=function(_,candidate,callback,row)
        if detail then
            detail.alternatives={candidate};detail:switchSource(1)
            return view._back()
        end
        return self:switchReaderSource(state,candidate,callback,row)
    end
    self:_present(view)
    view:start()
    return view
end

-- Retain the callable API for existing menu providers; both use exact site matching.
function App:openReaderSources(state, document) return self:openReaderSourceSites(state,document) end
function App:openReaderBookSearch(state, document) return self:openReaderSourceSites(state,document) end

function App:switchReaderSource(state, candidate, callback, row)
    if not state or not candidate or not self.reader_session or not self.service then return nil,{code='INVALID_INPUT'} end
    local source
    for _,value in ipairs(self.storage:listSources() or {}) do
        if Models.sourceId(value)==candidate.source_id and value.enabled~=false then source=value;break end
    end
    if not source then return nil,{code='STORAGE_ERROR',message='书源不存在或已停用'} end
    local cancelled,downstream=false,nil
    local handle={cancel=function()
        if cancelled then return false end
        cancelled=true
        local request=downstream
        downstream=nil
        if request and type(request.cancel)=='function' then pcall(request.cancel,request) end
        return true
    end}
    local function open(chapters,err,metadata)
        if cancelled then return end
        if err or not chapters or #chapters==0 then
            if callback then callback(nil,err or {code='PARSE_ERROR',message='目录为空'}) end
            return
        end
        local chapter=state.chapters and state.chapters[state.index or 1]
        local progress={chapter_title=chapter and chapter.title,chapter_index=state.index or 1}
        local index=self.reader_session.recoverIndex and self.reader_session:recoverIndex(chapters,progress)
            or math.max(1,math.min(#chapters,state.index or 1))
        local ok, opened=pcall(self.reader_session.open,self.reader_session,source,candidate,chapters,index,{on_complete=callback,
                reader_settings_book_id=state.book.id,
                statistics_book_id=state.statistics_book_id or state.book.id,
            is_current=function() return not cancelled end,
            catalog_complete=metadata and metadata.catalog_complete==true})
        if ok then downstream=opened elseif callback then pcall(callback,nil,{code='READER_OPEN_ERROR',message='打开新书源失败'}) end
    end
    if row and row.chapters and #row.chapters>0 then open(row.chapters,nil,row)
    else
        local completed=false
        local ok,request=pcall(self.service.getChapters,self.service,source,candidate,function(...)
            completed=true;return open(...)
        end)
        if not ok then return nil,{code='REQUEST_ERROR',message='切换书源请求启动失败'} end
        if not completed then downstream=request end
    end
    return handle
end
function App:openDownloads(back, start_picker)
    if not self.download_manager then return self:_present({ title = "下载管理", empty_text = "下载功能尚未初始化", _back = back }) end
    local view = Downloads.new({ manager = self.download_manager, scheduler = self.scheduler })
    view._back = back
    view.start_picker = start_picker == true
    return self:_present(view)
end
function App:openWeRead(back, restore)
    local view = WeRead.new({ auth = self.weread_auth, client = self.weread_client,
        fs = self.fs, path = self.weread_shelf_path, scheduler = self.scheduler, storage = self.storage })
    view._back = back
    if restore then view.display_page = restore.page end
    return self:_present(view)
end
function App:startWeReadReading(book,callback)
    callback=callback or function() end
    if not self.weread_service or not self.reader_session or not self.storage then
        callback(nil,{code='NETWORK_ERROR',message='微信读书阅读服务未初始化'})
        return nil
    end
    local cancelled,active,finished=false,nil,false
    local function deliver(value,err)
        if cancelled or finished then return end
        finished=true
        active=nil
        callback(value,err)
    end
    local function stage(start,done)
        local delivered=false
        local handle=start(function(...)
            delivered=true
            active=nil
            if not cancelled then done(...) end
        end)
        if not delivered then active=handle end
    end
    local function open(chapters)
        if cancelled then return end
        local cache=self.reader_session.cache
        if cache then cache:writeCatalog('weread',book.id,{chapters=chapters,complete=true}) end
        stage(function(done)
            return self.reader_session:resume({id='weread'},book,chapters,done,{catalog_complete=true})
        end,deliver)
    end
    local function progress(chapters)
        if cancelled then return end
        local existing,read_error=self.storage:getProgress(book.id)
        if read_error then return deliver(nil,read_error) end
        if existing then return open(chapters) end
        stage(function(done) return self.weread_client:getProgress(book.remote_id,done) end,function(wire)
            if type(wire)~='table' then
                return deliver(nil,{code='NETWORK_ERROR',message='微信读书阅读进度获取失败，请重试'})
            end
            local index,fraction=WeReadMapper.progress(wire,chapters)
            if index then
                local chapter=chapters[index]
                local saved,save_error=self.storage:putProgress({book_id=book.id,source_id='weread',chapter_uid=chapter.uid,
                    chapter_index=index,fraction=fraction,updated_at=os.time()})
                if not saved then return deliver(nil,save_error) end
            end
            open(chapters)
        end)
    end
    local function offline_after_catalog_failure(err)
        local failure=err or {code='NETWORK_ERROR',message='微信读书目录获取失败'}
        local existing,read_error=self.storage:getProgress(book.id)
        if read_error then return deliver(nil,read_error) end
        if not existing or type(self.reader_session.openOffline)~='function' then return deliver(nil,failure) end
        stage(function(done)
            return self.reader_session:openOffline({id='weread'},book,nil,done,{exact_progress=true})
        end,deliver)
    end
    stage(function(done) return self.weread_service:getChapters({id='weread'},book,done) end,function(chapters,err)
        if not chapters then return offline_after_catalog_failure(err) end
        progress(chapters)
    end)
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if active and active.cancel then active:cancel() end
        return true
    end}
end
function App:explainSelection(text, document)
    if not self.ai_service then return nil, { code = 'AI_UNAVAILABLE', message = 'AI 服务未初始化' } end
    if self.presenter and type(self.presenter.explainSelection)=='function' then
        return self.presenter:explainSelection(self.ai_service, text, document)
    end
    return self.ai_service:explain(text, nil, function() end)
end
function App:openSettings(document, chrome_only, back, section)
    local independent=document and type(document.refreshAppearance)=='function'
    local function refresh()
        if independent then return document:refreshAppearance() end
        if document and document.chrome then return document.chrome:refresh() end
    end
    local cache = self.reader_session and self.reader_session.cache
    local function no_active_downloads()
        local tasks = {}
        if self.storage and type(self.storage.listDownloadTasks) == 'function' then
            local ok, listed, list_error = pcall(self.storage.listDownloadTasks, self.storage)
            if not ok or type(listed) ~= 'table' then
                return nil,type(list_error) == 'table' and list_error
                    or {code='STORAGE_ERROR',message='下载任务读取失败'}
            end
            tasks = listed
        end
        for _,task in ipairs(tasks) do
            if type(task) ~= 'table' then
                return nil,{code='STORAGE_ERROR',message='下载任务记录无效'}
            end
            if task.status=='running' or task.status=='queued' or task.status=='cancelling' then
                return nil,{code='DOWNLOAD_ACTIVE',message='请等待下载结束或取消完成'}
            end
        end
        return true
    end
    local view=SettingsView.new({ settings = self.settings, settings_error = self.settings_error,
        ai_service = self.ai_service,
        plugin_cache_usage = self.cache_management and function() return self.cache_management:usage() end or nil,
        plugin_cache_clear = self.cache_management and function()
            local ready,err=no_active_downloads();if not ready then return nil,err end
            local state=self.reader_session and self.reader_session.active
            local keep=state and state.active and {source_id=state.book.source_id,book_id=state.book.id} or nil
            return self.cache_management:clear(keep)
        end or nil,
        default_download_cache_dir = self.default_download_cache_dir,
        validate_download_cache_dir = self.validate_download_cache_dir,
        temporary_reader_mode=self.reader_mode_temporary,
        chrome_only = chrome_only,document=document,
        cache_usage = cache and function() return cache:usage() end or nil,
        cache_cleanup = cache and function()
            local ready,err=no_active_downloads();if not ready then return nil,err end
            local state=self.reader_session and self.reader_session.active
            local keep=state and state.book and {source_id=state.book.source_id,book_id=state.book.id} or nil
            return cache:enforceLimit(self.settings:get('cache_limit_mb'),self.settings:get('cache_cleanup_threshold_mb'),self.settings:get('cache_retain_mb'),keep)
        end or nil,
        on_toggle_reader = document and function() return self:toggleImmersiveReader(document) end or nil,
        on_layout = independent and function() return document.widget:showLayoutMenu() end or nil,
        on_margins = document and not independent and function(index)
            local ok,err=self.reader_session.ui:applyMarginPreset(document.reader,index)
            if ok and document.flushProgress then return document:flushProgress() end
            return ok,err
        end or nil,
        on_chrome_change = document and refresh,
        on_background_change = document and function()
            if independent then return refresh() end
            local ok,err=require('legado.lib.reader_background').apply(document.reader and document.reader.document,self.settings)
            if document.reader and self.scheduler then self.scheduler:setDirty(document.reader,'ui') end
            return ok,err
        end,
        appearance = not independent and self.appearance or nil, local_library = self.local_library,
        on_sources = function() return self:openSources() end,
        on_close = not document and (back or function(local_changed) return self:openBookshelf(local_changed and 'local' or nil) end) or nil,
        on_progress_change = document and function()
            if independent then return refresh() end
            local applied = self.reader_session.ui:applyProgressBar(document.reader)
            if document.chrome then document.chrome:refresh() end
            return applied
        end,
        clear_cache = self.reader_session and self.reader_session.cache and function()
            local ready,err=no_active_downloads();if not ready then return nil,err end
            local state=self.reader_session.active
            return self.reader_session.cache:clear(state and state.active and {source_id=state.book.source_id,book_id=state.book.id} or nil)
        end or nil,
    })
    view.section=section
    return self:_present(view)
end
function App:openAbout(back)
    return self:_present({ kind = About.kind, title = About.title,
        text = "版本：" .. tostring(self.version or "未知") .. "\n\n" .. About.text, _back = back })
end
function App:startReading(book, chapters, index, callback, intent)
    if self.reading_hook then return self.reading_hook(book, chapters, index, callback, intent) end
    if not self.reader_session or not self.storage then return "阅读功能尚未初始化" end
    local on_progress=intent and intent.on_progress
    if on_progress then on_progress(1,'读取目录') end
    if book.is_local then
        local lfs=self.fs and self.fs.lfs
        local attr=lfs and lfs.attributes(book.local_path)
        if not attr or attr.mode~='file' then return nil,{code='STORAGE_ERROR',message='本地文件已移动或不可读'} end
        local saved,close_error=self.reader_session:close()
        if saved==false or close_error then return nil,close_error end
        self.storage:createBook(book)
        local started_at,paused,pending_progress
        local function progress(doc)
            local previous=pending_progress
            if not previous then
                local read_error
                if self.storage.getProgress then previous,read_error=self.storage:getProgress(book.id) end
                if read_error then return nil,read_error end
                previous=previous or {}
            end
            local now=os.time()
            local value=ReadingHistory.record(previous,book,started_at,now)
            value.book_id,value.source_id,value.fraction=book.id,'local',doc:getProgressFraction()
            value.chapter_index,value.updated_at=1,now
            if type(doc.getPagePosition)=='function' then
                local ok,page_index,page_count=pcall(doc.getPagePosition,doc)
                if ok then value.page_index,value.page_count=tonumber(page_index),tonumber(page_count) end
            end
            local saved,err=self.storage:putProgress(value)
            if not saved then
                pending_progress=value
                if not paused then started_at=now end
                return nil,err
            end
            pending_progress=nil
            if not paused then started_at=now end
            return true
        end
        return self.reader_session.ui:openDocument(book.local_path,{
            ready=function(doc) doc.is_local=true; doc.book=book; started_at=os.time(); if callback then callback(doc) end end,
            failure=function(err) if callback then callback(nil,err) end end,
            flush=progress,close=progress,
            pause=function(doc) if not paused then local saved,err=progress(doc);paused,started_at=true,nil;return saved,err end;return true end,
            resume=function() if paused then paused,started_at=false,os.time() end end,
        })
    end
    local function current()
        if not intent or type(intent.isCurrent) ~= "function" then return true end
        local ok, value = pcall(intent.isCurrent)
        return ok and value == true
    end
    local function request_complete()
        if not intent or type(intent.markRequestComplete) ~= "function" then return true end
        local ok, completed = pcall(intent.markRequestComplete)
        return ok and completed ~= false
    end
    local function replace_downstream(handle)
        if not intent or type(intent.replaceDownstream) ~= "function" then return true end
        local ok, replaced = pcall(intent.replaceDownstream, handle)
        if not ok or replaced == false then
            if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
            return false
        end
        return true
    end
    if not current() then return nil, { code = "CANCELLED", message = "阅读请求已失效" } end
    local source
    for _, candidate in ipairs(self.storage:listSources() or {}) do if Models.sourceId(candidate) == book.source_id then source = candidate; break end end
    if not source then return "书源不存在" end
    local function offline()
        return self.reader_session:openOffline(source, book, index, callback, { is_current = current, backend='immersive' })
    end
    if not self.service then return offline() end
    if type(chapters) == "table" and #chapters > 0 then
        if self.reader_session.cache and self.reader_session.cache.writeCatalog then
            self.reader_session.cache:writeCatalog(book.source_id,book.id,{chapters=chapters,complete=true})
        end
        if index then return self.reader_session:open(source, book, chapters, index, { on_complete = callback, is_current = current,on_progress=on_progress,backend='immersive' }) end
        return self.reader_session:resume(source, book, chapters, callback, { is_current = current,on_progress=on_progress,backend='immersive' })
    end
    local cache=self.reader_session.cache
    local offline_cache=self.reader_session.offline_cache
    local catalog=offline_cache and offline_cache:readCatalog(book.source_id,book.id)
    if not (catalog and catalog.complete == true) then
        catalog=cache and cache.readCatalog and cache:readCatalog(book.source_id,book.id)
    end
    local progress=self.storage.getProgress and self.storage:getProgress(book.id)
    local saved_chapters=catalog and (catalog.chapters or catalog)
    if saved_chapters and type(catalog.complete)=='boolean' and #saved_chapters>0 and (not progress or (progress.chapter_index or 1)<=#saved_chapters) then
        return self.reader_session:resume(source,book,saved_chapters,callback,{is_current=current,catalog_complete=catalog.complete==true,on_progress=on_progress,backend='immersive'})
    end
    return self.service:getChapters(source, book, function(values, err,metadata)
        if not current() then return end
        if not request_complete() then return end
        if not current() then return end
        if err or not values then
            local downstream, downstream_error = offline()
            replace_downstream(downstream)
            return downstream, downstream_error
        end
        if type(self.storage.replaceChapters) == "function" then self.storage:replaceChapters(book.id, values) end
        local complete=metadata and metadata.catalog_complete==true
        if not complete and #values > 10 then
            local first = {}; for i = 1, 3 do first[i] = values[i] end
            values = first
        end
        self.reader_session.cache:writeCatalog(book.source_id, book.id, { chapters = values, complete=complete })
        local downstream, downstream_error = self.reader_session:resume(source, book, values, callback, { is_current = current, catalog_complete=complete,on_progress=on_progress,backend='immersive' })
        replace_downstream(downstream)
        return downstream, downstream_error
    end, { max_pages = (not progress or (progress.chapter_index or 1)<=1) and 1 or nil,
        max_chapters = (not progress or (progress.chapter_index or 1)<=1) and 3 or nil })
end
function App:startDownload(book)
    if self.download_hook then return self.download_hook(book) end
    if self.download_manager then return self.download_manager:enqueue(book) end
    return "下载功能尚未初始化"
end
function App:startCache(book, end_index)
    if self.download_manager and type(self.download_manager.enqueueCache) == "function" then
        return self.download_manager:enqueueCache(book, nil, end_index)
    end
    return nil, { code = "STORAGE_ERROR", message = "离线缓存未初始化" }
end
local function native_catalog(document)
    local reader=document and document.reader
    local toc=reader and reader.toc
    if not toc then return {} end
    if toc.fillToc then pcall(toc.fillToc,toc) end
    local values={}
    for index,item in ipairs(toc.toc or {}) do
        values[#values+1]={title=item.title or item.text or ('第 '..index..' 章'),index=index,
            page=item.page,xpointer=item.xpointer,depth=item.depth}
    end
    return values
end

function App:openReadingSideToc(state,document)
    local native_items=not state and native_catalog(document) or nil
    if (state and (not state.book or type(state.chapters)~='table')) or (not state and not (document and document.reader)) then
        return self:_present({title='目录',empty_text='当前文档没有可用目录'})
    end
    local side
    local initial=state and state.chapters or native_items
    local complete=true
    if state then complete=state.catalog_complete~=false end
    local function flow_id(value)
        local book=value and value.book or {}
        local source_id=book.source_id or (value and value.source and Models.sourceId(value.source)) or ''
        return tostring(book.id or '')..'\0'..tostring(source_id)
    end
    local function current()
        -- A chapter navigation replaces ReaderSession.active with a new
        -- candidate before its completion callback fires. The drawer is
        -- still valid for that same reading flow; only its own close or a
        -- cancelled session should suppress a callback.
        if side.closed then return false end
        if not state or not self.reader_session or not self.reader_session.active then return true end
        return flow_id(self.reader_session.active)==flow_id(state)
    end
    local function load_page(page,done)
        if not state or not self.reader_session or state.catalog_complete~=false then
            done(state and state.chapters or native_items,true);return {cancel=function() end}
        end
        local target=page*15
        local cancelled,handle,attempts=false,nil,0
        local request
        request=function()
            attempts=attempts+1
            local attempt,completed=attempts,false
            local pending=self.reader_session:loadCatalog(state,function(chapters,err,metadata)
                completed=true
                if cancelled or not current() then return end
                local finished=not metadata or metadata.catalog_complete~=false
                local values=chapters or state.chapters
                -- A shared prefetch request may have a smaller chapter cap.
                -- Continue once with this page's explicit demand after it ends.
                if not err and not finished and #values<target and attempts==1 then return request() end
                done(values,finished,err)
            end,nil,{max_chapters=target})
            if attempts==attempt and not completed then handle=pending end
        end
        request()
        return {cancel=function()
            cancelled=true
            if handle and handle.cancel then handle:cancel() end
        end}
    end
    local function select_item(item,done)
        if not current() then return nil,{code='CANCELLED',message='阅读会话已切换'} end
        if state and self.reader_session then
            local selection={cancelled=false}
            local function selection_current() return current() and not selection.cancelled end
            local handle,err=self.reader_session:navigate(item.index,{is_current=selection_current,restore_fraction=item.fraction,bookmark=item.bookmark,
                on_complete=function(value,error_value)
                    if error_value then done(false,error_value) else done(true);side:close() end
                end})
            if err then done(false,err) end
            if handle and type(handle.cancel)=='function' then
                return {cancel=function()
                    selection.cancelled=true
                    return pcall(handle.cancel,handle)
                end}
            end
            return handle
        end
        local reader=document and document.reader
        if not reader or not reader.handleEvent then return nil,{code='READER_ERROR',message='原生目录跳转接口不可用'} end
        local Event=require('ui/event')
        local event=item.xpointer and Event:new('GotoXPointer',item.xpointer,item.xpointer)
            or Event:new('GotoPage',item.page)
        local ok,result=pcall(reader.handleEvent,reader,event)
        if not ok then done(false,{code='READER_ERROR',message=tostring(result)});return nil end
        done(true);side:close();return true
    end
    side=SideToc.new{items=initial,current_index=state and state.index,complete=complete,page_size=15,
        on_tab_items=function(tab,view)
            return require('legado.ui.reader_sidebar').items(self,state,document,view,tab)
        end,
        on_load_page=load_page,on_select=select_item,position=self.settings and self.settings:get('side_toc_position')}
    side.document=document
    if state then state.side_toc=side end
    side.on_close=function(view)
        if state and state.side_toc==view then state.side_toc=nil end
    end
    if state and not complete and #initial>=side.page_size then side:prefetchNextPage() end
    if type(self.show)=='function' then
        local widget,err=self.show({kind='side_toc',side=side,document=document,state=state})
        if not widget and err then self:_present({title='目录',text=err.message or '侧边目录显示失败'}) end
    end
    return side
end

-- Keep the old callable name for existing menu providers and tests; the
-- reading-page implementation is now the side overlay.
function App:openReadingCatalog(state,document)
    return self:openReadingSideToc(state,document)
end
function App:createBookDetail(book, alternatives)
    local page_size = self.settings and self.settings:get("shelf_page") or 20
    local covers_enabled = not self.settings or self.settings:get("covers_enabled") ~= false
    local shelf = self.storage and Shelf.new({ storage = self.storage, page_size = page_size, covers_enabled = covers_enabled, cover_loader = self.cover_loader }) or nil
    return BookDetail.new({
        book = book, alternatives = alternatives or { book }, shelf = shelf,
        service = self.service,
        catalog_lookup = self.reader_session and self.reader_session.offline_cache and function(selected)
            local catalog = self.reader_session.offline_cache:readCatalog(selected.source_id, selected.id)
            return catalog and catalog.complete == true and catalog.chapters or nil
        end or nil,
        source_lookup = self.storage and function(opaque_id)
            for _, source in ipairs(self.storage:listSources() or {}) do if Models.sourceId(source) == opaque_id then return source end end
        end or nil,
        compatibility = function(selected)
            if not selected or not self.source_manager or type(self.source_manager.compatibility) ~= "function" then return nil end
            local source = self.storage and (function()
                for _, candidate in ipairs(self.storage:listSources() or {}) do
                    if Models.sourceId(candidate) == selected.source_id then return candidate end
                end
            end)()
            return source and self.source_manager:compatibility(source.id) or nil
        end,
        cache_lookup = self.reader_session and function(chapter, current_book)
            local offline=self.reader_session.offline_cache
            if offline and offline:readBody(current_book.source_id,current_book.id,chapter) ~= nil then return true end
            return self.reader_session.cache:readBody(current_book.source_id, current_book.id, chapter) ~= nil
        end or nil,
        reading_hook = function(selected, selected_chapters, selected_index, selected_callback, intent)
            return self:startReading(selected, selected_chapters, selected_index, selected_callback, intent)
        end,
        download_hook = function(selected) return self:startDownload(selected) end,
        cache_hook = function(selected, end_index) return self:startCache(selected, end_index) end,
    })
end

function App:menuItems()
    return {
        { text = "书架", callback = function() return self:openBookshelf() end },
        { text = "搜索", callback = function() return self:openSearch() end },
        { text = "书源管理", callback = function() return self:openSources() end },
        { text = "下载管理", callback = function() return self:openDownloads() end },
        { text = "设置", callback = function() return self:openSettings() end },
        { text = "关于", callback = function() return self:openAbout() end },
        { text = "发现", callback = function() return self:openDiscovery() end },
    }
end

return App
