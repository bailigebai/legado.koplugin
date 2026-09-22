-- Session proxy for the independent Leko-derived reader (AGPL-3.0-or-later).
-- Construction/readiness belong here; Session owns commit, show and replacement.
local Reader=require('legado.ui.leko_reader')
local Errors=require('legado.lib.errors')
local Adapter={}

local function source_id(state)
    return state.source and (state.source.id or state.source.bookSourceUrl) or state.book.source_id
end

local function failure(value)
    if type(value)=='table' and value.code then return value end
    return Errors.new(Errors.STORAGE_ERROR,tostring(value or '独立阅读器未能就绪。'),{stage='reader_open'})
end

local function cancel_preparation(owner,clear)
    local ui=owner.ui_manager or (owner.current_document and owner.current_document.widget and owner.current_document.widget.ui)
    if owner.preparation_job and ui and ui.unschedule then ui:unschedule(owner.preparation_job) end
    owner.preparation_job=nil
    if clear then owner.prepared_chapters={};owner.previous_pagination=nil end
end
local function trim_preparation(owner,state)
    local records=owner.prepared_chapters or {}
    local kept={}
    for _,record in ipairs(records) do
        if record.source_id==source_id(state) and record.book_id==state.book.id and record.index>state.index and record.index<=state.index+3 then
            kept[#kept+1]=record
        end
    end
    table.sort(kept,function(a,b) return a.index<b.index end)
    local bytes,starts=0,owner.previous_pagination and #owner.previous_pagination.page_starts or 0
    for _,record in ipairs(kept) do bytes=bytes+record.prepared.input_bytes;starts=starts+#record.prepared.page_starts end
    while #kept>0 and (#kept>3 or bytes>8*1024*1024 or starts>10000) do
        local removed=table.remove(kept)
        bytes=bytes-removed.prepared.input_bytes;starts=starts-#removed.prepared.page_starts
    end
    owner.prepared_chapters=kept
end
local function schedule_preparation(owner)
    if owner.preparation_job then return end
    local document=owner.current_document
    local view=document and document.backend=='immersive' and not document.closed and document.widget
    if not view or view.paused then return end
    local fingerprint=view:getLayoutKey()
    local pending=false
    for _,record in ipairs(owner.prepared_chapters or {}) do
        if (record.prepared.layout_key~=fingerprint and record.failed_layout_key~=fingerprint)
            or (not record.prepared.complete and not record.failed) then pending=true;break end
    end
    if not pending then return end
    local function batch()
        if owner.preparation_job~=batch then return end
        owner.preparation_job=nil
        if owner.current_document~=document or document.closed or view.paused then return end
        -- Keep the active chapter ahead of background work. Both schedulers
        -- yield after a single page instead of combining four pages per tick.
        if not view.pagination_job then
            local rebuilding=false
            for _,record in ipairs(owner.prepared_chapters or {}) do
                if record.prepared.layout_key~=fingerprint and record.failed_layout_key~=fingerprint then
                    local ok,prepared,err=pcall(Reader.prepare,{source_id=record.source_id,book=document.book,
                        chapter=document.reading_state.chapters[record.index],body=record.prepared.body,style=view.style,
                        settings=owner.settings,chrome_heights=view.chrome_heights},record.prepared)
                    if not ok or not prepared then record.failed=failure(not ok and prepared or err);record.failed_layout_key=fingerprint
                    else record.prepared=prepared;record.failed,record.failed_layout_key=nil,nil end
                    rebuilding=true;break
                end
            end
            if not rebuilding then
            for _,record in ipairs(owner.prepared_chapters or {}) do
                if not record.prepared.complete and not record.failed then
                    local started=view:_now();local count=#record.prepared.page_starts
                    local ok,result,err=pcall(Reader.prepareNextPage,record.prepared,function() return view:_now() end)
                    view:_timing('pagination_batch',started,{over_budget=view:_now()-started>.008,pages=#record.prepared.page_starts-count})
                    if not ok or not result then record.failed=failure(not ok and result or err) end
                    break
                end
            end
            end
            trim_preparation(owner,document.reading_state)
        end
        schedule_preparation(owner)
    end
    owner.preparation_job=batch;view.ui:scheduleIn(.01,batch)
end

function Adapter.prepare(owner,state,chapter,body)
    local document=owner and owner.current_document
    local view=document and document.backend=='immersive' and not document.closed and document.widget
    if not view or document.reading_state~=state then return false end
    trim_preparation(owner,state)
    local previous,index
    for i,value in ipairs(state.chapters or {}) do if value.uid==chapter.uid then index=i;break end end
    if not index or index<=state.index or index>state.index+3 then return false end
    for _,record in ipairs(owner.prepared_chapters) do if record.chapter_uid==chapter.uid then previous=record;break end end
    local ok,prepared,err=pcall(Reader.prepare,{source_id=source_id(state),book=state.book,chapter=chapter,body=body,
        style=view.style,settings=owner.settings,chrome_heights=view.chrome_heights},previous and previous.prepared)
    if not ok or not prepared then return nil,failure(not ok and prepared or err) end
    if previous then previous.prepared=prepared;previous.failed,previous.failed_layout_key=nil,nil
    else owner.prepared_chapters[#owner.prepared_chapters+1]={source_id=source_id(state),book_id=state.book.id,chapter_uid=chapter.uid,index=index,prepared=prepared} end
    trim_preparation(owner,state);schedule_preparation(owner)
    for _,record in ipairs(owner.prepared_chapters) do if record.prepared==prepared then return true end end
    return false
end

function Adapter.preparedStatus(owner,state)
    local status={first_pages=0,paginated=0,total=0}
    local document=owner.current_document
    if not document or document.closed or document.backend~='immersive' or document.reading_state~=state then return status end
    local fingerprint=document.widget:getLayoutKey()
    for _,record in ipairs(owner.prepared_chapters or {}) do
        if record.source_id==source_id(state) and record.book_id==state.book.id and record.index>state.index and record.index<=state.index+3 then
            status.total=status.total+1
            if record.prepared.layout_key==fingerprint and not record.failed then
                status.first_pages=status.first_pages+1
                if record.prepared.complete then status.paginated=status.paginated+1 end
            end
        end
    end
    return status
end

function Adapter.open(owner,payload,callbacks)
    callbacks=callbacks or {}
    local function failed(err)
        err=failure(err)
        if callbacks.failure then pcall(callbacks.failure,err) end
        return nil,err
    end
    if type(owner)~='table' or type(payload)~='table' or type(payload.state)~='table' then
        return failed(Errors.new(Errors.INVALID_INPUT,'独立阅读会话参数不完整。'))
    end
    local state=payload.state
    local chapter=type(state.chapters)=='table' and state.chapters[state.index or 1]
    if type(chapter)~='table' then return failed(Errors.new(Errors.INVALID_INPUT,'独立阅读章节不存在。')) end
    local progress=type(payload.progress)=='table' and payload.progress or {}
    local proxy={backend='immersive',is_legado_document=true,closed=false,book=state.book,
        reading_state=state,reading_settings_key='immersive_style',restored_on_open=true,defer_notification=true}
    local accepted=false
    local pending_page,pending_total,page_pending
    local core={now=callbacks.now,timing=callbacks.timing}
    core.layout_changed=function() cancel_preparation(owner,false);schedule_preparation(owner) end
    local function update_catalog(view)
        view=view or proxy.widget
        view.count=#state.chapters;view.catalog_complete=state.catalog_complete
    end
    for _,method in ipairs{'getProgressFraction','setProgressFraction','getPosition','getReaderSettings',
        'flushProgress','close','pauseReading','resumeReading','animateEntry','requestChapter','runAction','showMenu'} do
        local name=method
        proxy[name]=function(_,...)
            if proxy.detached then
                if proxy.last_values[name]~=nil then return proxy.last_values[name] end
                return name=='close' or name=='flushProgress'
            end
            return proxy.widget[name](proxy.widget,...)
        end
    end
    function proxy:detach()
        local ok,snapshot=pcall(self.widget.getPaginationSnapshot,self.widget)
        if ok and #snapshot.page_starts<=10000 then owner.previous_pagination=snapshot end
        self.last_values={}
        for _,name in ipairs{'getProgressFraction','getPosition','getReaderSettings','getReadingContext'} do
            local ok,value=pcall(self[name],self);if ok then self.last_values[name]=value end
        end
        if self.last_values.getReadingContext then self.last_values.getReadingContext.active=false end
        self.detached,self.closed=true,true
    end
    function proxy:getReadingContext()
        if self.detached then return self.last_values.getReadingContext end
        update_catalog();return self.widget:getReadingContext()
    end
    function proxy:getPagePosition()
        if self.closed then return nil end
        local context=self:getReadingContext();return context.chapter_page,context.chapter_pages
    end
    function proxy:refreshAppearance()
        if self.closed then return false end
        update_catalog();return self.widget:refreshAppearance()
    end
    proxy.chrome={refresh=function() return proxy:refreshAppearance() end}
    for _,event in ipairs{'flush','pause','resume','end_of_book'} do
        local name=event
        core[name]=function(_, ...)
            if not accepted or proxy.closed then return true end
            local result,err=true,nil
            if callbacks[name] then result,err=callbacks[name](proxy,...) end
            if name=='pause' and (select(1,...)==true or (result~=false and not err)) then cancel_preparation(owner,false)
            elseif name=='resume' then schedule_preparation(owner) end
            return result,err
        end
    end
    core.close=function()
        proxy.closed=true
        if owner.current_document==proxy then cancel_preparation(owner,true);owner.current_document=nil end
        local current=owner.current_document
        if accepted and current and (current.backend~='immersive' or current.book.id~=state.book.id
            or source_id(current.reading_state)~=source_id(state)) then cancel_preparation(owner,true) end
        if accepted and callbacks.close then return callbacks.close(proxy) end
    end
    core.page_changed=function(_,page,total)
        if proxy.closed then return true end
        if not accepted then pending_page,pending_total,page_pending=page,total,true;return true end
        if callbacks.page_update then return callbacks.page_update(proxy,page,total) end
    end
    core.style_changed=function(_,style)
        if proxy.closed then return false end
        if not callbacks.save_style then return nil,failure('独立排版保存接口未连接。') end
        return callbacks.save_style(style)
    end
    core.context=function(view,base)
        update_catalog(view)
        base.chapter_count=view.count
        base.book_fraction=view.catalog_complete~=false and view.count>0 and (view.index-1+base.chapter_fraction)/view.count or nil
        if proxy.widget and callbacks.context then return callbacks.context(proxy,base) end
    end
    if callbacks.error then core.error=function(_,err) proxy.last_error=err;return callbacks.error(proxy,err) end end
    if callbacks.chapter or callbacks.refresh then
        core.chapter=function(_,index,request)
            if not accepted or proxy.closed then return false end
            if request.refresh and callbacks.refresh then return callbacks.refresh(request) end
            if callbacks.chapter then return callbacks.chapter(index,request) end
            return nil,failure('章节切换接口未连接。')
        end
    end
    if callbacks.refresh then core.refresh=function(view) return view:requestChapter(view.index,false,true) end end
    for action,handler in pairs{toc='on_toc',settings='on_settings',bookshelf='on_exit',receipt='on_receipt',
        review='on_review',sources='on_source_sites',statistics='on_statistics',toggle_reader='on_toggle_reader',
        book_info='on_book_info',add_to_shelf='on_add_to_shelf'} do
        local fn=owner[handler]
        if type(fn)=='function' then core[action]=function() if proxy.closed or not accepted then return false end;return fn(proxy) end end
    end
    -- An explicit mode-switch fraction is newer than a prior immersive cursor.
    local fraction=state.restore_fraction
    if fraction==nil and progress.chapter_uid==chapter.uid then fraction=progress.fraction end
    local previous=owner.current_document
    local prepared
    for _,record in ipairs(owner.prepared_chapters or {}) do
        if record.source_id==source_id(state) and record.book_id==state.book.id and record.chapter_uid==chapter.uid then prepared=record.prepared;break end
    end
    local options={book=state.book,chapter=chapter,index=state.index,count=#state.chapters,
        catalog_complete=state.catalog_complete,body=payload.body,settings=owner.settings,ui_manager=owner.ui_manager,
        style=progress.immersive_style,position=state.restore_fraction==nil and progress.immersive_position or nil,
        fraction=fraction,background=payload.background,callbacks=core,source_id=source_id(state),prepared=prepared,defer_tasks=true}
    local previous_state=previous and previous.reading_state
    local reuse=previous and previous.backend=='immersive' and not previous.closed and previous_state
        and previous_state.book.id==state.book.id and source_id(previous_state)==source_id(state)
        and (payload.background==nil or payload.background==previous.widget.background)
    if reuse then
        options.style=options.style or previous.widget.style
        local started=previous.widget:_now()
        local ok,value,err=pcall(Reader.prepare,options,prepared)
        if not ok or not value then return failed(not ok and value or err) end
        local snapshot=owner.previous_pagination
        if not prepared and snapshot and snapshot.key==value.key and snapshot.layout_key==value.layout_key then
            value.page_starts,value.pagination_position,value.complete=snapshot.page_starts,snapshot.pagination_position,snapshot.complete
            if fraction==1 and snapshot.last_page then options.position=snapshot.last_page end
        end
        if callbacks.timing then pcall(callbacks.timing,value==prepared and 'reader_layout_reused' or 'reader_layout_rebuilt',started) end
        -- Reader.prepare already built the first page for a matching layout.
        -- Repainting that page off-screen here duplicates the expensive Kindle
        -- work and blocks the first tap in the next chapter.
        options.skip_validation=prepared~=nil and value.layout_key==previous.widget:getLayoutKey()
        local widget=previous.widget
        proxy.reuses_widget=true
        local replaced;ok,replaced,err=pcall(widget.replaceChapter,widget,options,value,function(candidate)
            proxy.widget=candidate
            local result,cause=true,nil
            if callbacks.ready then result,cause=callbacks.ready(proxy) end
            if not result or cause then return nil,cause end
            if proxy.closed or candidate.closed then return nil,Errors.new(Errors.CANCELLED,'独立阅读候选已取消。') end
            previous:detach()
            return true
        end)
        if not ok or not replaced then proxy.closed=true;return failed(not ok and replaced or err) end
        proxy.widget=widget;accepted=true
        widget:_timing('reader_window_reused',started)
        trim_preparation(owner,state)
        cancel_preparation(owner,false)
        -- The outer adapter installs current_document after this call returns.
        owner.preparation_resume=function() schedule_preparation(owner) end
        return proxy
    end
    local ok,widget,err=pcall(Reader.new,options)
    if not ok or not widget then return failed(not ok and widget or err) end
    proxy.widget=widget
    local painted,paint_error=widget:validatePaint()
    if not painted then widget:close();return failed(paint_error) end
    if callbacks.ready then
        local ready,result,ready_error=pcall(callbacks.ready,proxy)
        if not ready or not result or ready_error then
            widget:close() -- Not accepted: no session flush/close callbacks or owner commit.
            return failed(not ready and result or ready_error)
        end
    end
    if proxy.closed then return failed(Errors.new(Errors.CANCELLED,'独立阅读候选已取消。')) end
    accepted=true
    local activated,activation_error=pcall(widget.activate,widget)
    if not activated then widget:_error(failure(activation_error)) end
    if page_pending then
        local notified,cause=pcall(core.page_changed,widget,pending_page,pending_total)
        if not notified then
            proxy.last_error=failure(cause)
            if callbacks.error then pcall(callbacks.error,proxy,proxy.last_error) end
        end
    end
    return proxy
end

return Adapter
