-- Independent text reader adapted from Leko/ReaderView.lua (AGPL-3.0-or-later),
-- jnjnnjzch/leko-reader 57dff8958dd43a5d95cb2dac22ca363d874de29b.
-- Chapter IO, persistence, catalog and application navigation belong to callbacks.
local InputContainer=require('ui/widget/container/inputcontainer')
local TextWidget=require('ui/widget/textwidget')
local TextBoxWidget=require('ui/widget/textboxwidget')
local Font=require('ui/font')
local Geom=require('ui/geometry')
local GestureRange=require('ui/gesturerange')
local Device=require('device')
local UIManager=require('ui/uimanager')
local BB=require('ffi/blitbuffer')
local Paginator=require('legado.lib.leko_paginator')
local Text=require('legado.lib.leko_text')
local Animation=require('legado.lib.leko_animation')
local Reader={}
local View=InputContainer:extend{covers_fullscreen=true,modal=false}
local TransparentTitle=TextBoxWidget:extend{bgcolor=BB.COLOR_BLACK,fgcolor=BB.COLOR_WHITE}
function TransparentTitle:paintTo(bb,x,y)
    self:getSize()
    -- TextBoxWidget normally blits an opaque white rectangle. Its monochrome
    -- title buffer is used as an alpha mask so the prepared background survives.
    bb:colorblitFrom(self._bb,x,y,0,0,self.width,self._bb:getHeight(),BB.COLOR_BLACK)
end
local defaults={body_font='cfont',title_font='cfont',body_font_size=27,title_font_size=34,
    line_spacing=.28,paragraph_spacing=10,margin_left=28,margin_right=28,indent=true,
    show_header=true,show_footer=true,title_bold=true,layout_version=2,page_transition='swipe',
    chapter_clean_wave_enabled=false,swipe_refresh_mode='ui',swipe_portrait_delay_ms=20,swipe_landscape_delay_ms=10}
local function copy(value)
    local result={};for key,item in pairs(value or {}) do result[key]=item end;return result
end
local function error_value(message) return {code='READER_ERROR',message=tostring(message)} end
local function safe_event(self, callback, ...)
    local ok, first, second = xpcall(callback, debug.traceback, ...)
    if ok then return first, second end
    local err = error_value(first)
    self.last_error = err
    pcall(function() self:_error(err) end)
    return false, err
end
local function free(widgets)
    for _,item in ipairs(widgets or {}) do if item.widget and item.widget.free then pcall(item.widget.free,item.widget) end end
end
local function finite(n) return type(n)=='number' and n==n and n>-math.huge and n<math.huge end
local function normalized_style(values)
    local style=copy(defaults);for k,v in pairs(values or {}) do style[k]=v end
    for key,range in pairs{body_font_size={12,72},title_font_size={12,96},line_spacing={0,2},paragraph_spacing={0,100},
        margin_left={0,180},margin_right={0,180},swipe_portrait_delay_ms={0,200},swipe_landscape_delay_ms={0,200}} do
        local n=tonumber(style[key]);if not finite(n) or n<range[1] or n>range[2] then return nil,error_value('排版参数无效：'..key) end
        style[key]=n
    end
    if not ({off=true,original=true,swipe=true,ripple=true})[style.page_transition] then return nil,error_value('翻页效果无效。') end
    if not ({ui=true,fast=true})[style.swipe_refresh_mode] then return nil,error_value('动画刷新模式无效。') end
    for _,key in ipairs{'body_font','title_font'} do
        if type(style[key])~='string' or #style[key]>4096 or style[key]:find('%c') then return nil,error_value('字体路径无效。') end
    end
    for _,key in ipairs{'body_font_index','title_font_index'} do
        if style[key]~=nil then
            local n=tonumber(style[key]);if not finite(n) or n<0 or n>65535 or n%1~=0 then return nil,error_value('字体面索引无效。') end
            style[key]=n
        end
    end
    for _,key in ipairs{'indent','show_header','show_footer','title_bold','chapter_clean_wave_enabled'} do
        if type(style[key])~='boolean' then return nil,error_value('阅读开关参数无效：'..key) end
    end
    return style
end
function View:_call(name,...)
    local fn=self.callbacks and self.callbacks[name]
    if type(fn)~='function' then return true end
    local ok,result,err=pcall(fn,self,...)
    if not ok then return nil,error_value(result) end
    return result,err
end
function View:_error(err)
    err=type(err)=='table' and err or error_value(err)
    self.last_error=err
    if self.callbacks.error then self:_call('error',err)
    else
        local ok,notification=pcall(function() return require('ui/widget/notification'):new{text=err.message} end)
        if ok and notification then pcall(UIManager.show,UIManager,notification) end
    end
    return nil,err
end
function View:_setting(key,default)
    local value=self.settings and self.settings:get(key)
    if value==nil then return default end
    return value
end
function View:_chromeTextHeight(size,scale)
    if not self.chrome_heights or self.chrome_heights.scale~=scale then self.chrome_heights={scale=scale} end
    local height=self.chrome_heights[size]
    if not height then
        local probe=TextWidget:new{text='测',face=Font:getFace('cfont',size),padding=0}
        local ok,size_value=pcall(probe.getSize,probe);probe:free()
        if not ok then error(size_value,0) end
        height=size_value.h;self.chrome_heights[size]=height
    end
    return height
end
function View:_layoutStyle(style)
    local value=copy(style)
    local screen=Device.screen
    local scale=screen:scaleBySize(1000)/1000
    -- The paginator takes logical heights; its rounding must still reserve
    -- every physical pixel measured by the native text widget.
    local function logicalHeight(pixels)
        local units=math.ceil(pixels/scale)
        while screen:scaleBySize(units)<pixels do units=units+1 end
        return units
    end
    local layout={pad=screen:scaleBySize(8),vpad=screen:scaleBySize(4),gap=screen:scaleBySize(3),bar_height=math.max(1,screen:scaleBySize(2))}
    local top,bottom=false,false
    for _,key in ipairs{'tl','tc','tr'} do
        layout[key]=self:_setting('reader_corner_'..key,({tl='time',tc='title',tr='chapter_page'})[key]);if layout[key]~='off' then top=true end
    end
    for _,key in ipairs{'bl','br'} do
        layout[key]=self:_setting('reader_corner_'..key,({bl='chapter',br='progress'})[key]);if layout[key]~='off' then bottom=true end
    end
    local mode=self:_setting('progress_bar_mode','details')
    if self:_setting('progress_bar',true)==false then mode='hidden' end
    layout.mode=mode
    value.show_header=style.show_header and top
    value.show_footer=style.show_footer and (bottom or mode~='hidden')
    value.header_height,value.footer_height=0,0
    if value.show_header then
        layout.header_size=tonumber(self:_setting('reader_header_font_size',11)) or 11
        layout.header_text_height=self:_chromeTextHeight(layout.header_size,scale)
        value.header_height=logicalHeight(layout.header_text_height+2*layout.vpad)
    end
    if value.show_footer then
        layout.footer_row_height=0
        if bottom then
            layout.footer_size=tonumber(self:_setting('reader_footer_font_size',11)) or 11
            layout.footer_text_height=self:_chromeTextHeight(layout.footer_size,scale)
            layout.footer_row_height=layout.footer_text_height+2*layout.vpad
        end
        local progress_height=0
        if mode~='hidden' then
            layout.progress_content_height=layout.bar_height
            if mode=='details' then
                layout.progress_size=tonumber(self:_setting('progress_bar_font_size',12)) or 12
                layout.progress_text_height=self:_chromeTextHeight(layout.progress_size,scale)
                layout.progress_content_height=layout.progress_text_height+layout.gap+layout.bar_height
            end
            progress_height=math.max(layout.progress_content_height+2*layout.vpad,
                screen:scaleBySize(math.max(16,math.min(48,tonumber(self:_setting('progress_bar_height',24)) or 24))))
        end
        value.footer_height=logicalHeight(layout.footer_row_height+progress_height)
    end
    value._chrome_layout=layout
    return value
end
local function layout_key(style)
    local parts={tostring(Device.screen:getWidth()),tostring(Device.screen:getHeight()),tostring(Device.screen:scaleBySize(1000)),
        tostring(Device.screen.getRotationMode and Device.screen:getRotationMode() or 0)}
    for _,values in ipairs{style,style._chrome_layout} do
        local entries={}
        for key,value in pairs(values or {}) do
            if type(value)~='table' then entries[#entries+1]=key..'='..type(value)..':'..tostring(value) end
        end
        table.sort(entries);parts[#parts+1]=table.concat(entries,'\n')
    end
    return table.concat(parts,'\n')
end
local function chapter_identity(options)
    return table.concat({tostring(options.source_id or ''),tostring(options.book.id or ''),
        tostring(options.chapter.uid or options.chapter.url or ''),tostring(options.chapter.title or '')},'\n')
end
-- Preparation holds one text model and one page description, never widgets,
-- framebuffers, menus or scheduled work. Native faces remain owned by Font.
function Reader.prepare(options,previous)
    if type(options.body)~='string' or type(options.chapter)~='table' or type(options.book)~='table' then
        return nil,error_value('阅读章节参数不完整。')
    end
    local style,err=normalized_style(options.style);if not style then return nil,err end
    local identity=chapter_identity(options)
    local model=previous and previous.identity==identity and previous.body==options.body and previous.model
    if not model then model,err=Text.parse(options.body,options.chapter.title);if not model then return nil,err end end
    local key=identity..'\n'..model.checksum
    Text.metrics(model)
    local context=setmetatable({settings=options.settings,chrome_heights=options.chrome_heights},{__index=View})
    local layout=context:_layoutStyle(style)
    local fingerprint=layout_key(layout)
    if previous and previous.key==key and previous.layout_key==fingerprint then return previous end
    local pagination_book={chapters={{id=options.chapter.uid or options.chapter.url or tostring(options.index)}},models={model}}
    local page;page,err=Paginator:makePage(pagination_book,{chapter=1,paragraph=1,char=1},layout)
    if not page then return nil,error_value(err) end
    return {key=key,identity=identity,body=options.body,layout_key=fingerprint,model=model,page=page,chrome_heights=context.chrome_heights,
        pagination_book=pagination_book,layout=layout,input_bytes=#options.body,
        page_starts={Text.positionCopy(page.start_position)},pagination_position=Text.positionCopy(page.next_position),complete=page.at_end==true}
end
-- One scheduled unit computes at most one page, with no persistent bitmaps.
function Reader.prepareNextPage(prepared,now,make_page)
    if prepared.complete then return true end
    now=now or os.clock
    prepared.deadline=now()+.008
    if not prepared.pagination_task then
        prepared.pagination_task=coroutine.create(function()
            local function checkpoint() if now()>=prepared.deadline then coroutine.yield() end end
            if make_page then return make_page(prepared.pagination_position,checkpoint) end
            return Paginator:makePage(prepared.pagination_book,prepared.pagination_position,prepared.layout,checkpoint)
        end)
    end
    local ok,page,err=coroutine.resume(prepared.pagination_task)
    if not ok then prepared.pagination_task=nil;return nil,error_value(page) end
    if coroutine.status(prepared.pagination_task)~='dead' then return true end
    prepared.pagination_task=nil
    if not page then return nil,error_value(err) end
    if not page.at_end and not Text.positionLess(prepared.pagination_position,page.next_position) then
        return nil,error_value('章节分页未能前进。')
    end
    prepared.page_starts[#prepared.page_starts+1]=Text.positionCopy(page.start_position)
    prepared.pagination_position=Text.positionCopy(page.next_position)
    prepared.complete=page.at_end==true
    return true,page
end
function View:_makePage(position,style,checkpoint)
    local ok,page,err=pcall(Paginator.makePage,Paginator,self.pagination_book,position,self:_layoutStyle(style or self.style),checkpoint)
    if not ok or not page then return nil,error_value(not ok and page or err) end
    return page
end
function View:_makeWidgets(page)
    local widgets={};local g=page.geometry;local y=g.body_top+g.header_height
    local ok,err=pcall(function()
        for _,element in ipairs(page.elements) do
            if element.type=='gap' then y=y+element.height
            else
                y=y+(element.top_gap or 0)
                local options={text=element.text,face=element.face or g.body_face,padding=0,lang='zh-CN',bold=element.bold or false,
                    width=g.content_width,height=element.height,line_height=element.line_height or self.style.line_spacing,alignment='left',alignment_strict=true}
                local widget=element.type=='title' and TransparentTitle:new(options) or TextWidget:new(options)
                widgets[#widgets+1]={widget=widget,x=g.left,y=y}
                widget:getSize()
                y=y+element.height+(element.bottom_gap or 0)
            end
        end
    end)
    if not ok then free(widgets);return nil,error_value(err) end
    return widgets
end
function View:_pageNumber(position)
    local found,low,high=nil,1,#(self.page_starts or {})
    while low<=high do local middle=math.floor((low+high)/2)
        if Text.positionLess(position,self.page_starts[middle]) then high=middle-1 else found=middle;low=middle+1 end
    end
    if self.page_total or (found and self.page_starts[found+1]) then return found end
end
function View:_notifyPage()
    self.current_page=self:_pageNumber(self.page.start_position)
    self:_call('page_changed',self.current_page,self.page_total)
end
function View:_finishAnimation(cancel)
    local ok,err=pcall(cancel and self.animation.cancel or self.animation.settle,self.animation)
    if not ok then pcall(self.animation.cancel,self.animation);self:_error(err) end
end
function View:_setPage(page,direction,prepared_widgets)
    if self.closed then return nil,error_value('阅读器已经关闭。') end
    local widgets,err=prepared_widgets,nil
    if not widgets then widgets,err=self:_makeWidgets(page) end
    if not widgets then return nil,err end
    local started=self.page_input_started or self:_now()
    if self.page_input_started then self:_timing('page_prepare',started) end
    self.page_input_started=nil
    self.paint_started=started
    self:_finishAnimation(true)
    local previous=self.widgets
    self.page,self.widgets=page,widgets
    if page.style._font_fallback_pending then
        for _,key in ipairs{'body_font','body_font_index','body_font_display_name','title_font','title_font_index','title_font_display_name'} do self.style[key]=page.style[key] end
        self.font_fallback=true
    end
    if previous~=widgets then free(previous) end
    self:_notifyPage()
    if direction and self.style.page_transition~='off' then
        local timing=self.callbacks.timing
        local ok,animated=pcall(self.animation.begin,self.animation,self,direction,function(_,painted)
            if timing then pcall(timing,'animation_submit',started) end
            if not self.closed and not painted then self.ui:setDirty(self,'ui') end
        end,
            {effect=self.style.page_transition,chapter_changed=self.chapter_changed==true,
                chapter_clean_wave_enabled=self.style.chapter_clean_wave_enabled,refresh_mode=self.style.swipe_refresh_mode,
                portrait_delay_ms=self.style.swipe_portrait_delay_ms,landscape_delay_ms=self.style.swipe_landscape_delay_ms})
        self.chapter_changed=false
        if not ok then self:_finishAnimation(true);self:_error(animated)
        elseif animated then self:_timing('animation_start',started);return true end
    end
    if not self.defer_tasks then self.ui:setDirty(self,'partial') end
    return true
end
function View:_cancelJob(key)
    local job=self[key]
    self[key]=nil
    if job and self.ui.unschedule then pcall(self.ui.unschedule,self.ui,job) end
end
function View:_startPagination(prepared)
    self:_cancelJob('pagination_job')
    if not prepared then self:_call('layout_changed') end
    self.page_starts=prepared and prepared.page_starts or {}
    self.page_total=prepared and prepared.complete and #self.page_starts or nil
    self.pagination_position=prepared and prepared.pagination_position or {chapter=1,paragraph=1,char=1}
    self.pagination_generation=(self.pagination_generation or 0)+1
    local generation=self.pagination_generation
    prepared=prepared or {page_starts=self.page_starts,pagination_position=self.pagination_position,
        pagination_book=self.pagination_book,layout=self:_layoutStyle(self.style),model=self.model}
    self.pagination_prepared=prepared
    if self.page_total then
        if self.go_last then
            self.go_last=nil
            local page=self:_makePage(self.page_starts[self.page_total]);if page then self:_setPage(page) end
        end
        self:_notifyPage();return
    end
    local function batch()
        if self.closed or self.pagination_generation~=generation then return end
        self.pagination_job=nil
        safe_event(self,function()
        for _=1,1 do
            local started=self:_now();local count=#prepared.page_starts
            local ok,page=Reader.prepareNextPage(prepared,function() return self:_now() end,
                function(position,checkpoint) return self:_makePage(position,nil,checkpoint) end)
            self:_timing('pagination_batch',started,{over_budget=self:_now()-started>.008,pages=#prepared.page_starts-count})
            if not ok then self:_error(page);return end
            if not page then self.pagination_job=batch;self.ui:scheduleIn(.01,batch);return end
            if self.previous_target and not Text.positionLess(page.next_position,self.previous_target) then
                local position=Text.positionLess(page.start_position,self.previous_target) and page.start_position or self.page_starts[#self.page_starts-1]
                self.previous_target=nil
                if position then local previous=self:_makePage(position);if previous then self:_setPage(previous,'backward') end end
            end
            if page.at_end then
                self.page_total=#self.page_starts
                if prepared then prepared.complete=true;prepared.pagination_position=Text.positionCopy(page.next_position) end
                if self.go_last then
                    self.go_last=nil
                    local last=self:_makePage(self.page_starts[self.page_total]);if last then self:_setPage(last) end
                end
                self:_notifyPage();self.ui:setDirty(self,'ui');return
            end
            if not Text.positionLess(self.pagination_position,page.next_position) then self:_error('章节分页未能前进。');return end
            self.pagination_position=page.next_position
            if prepared then prepared.pagination_position=Text.positionCopy(page.next_position) end
        end
        self.pagination_job=batch;self.ui:scheduleIn(.01,batch)
        end)
    end
    self.pagination_job=batch;self.ui:scheduleIn(0,batch)
end
function View:_now()
    if self.callbacks and self.callbacks.now then return self.callbacks.now() end
    return os.clock()
end
function View:_timing(stage,started,details)
    if self.callbacks and self.callbacks.timing then pcall(self.callbacks.timing,stage,started,details) end
end
function View:_startClock()
    self:_cancelJob('clock_job')
    local function tick()
        if self.closed or self.clock_job~=tick then return end
        safe_event(self,function()
            if not self.paused and (not self.ui.getTopmostVisibleWidget or self.ui:getTopmostVisibleWidget()==self) and not self.animation:isRunning() then
                local g=self.page.geometry
                if self.page.style.show_header then self.ui:setDirty(self,'ui',Geom:new{x=0,y=0,w=self.dimen.w,h=g.body_top+g.header_height}) end
            end
        end)
        if not self.closed and self.clock_job==tick then
            safe_event(self,function() self.ui:scheduleIn(60,tick) end)
        end
    end
    self.clock_job=tick;self.ui:scheduleIn(60,tick)
end
local function initial_position(options,model)
    local position={chapter=1,paragraph=1,char=1}
    local last=finite(tonumber(options.fraction)) and tonumber(options.fraction)==1 or nil
    if finite(tonumber(options.fraction)) then position=Text.positionAt(model,tonumber(options.fraction)) end
    local saved=options.position
    if type(saved)=='table' and saved.content_checksum==model.checksum and saved.chapter_uid==options.chapter.uid then
        local paragraph,char=tonumber(saved.paragraph),tonumber(saved.char)
        if finite(paragraph) and paragraph%1==0 and paragraph>=1 and paragraph<=#model.paragraphs
            and finite(char) and char%1==0 and char>=1 and char<=Text.utf8Length(model.paragraphs[paragraph]) then
            position={chapter=1,paragraph=paragraph,char=char};last=nil
        end
    end
    return position,last
end
-- The candidate owns only new text widgets. It borrows immutable display
-- resources, validates off-screen, and cannot replace live callbacks until
-- persistence/session commit has accepted it.
function View:replaceChapter(options,prepared,commit)
    if self.closed then return nil,error_value('阅读器已经关闭。') end
    local style,err=normalized_style(options.style);if not style then return nil,err end
    local candidate=setmetatable({book=options.book,chapter=options.chapter,index=options.index,count=options.count,
        catalog_complete=options.catalog_complete,model=prepared.model,style=style,callbacks=options.callbacks or {},
        source_id=options.source_id,settings=self.settings,ui=self.ui,dimen=self.dimen,
        pagination_book=prepared.pagination_book,page_starts=prepared.page_starts,
        page_total=prepared.complete and #prepared.page_starts or nil,chrome_heights=prepared.chrome_heights,
        background=self.background,background_widget=self.background_widget,background_painter=self.background_painter,
        closed=false,paused=false,history={}}, {__index=View})
    -- A readiness observer may cancel. The candidate never owns the live
    -- clock/background/animation, and its text resources remain owned below.
    candidate.close=function(view) view.closed=true;view:_call('close');return true end
    candidate._dispose=candidate.close
    local position;position,candidate.go_last=initial_position(options,prepared.model)
    if candidate.go_last and prepared.complete then position=prepared.page_starts[#prepared.page_starts];candidate.go_last=nil end
    candidate.page=prepared.page
    if not Text.positionEqual(candidate.page.start_position,position) then
        candidate.page,err=candidate:_makePage(position);if not candidate.page then return nil,err end
    end
    candidate.widgets,err=candidate:_makeWidgets(candidate.page);if not candidate.widgets then return nil,err end
    if not options.skip_validation then
        local painted;painted,err=candidate:validatePaint()
        if not painted then free(candidate.widgets);return nil,err end
    end
    local ok,accepted,cause=pcall(commit,candidate)
    if not ok or not accepted or cause then
        free(candidate.widgets);return nil,not ok and error_value(accepted) or cause or error_value('章节提交未完成。')
    end
    self:_finishAnimation(true)
    local previous_widgets=self.widgets
    for _,key in ipairs{'book','chapter','index','count','catalog_complete','model','style','callbacks','source_id',
        'pagination_book','page_starts','page_total','chrome_heights','page','widgets','history','paused','go_last'} do
        self[key]=candidate[key]
    end
    self.chapter_generation=(self.chapter_generation or 0)+1
    self.chapter_request,self.chapter_pending,self.previous_target=nil,nil,nil
    free(previous_widgets)
    local scheduled,cause=pcall(self._startPagination,self,prepared)
    if not scheduled then self:_error(cause) end
    return true
end
function View:init()
    self.ui=self.ui_manager or UIManager
    self.callbacks=self.callbacks or {}
    self.closed,self.paused=false,false
    self.history={}
    self.dimen=Geom:new{x=0,y=0,w=Device.screen:getWidth(),h=Device.screen:getHeight()}
    self.animation=Animation:new{screen=Device.screen,ui_manager=self.ui,device=Device}
    self.pagination_book={chapters={{id=self.chapter.uid or self.chapter.url or tostring(self.index)}},models={self.model}}
    self.page_starts=self.initial_prepared and self.initial_prepared.page_starts or {}
    self.page_total=self.initial_prepared and self.initial_prepared.complete and #self.page_starts or nil
    self.ges_events={Tap={GestureRange:new{ges='tap',range=function() return self.dimen end}},Hold={GestureRange:new{ges='hold',range=function() return self.dimen end}},
        Swipe={GestureRange:new{ges='swipe',range=function() return self.dimen end}}}
    self.key_events={Close={{'Back'},{'Esc'}},ReaderMenu={{'Menu'}},PageForward={{'Right'},{'RPgFwd'},{'LPgFwd'},{'PgFwd'}},
        PageBackward={{'Left'},{'RPgBack'},{'LPgBack'},{'PgBack'}}}
    local position;position,self.go_last=initial_position(self,self.model)
    if self.go_last and self.page_total then position=self.page_starts[self.page_total];self.go_last=nil end
    local page=self.initial_page;self.initial_page=nil
    local err
    if not page or not Text.positionEqual(page.start_position,position) then page,err=self:_makePage(position) end
    if not page then error(err.message,0) end
    local success;success,err=self:_setPage(page);if not success then error(err.message,0) end
    self:refreshBackground()
    if not self.defer_tasks then self:_startPagination(self.initial_prepared);self.initial_prepared=nil;self:_startClock() end
end
function View:activate()
    if self.closed then return false end
    if self.defer_tasks then self.defer_tasks=nil;self:_startPagination(self.initial_prepared);self.initial_prepared=nil;self:_startClock() end
    return true
end
function View:refreshBackground()
    local value=self.background
    if value==nil and self.settings and self:_setting('reader_background','')~='' then
        local err;value,err=require('legado.lib.reader_background').prepare(self.settings)
        if err then return self:_error(err) end
    end
    local image
    if type(value)=='string' and value~='' then
        local pending
        local ok,result=pcall(function()
            pending=require('ui/widget/imagewidget'):new{file=value,width=self.dimen.w,height=self.dimen.h,scale_factor=1}
            pending:getSize();return pending
        end)
        if not ok then if pending and pending.free then pcall(pending.free,pending) end;return self:_error(result) end
        image=result
    end
    if self.background_widget and self.background_widget.free then self.background_widget:free() end
    self.background_widget=image
    self.background_painter=type(value)=='function' and value or type(value)=='table' and value.paintTo and function(_,bb,x,y) value:paintTo(bb,x,y) end or nil
    return true
end
function View:_paintLabel(bb,text,x,y,width,align,size)
    local label=TextWidget:new{text=tostring(text or ''),face=Font:getFace('cfont',size or 11),max_width=math.max(1,width),padding=0}
    local ok,err=pcall(function()
        local s=label:getSize();local xx=x+(align=='right' and width-s.w or align=='center' and math.floor((width-s.w)/2) or 0)
        label:paintTo(bb,xx,y)
    end)
    label:free();if not ok then error(err,0) end
end
function View:_paintTo(bb,x,y)
    if self.closed or not self.page then return end
    x,y=x or 0,y or 0
    bb:paintRect(x,y,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
    if self.background_widget then self.background_widget:paintTo(bb,x,y) end
    if self.background_painter then self.background_painter(self,bb,x,y) end
    for _,item in ipairs(self.widgets) do item.widget:paintTo(bb,x+item.x,y+item.y) end
    local g=self.page.geometry;local layout=self.page.style._chrome_layout;local context=self:getReadingContext()
    local values={time=os.date('%H:%M'),title=self.book.name or self.book.title or '',chapter=self.chapter.title or '',off='',
        chapter_page=(context.chapter_page or '—')..'/'..(context.chapter_pages or '—'),
        progress=context.book_fraction and string.format('约 %.1f%%',context.book_fraction*100) or '目录加载中'}
    local pad=layout.pad;local w=self.dimen.w-2*pad;local quarter=math.floor(w/4)
    if self.page.style.show_header then
        local header_y=y+g.body_top+math.floor((g.header_height-layout.header_text_height)/2)
        for _,entry in ipairs{{'tl',pad,quarter,'left'},{'tc',pad+quarter,w-quarter*2,'center'},{'tr',pad+w-quarter,quarter,'right'}} do
            self:_paintLabel(bb,values[layout[entry[1]]] or '',x+entry[2],header_y,entry[3],entry[4],layout.header_size)
        end
    end
    if self.page.style.show_footer then
        local footer_y=y+self.dimen.h-g.footer_height
        if layout.footer_row_height>0 then
            local row_y=footer_y+math.floor((layout.footer_row_height-layout.footer_text_height)/2)
            self:_paintLabel(bb,values[layout.bl] or '',x+pad,row_y,math.floor(w*.65),'left',layout.footer_size)
            self:_paintLabel(bb,values[layout.br] or '',x+pad+math.floor(w*.65),row_y,w-math.floor(w*.65),'right',layout.footer_size)
        end
        if layout.mode~='hidden' then
            local progress_y=footer_y+layout.footer_row_height+math.floor((g.footer_height-layout.footer_row_height-layout.progress_content_height)/2)
            if layout.mode=='details' then
                local text=string.format('本章 %d%%',math.floor(self:getProgressFraction()*100+.5))..' · '..(context.chapter_remaining_text or '时间待估算')
                local pending=context.prefetch
                if self.chapter_pending then text=text..' · 正在准备章节'
                elseif type(pending)=='table' and tonumber(pending.total) and tonumber(pending.cached) and pending.total>pending.cached then text=text..string.format(' · 缓存 %d/%d',pending.cached,pending.total) end
                self:_paintLabel(bb,text,x+pad,progress_y,w,'center',layout.progress_size)
                progress_y=progress_y+layout.progress_text_height+layout.gap
            end
            bb:paintRect(x+pad,progress_y,w,layout.bar_height,BB.COLOR_LIGHT_GRAY)
            bb:paintRect(x+pad,progress_y,math.floor(w*self:getProgressFraction()),layout.bar_height,BB.COLOR_BLACK)
        end
    end
end
function View:paintTo(bb,x,y)
    return safe_event(self,function()
        local started=self.paint_started or self:_now()
        self:_paintTo(bb,x,y)
        self.paint_started=nil
        self:_timing('paint_drawn',started)
        return true
    end)
end
function View:validatePaint()
    local started=self:_now()
    local target
    local ok,err=xpcall(function()
        local screen=Device.screen.bb
        target=BB.new(self.dimen.w,self.dimen.h,screen and screen.getType and screen:getType() or nil)
        self:_paintTo(target,0,0)
    end,debug.traceback)
    if target then pcall(target.free,target) end
    self:_timing('reader_validate',started)
    if not ok then return nil,error_value(err) end
    return true
end
function View:getPosition()
    if not self.page then return copy(self.last_position) end
    local p=self.page.start_position
    return {chapter_uid=self.chapter.uid,paragraph=p.paragraph,char=p.char,content_checksum=self.model.checksum}
end
function View:getPaginationSnapshot()
    return {key=chapter_identity(self)..'\n'..self.model.checksum,layout_key=layout_key(self:_layoutStyle(self.style)),
        page_starts=self.page_starts,pagination_position=self.pagination_position,complete=self.page_total~=nil,
        last_page=self.page.at_end and self:getPosition() or nil}
end
function View:getLayoutKey() return layout_key(self:_layoutStyle(self.style)) end
function View:getProgressFraction()
    if not self.page then return self.last_fraction or 0 end
    return Text.fraction(self.model,self.page.start_position)
end
function View:setProgressFraction(value)
    value=tonumber(value);if not finite(value) or value<0 or value>1 then return nil,error_value('章节进度无效。') end
    local page,err=self:_makePage(Text.positionAt(self.model,value));if not page then return nil,err end
    self.history={};self.go_last=value==1
    if value==1 and self.page_total then page=self:_makePage(self.page_starts[self.page_total]);self.go_last=nil end
    return self:_setPage(page)
end
function View:getReaderSettings() return copy(self.style) end
function View:getReadingContext()
    if not self.page then local context=copy(self.last_context);context.active=false;return context end
    local fraction=self:getProgressFraction()
    local context={api_version=1,active=not self.closed,book_id=self.book.id,title=self.book.name or self.book.title,author=self.book.author,
        chapter_title=self.chapter.title,chapter_index=self.index,chapter_count=self.count,chapter_page=self:_pageNumber(self.page.start_position),
        chapter_pages=self.page_total,chapter_fraction=fraction,chapter_progress=fraction,
        book_fraction=self.catalog_complete~=false and self.count and self.count>0 and (self.index-1+fraction)/self.count or nil}
    local extra=self:_call('context',context)
    if type(extra)=='table' then for _,key in ipairs{'reading_seconds','chapter_remaining','book_remaining','chapter_remaining_text','prefetch'} do context[key]=extra[key] end end
    return context
end
function View:flushProgress() return self:_call('flush') end
function View:pauseReading(suspend)
    if self.closed then return true end
    if suspend and self.pagination_job then self:_cancelJob('pagination_job');self.pagination_suspended=true end
    if self.paused then if suspend then return self:_call('pause',true) end;return true end
    self:_finishAnimation();local result,err=self:_call('pause',suspend)
    if (result==false or err) and not suspend then return nil,err end
    self.paused=true;return true
end
function View:resumeReading()
    if self.closed or not self.paused then return true end
    self.paused=false
    if self.pagination_suspended then self.pagination_suspended=nil;self:_startPagination(self.pagination_prepared) end
    self:_call('resume');self.ui:setDirty(self,'ui');return true
end
function View:_resumeIfVisible()
    if self.ui.getTopmostVisibleWidget and self.ui:getTopmostVisibleWidget()==self then return self:resumeReading() end
    return false
end
function View:requestChapter(index,last_page,refresh)
    if self.closed then return false end
    local input_started=self:_now()
    if index<1 then return self:_error('已经是第一章。') end
    if self.count and self.catalog_complete~=false and index>self.count then
        if self.callbacks.end_of_book then return self:_call('end_of_book',input_started) end
        return self:_error('已经是最后一章。')
    end
    if not self.callbacks.chapter then return self:_error('章节切换接口未连接。') end
    local pending=self.chapter_pending
    if pending and pending.index==index and pending.last_page==(last_page==true) and pending.refresh==(refresh==true) then
        return self.chapter_request or true
    end
    self:_finishAnimation()
    if self.chapter_request and self.chapter_request.cancel then pcall(self.chapter_request.cancel,self.chapter_request) end
    self.chapter_request=nil
    self.chapter_generation=(self.chapter_generation or 0)+1
    local generation=self.chapter_generation
    self.chapter_pending={index=index,last_page=last_page==true,refresh=refresh==true}
    local function status_dirty()
        if not self.closed and self.page then
            local height=self.page.geometry.footer_height
            if height>0 then self.ui:setDirty(self,'ui',Geom:new{x=0,y=self.dimen.h-height,w=self.dimen.w,h=height}) end
        end
    end
    status_dirty()
    local handle,err=self:_call('chapter',index,{last_page=last_page==true,refresh=refresh==true,input_started=input_started,
        is_current=function() return not self.closed and generation==self.chapter_generation end,
        on_complete=function(_,completion_error)
            if self.closed or generation~=self.chapter_generation then return end
            self.chapter_pending,self.chapter_request=nil,nil
            if completion_error then self:_error(completion_error) end
            status_dirty()
        end})
    if self.closed then
        if type(handle)=='table' and handle.cancel then pcall(handle.cancel,handle) end
        return false
    end
    if handle==false or err then self.chapter_pending=nil;status_dirty();return self:_error(err or '章节请求未完成。') end
    self.chapter_request=self.chapter_pending and type(handle)=='table' and handle or nil
    if not self.chapter_request then self.chapter_pending=nil end
    return handle or true
end
function View:nextPage()
    if self.closed then return false end
    if self.page.at_end then return self:requestChapter(self.index+1,false) end
    self.page_input_started=self:_now()
    local page,err=self:_makePage(self.page.next_position);if not page then return self:_error(err) end
    local previous=Text.positionCopy(self.page.start_position)
    local ok;ok,err=self:_setPage(page,'forward')
    if ok then
        -- ponytail: keep 256 recent cursor entries; older backward navigation uses canonical chapter boundaries.
        if #self.history==256 then table.remove(self.history,1) end
        self.history[#self.history+1]=previous
    end
    return ok,err
end
function View:previousPage()
    if self.closed then return false end
    self.page_input_started=self:_now()
    local position=self.history[#self.history]
    if position then
        local page,err=self:_makePage(position);if not page then return self:_error(err) end
        local ok;ok,err=self:_setPage(page,'backward');if ok then table.remove(self.history) end;return ok,err
    end
    local current=self.page.start_position
    if current.paragraph==1 and current.char==1 then return self:requestChapter(self.index-1,true) end
    local number=self:_pageNumber(current)
    if number then
        local start=self.page_starts[number]
        local target=Text.positionLess(start,current) and start or self.page_starts[number-1]
        if target then local page,err=self:_makePage(target);if not page then return self:_error(err) end;return self:_setPage(page,'backward') end
    end
    self.previous_target=Text.positionCopy(current)
    return true
end
function View:applyStyle(changes)
    local candidate=copy(self.style);for key,value in pairs(changes or {}) do candidate[key]=value end
    if changes and changes.body_font and changes.body_font_index==nil then candidate.body_font_index=nil end
    if changes and changes.title_font and changes.title_font_index==nil then candidate.title_font_index=nil end
    local style,err=normalized_style(candidate);if not style then return nil,err end
    local page;page,err=self:_makePage(self.page.start_position,style);if not page then return nil,err end
    local widgets;widgets,err=self:_makeWidgets(page);if not widgets then return nil,err end
    local saved,save_error=self:_call('style_changed',copy(style))
    if saved==false or save_error then free(widgets);return nil,save_error or error_value('阅读设置保存失败。') end
    local previous=self.style;self.style=style
    local success;success,err=self:_setPage(page,nil,widgets);if not success then free(widgets);self.style=previous;return nil,err end
    self.history={};self.previous_target=nil;self:_startPagination();return true
end
function View:animateEntry(direction,chapter_changed)
    self.chapter_changed=chapter_changed==true
    return self:_setPage(self.page,direction,self.widgets)
end
function View:refreshAppearance()
    self:_finishAnimation()
    self:refreshBackground()
    self.chrome_heights=nil
    local page,err=self:_makePage(self.page.start_position);if not page then return nil,err end
    local ok;ok,err=self:_setPage(page);if ok then self:_startPagination() end;return ok,err
end
function View:runAction(name)
    if self.closed then return false end
    if name=='previous_chapter' then return self:requestChapter(self.index-1,false) end
    if name=='next_chapter' then return self:requestChapter(self.index+1,false) end
    if name=='layout' then return self:showLayoutMenu() end
    if not self.callbacks[name] then return self:_error('功能接口未连接：'..name) end
    local paused,pause_error=self:pauseReading()
    if not paused then return self:_error(pause_error or '阅读进度保存失败。') end
    local result,err=self:_call(name)
    if result==false or err then self:resumeReading();return self:_error(err or '操作未完成。') end
    return result or true
end
function View:showMenu()
    if self.closed then return false end
    if self.menu_dialog then return true end
    self:pauseReading()
    local buttons={}
    for _,row in ipairs{{{'回到书架','bookshelf'},{'关闭无感阅读','toggle_reader'}},{{'章节目录','toc'},{'书籍详情','book_info'}},
        {{'上一章','previous_chapter'},{'下一章','next_chapter'}},{{'阅读设置','layout'},{'重新获取本章','refresh'}},
        {{'插件设置','settings'},{'当前书籍小票','receipt'}},{{'阅读回顾','review'},{'切换站点书源','sources'}},{{'阅读统计','statistics'}}} do
        local cells={}
        for _,entry in ipairs(row) do
            if self.callbacks[entry[2]] or entry[2]=='layout' or entry[2]=='previous_chapter' or entry[2]=='next_chapter' then
                local name=entry[2]
                cells[#cells+1]={text=entry[1],callback=function()
                    local ok,result=xpcall(function() self:_closeDialog('menu_dialog');return self:runAction(name) end,debug.traceback)
                    if not ok then return self:_error(result) end
                    return result
                end}
            end
        end
        if #cells>0 then buttons[#buttons+1]=cells end
    end
    if self.callbacks.add_to_shelf then buttons[#buttons+1]={{text='加入书架',callback=function() self:_closeDialog('menu_dialog');self:runAction('add_to_shelf') end}} end
    buttons[#buttons+1]={{text='继续阅读',callback=function() self:_closeDialog('menu_dialog');self:resumeReading() end}}
    self.menu_dialog=require('ui/widget/buttondialog'):new{title=self.book.name or self.book.title or '阅读',buttons=buttons,
        tap_close_callback=function() self.menu_dialog=nil;self:resumeReading() end}
    local ok,err=pcall(self.ui.show,self.ui,self.menu_dialog)
    if not ok then self.menu_dialog=nil;return self:_error(err) end
    return true
end
function View:_closeDialog(key)
    local dialog=self[key];self[key]=nil
    if dialog then pcall(self.ui.close,self.ui,dialog) end
end
function View:showLayoutMenu()
    if self.closed then return false end
    self:pauseReading();self:_closeDialog('layout_dialog')
    local function update(changes)
        local ok,err=self:applyStyle(changes);if not ok then self:_error(err) end
        self:showLayoutMenu()
    end
    local function cycle(key,values)
        local closest=1
        for i,value in ipairs(values) do if math.abs(value-self.style[key])<math.abs(values[closest]-self.style[key]) then closest=i end end
        update{[key]=values[closest%#values+1]}
    end
    local buttons={
        {{text='字体',callback=function()
            self:_closeDialog('layout_dialog')
            local font_view=require('legado.ui.leko_font_selection'):new{style=self.style,
                on_selected=function(font)
                    local ok,err=self:applyStyle{body_font=font.font_path,body_font_index=font.face_index,body_font_display_name=font.display_name,
                        title_font=font.font_path,title_font_index=font.face_index,title_font_display_name=font.display_name}
                    if not ok then self:_error(err) end
                end,
                on_return=function() self.font_dialog=nil;self:showLayoutMenu() end}
            self.font_dialog=font_view;self.ui:show(font_view)
        end},{text='字号：'..self.style.body_font_size,callback=function() cycle('body_font_size',{18,22,27,32,38,44}) end}},
        {{text='行距：'..self.style.line_spacing,callback=function() cycle('line_spacing',{.12,.20,.28,.38,.50}) end},
         {text='段落间距：'..self.style.paragraph_spacing,callback=function() cycle('paragraph_spacing',{0,6,10,16,24}) end}},
        {{text='页边距：'..self.style.margin_left,callback=function()
            local values=Paginator.MARGINS.values;local i=Paginator.MARGINS:index(self.style.margin_left) or 3;local margin=values[i%#values+1];update{margin_left=margin,margin_right=margin}
        end},{text='首行缩进：'..(self.style.indent and '开' or '关'),callback=function() update{indent=not self.style.indent} end}},
        {{text='页眉：'..(self.style.show_header and '显示' or '隐藏'),callback=function() update{show_header=not self.style.show_header} end},
         {text='页脚：'..(self.style.show_footer and '显示' or '隐藏'),callback=function() update{show_footer=not self.style.show_footer} end}},
        {{text='动画效果：'..({off='关闭',original='原版翻页',swipe='擦除渐显',ripple='水波纹'})[self.style.page_transition],callback=function()
            update{page_transition=({off='original',original='swipe',swipe='ripple',ripple='off'})[self.style.page_transition]}
        end},{text='跨章净屏动画：'..(self.style.chapter_clean_wave_enabled and '开' or '关'),callback=function() update{chapter_clean_wave_enabled=not self.style.chapter_clean_wave_enabled} end}},
        {{text='刷新模式：'..(self.style.swipe_refresh_mode=='fast' and '快速' or '清晰'),callback=function() update{swipe_refresh_mode=self.style.swipe_refresh_mode=='fast' and 'ui' or 'fast'} end}},
        {{text='竖屏帧延时：'..self.style.swipe_portrait_delay_ms..'ms',callback=function() cycle('swipe_portrait_delay_ms',{0,10,20,30,50,80}) end},
         {text='横屏帧延时：'..self.style.swipe_landscape_delay_ms..'ms',callback=function() cycle('swipe_landscape_delay_ms',{0,10,20,30,50,80}) end}},
    }
    if Device.hasFrontlight and Device:hasFrontlight() then buttons[#buttons+1]={{text='屏幕亮度',callback=function()
        self:_closeDialog('layout_dialog');self.ui:broadcastEvent(require('ui/event'):new('ShowFlDialog'))
    end}} end
    buttons[#buttons+1]={{text='继续阅读',callback=function() self:_closeDialog('layout_dialog');self:resumeReading() end}}
    self.layout_dialog=require('ui/widget/buttondialog'):new{title='阅读设置',buttons=buttons,rows_per_page=8,
        tap_close_callback=function() self.layout_dialog=nil;self:resumeReading() end}
    local ok,err=pcall(self.ui.show,self.ui,self.layout_dialog)
    if not ok then self.layout_dialog=nil;return self:_error(err) end
    return true
end
function View:onTap(_,ges) return safe_event(self, function()
    local x=ges and ges.pos and ges.pos.x or self.dimen.w/2;local y=ges and ges.pos and ges.pos.y or self.dimen.h/2
    if self.callbacks.toc and require('legado.ui.side_toc').isActivationTap(x,y,self.dimen.w,self.dimen.h) then return self:runAction('toc') end
    if y<=self.dimen.h*.12 or (x>=self.dimen.w*.38 and x<=self.dimen.w*.62 and y>=self.dimen.h*.36 and y<=self.dimen.h*.64) then return self:showMenu() end
    self:_resumeIfVisible()
    if x<self.dimen.w*.16 then return self:previousPage() end
    return self:nextPage()
end) end
function View:onSwipe(_,ges) return safe_event(self, function()
    self:_resumeIfVisible()
    if ges and ges.direction=='west' then return self:nextPage() end
    if ges and ges.direction=='east' then return self:previousPage() end
    return self:showMenu()
end) end
function View:onHold() return safe_event(self, function() return self:showMenu() end) end
function View:onReaderMenu() return safe_event(self, function() return self:showMenu() end) end
function View:onPageForward() return safe_event(self, function() self:_resumeIfVisible();return self:nextPage() end) end
function View:onPageBackward() return safe_event(self, function() self:_resumeIfVisible();return self:previousPage() end) end
function View:onFlushSettings() return safe_event(self, function() return self:flushProgress() end) end
function View:onSuspend() return safe_event(self, function() self:pauseReading(true);return self:flushProgress() end) end
function View:onResume() return safe_event(self, function() return self:_resumeIfVisible() end) end
function View:onReadingPaused() return safe_event(self, function() return self:pauseReading() end) end
function View:onReadingResumed() return safe_event(self, function() return self:_resumeIfVisible() end) end
function View:onSetDimensions(dimen) return safe_event(self, function()
    if dimen then self.dimen=Geom:new{x=0,y=0,w=dimen.w,h=dimen.h} end
    return self:refreshAppearance()
end) end
function View:onRotation() return safe_event(self, function() self:_finishAnimation();return false end) end
View.onIterateRotation=View.onRotation;View.onSwapRotation=View.onRotation;View.onInvertRotation=View.onRotation
function View:onClose() return safe_event(self, function()
    if self.menu_dialog then self:_closeDialog('menu_dialog');return self:resumeReading() end
    if self.callbacks.bookshelf then return self:runAction('bookshelf') end
    return self:close()
end) end
function View:_dispose()
    if self.closed then return false end
    for key,method in pairs{last_position='getPosition',last_fraction='getProgressFraction',last_context='getReadingContext'} do
        local ok,value=pcall(self[method],self);if ok then self[key]=value end
    end
    self.closed=true;self.pagination_generation=(self.pagination_generation or 0)+1
    self:_finishAnimation(true);self:_cancelJob('pagination_job');self:_cancelJob('clock_job')
    if self.chapter_request and self.chapter_request.cancel then pcall(self.chapter_request.cancel,self.chapter_request) end
    self.chapter_request,self.chapter_pending=nil,nil
    self:_closeDialog('menu_dialog');self:_closeDialog('layout_dialog');self:_closeDialog('font_dialog')
    free(self.widgets);self.widgets={}
    if self.background_widget and self.background_widget.free then pcall(self.background_widget.free,self.background_widget) end
    self.background_widget,self.background_painter,self.background=nil,nil,nil;self:_call('close')
    self.model,self.page,self.pagination_book,self.prepared_chapter,self.pagination_prepared,self.initial_prepared=nil,nil,nil,nil,nil,nil
    self.page_starts,self.history={},{}
    return true
end
function View:close()
    if self.closed then return true end
    local ok,saved,err=xpcall(function() return self:flushProgress() end,debug.traceback)
    if not ok then return nil,error_value(saved) end
    if saved==false or err then return nil,err or error_value('阅读进度保存失败。') end
    local disposed,dispose_error=pcall(self._dispose,self)
    if not disposed then self.closed=true;return nil,error_value(dispose_error) end
    local closed,close_error=pcall(self.ui.close,self.ui,self,'full')
    if not closed then return nil,error_value(close_error) end
    return true
end
function View:onCloseWidget()
    local ok,err=pcall(self._dispose,self)
    if not ok then self.closed=true;self.last_error=error_value(err);return false end
    return true
end
function Reader.new(options)
    options=copy(options)
    if type(options.body)~='string' or type(options.chapter)~='table' or type(options.book)~='table' then return nil,error_value('阅读章节参数不完整。') end
    local ok,prepared,err=pcall(Reader.prepare,options,options.prepared)
    if not ok or not prepared then return nil,not ok and error_value(prepared) or err end
    local style;style,err=normalized_style(options.style);if not style then return nil,err end
    options.style,options.model,options.body=style,prepared.model,nil
    options.initial_page,options.chrome_heights,options.initial_prepared,options.prepared=prepared.page,prepared.chrome_heights,prepared,nil
    local index,count=tonumber(options.index),tonumber(options.count)
    if index~=nil and (not finite(index) or index<1 or index%1~=0) then return nil,error_value('章节序号无效。') end
    if count~=nil and (not finite(count) or count<1 or count%1~=0) then return nil,error_value('章节数量无效。') end
    options.index,options.count=index or 1,count
    local ok,view=pcall(View.new,View,options)
    if not ok then
        -- KOReader Widget.new initializes the supplied table in place. Reclaim
        -- resources allocated before a later font/background/settings error.
        if options.animation then pcall(View._dispose,options) end
        return nil,error_value(view)
    end
    return view
end
Reader.DEFAULT_STYLE=defaults
return Reader
