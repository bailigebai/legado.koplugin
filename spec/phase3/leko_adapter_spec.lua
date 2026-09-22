package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local loaded,Adapter=pcall(require,'legado.lib.leko_reader_ui')
eq(true,loaded,'independent session adapter is available')
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',150)..'</p>'
local state={book={id='book',name='测试书'},chapters={{uid='c1',title='第一章'},{uid='c2',title='第二章'}},index=1,catalog_complete=false}
local progress={book_id='book',chapter_uid='c1',fraction=.2,immersive_style={body_font_size=30,page_transition='off'},
    immersive_position={chapter_uid='c1',content_checksum=require('legado.lib.identity').hash(body),paragraph=1,char=31}}
local old={closed=false};local owner={settings={get=function() end},ui_manager=h.ui,current_document=old}
local counts={ready=0,closed=0,flush=0,pause=0,resume=0,failure=0};local calls,events={},{}
for _,name in ipairs{'toc','settings','exit','receipt','review','source_sites','statistics','toggle_reader','book_info','add_to_shelf'} do
    owner['on_'..name]=function(proxy) calls[#calls+1]={name=name,proxy=proxy};return true end
end
local saved_style,requested,refresh_request,refused_style,refused_pause,refused_flush
local cancellations=0
local callbacks={
    ready=function(proxy)
        counts.ready=counts.ready+1
        eq(0,#events,'constructor page notifications wait until ready accepts')
        eq('immersive',proxy.backend,'ready receives a fully bound independent proxy')
        eq(31,proxy:getPosition().char,'exact per-book cursor restores before readiness')
        return true
    end,
    failure=function() counts.failure=counts.failure+1 end,
    page_update=function(proxy,page,total) events[#events+1]={proxy=proxy,page=page,total=total} end,
    flush=function(proxy) counts.flush=counts.flush+1;if refused_flush then return nil,{code='STORAGE_ERROR'} end;return true end,
    pause=function() counts.pause=counts.pause+1;if refused_pause then return nil,{code='STORAGE_ERROR'} end;return true end,
    resume=function() counts.resume=counts.resume+1 end,
    close=function(proxy) counts.closed=counts.closed+1;eq(true,proxy.closed,'close callback observes final proxy state') end,
    save_style=function(style) saved_style=style;if refused_style then return nil,{code='STORAGE_ERROR'} end;return true end,
    chapter=function(index,request) requested={index=index,request=request};return {cancel=function() cancellations=cancellations+1 end} end,
    refresh=function(request) refresh_request=request;return {cancel=function() cancellations=cancellations+1 end} end,
    context=function(proxy,base) return {reading_seconds=90,chapter_remaining_text='约 1 分钟'} end,
    error=function(proxy,err) eq(true,err.code=='STORAGE_ERROR' or err.code=='READER_ERROR','runtime failure reaches host diagnostics') end,
}
local document=assert(Adapter.open(owner,{state=state,body=body,progress=progress},callbacks))
eq(1,counts.ready,'one candidate has one ready notification')
eq(1,#events,'latest initial page state is published once after ready')
eq(document,events[1].proxy,'page callback receives the session proxy')
eq(nil,events[1].total,'uncomputed page totals remain unknown')
eq(nil,document.reader,'independent proxy does not fake a ReaderUI field')
eq('immersive_style',document.reading_settings_key,'native and independent layouts have separate storage keys')
eq(true,document.restored_on_open,'session skips a second fractional restore over the precise cursor')
eq(old,owner.current_document,'open leaves owner commit to the caller')
eq(false,old.closed,'open never closes the previous document')
eq(nil,h.shown,'constructing a candidate never shows it')
eq(30,document:getReaderSettings().body_font_size,'only independent style is restored')
eq(90,document:getReadingContext().reading_seconds,'context extras come from the host')
eq(nil,document:getReadingContext().book_fraction,'incomplete catalog remains unknown')
h:drain();local page,total=document:getPagePosition()
eq(true,page>=1 and total>1,'neutral page API exposes actual computed pagination')
state.catalog_complete=true
eq(true,document.widget:getReadingContext().book_fraction~=nil,'live footer sees completed catalog without a proxy query first')
eq(true,document:getReadingContext().book_fraction~=nil,'completed host catalog is reflected in neutral context')
document.widget:applyStyle{body_font_size=32}
eq(32,saved_style.body_font_size,'style callback receives pending style directly')
eq(30,progress.immersive_style.body_font_size,'adapter never mutates stored progress')
refused_style=true;local changed=document.widget:applyStyle{body_font_size=34}
eq(nil,changed,'style save failure reaches the caller')
eq(32,document:getReaderSettings().body_font_size,'save failure keeps accepted style')
assert(document:setProgressFraction(.4));eq(.4,document:getProgressFraction(),'fraction API updates the independent cursor')
assert(document:pauseReading());assert(document:pauseReading());eq(1,counts.pause,'pause callback is idempotent')
assert(document:resumeReading());eq(1,counts.resume,'resume reaches session lifecycle')
for action,expected in pairs{toc='toc',settings='settings',bookshelf='exit',receipt='receipt',review='review',sources='source_sites',
    statistics='statistics',toggle_reader='toggle_reader',book_info='book_info',add_to_shelf='add_to_shelf'} do
    document.widget:runAction(action)
    eq(expected,calls[#calls].name,'visible action forwards to its owner callback')
    eq(document,calls[#calls].proxy,'owner action receives proxy rather than widget')
    document:resumeReading()
end
document.widget:showMenu();local found=false
for _,row in ipairs(document.widget.menu_dialog.buttons) do for _,button in ipairs(row) do if button.text=='阅读统计' then found=true end end end
eq(true,found,'statistics owner action is reachable in the visible menu')
document.widget:_closeDialog('menu_dialog');document:resumeReading()
refused_pause=true;local before=#calls;local acted=document.widget:runAction('toc')
eq(nil,acted,'failed pause/save prevents leaving the reading view')
eq(before,#calls,'owner action is not called after pause failure');refused_pause=false
document.widget:requestChapter(2,false)
eq(2,requested.index,'chapter callback receives target chapter directly')
eq(true,requested.request.is_current(),'chapter request starts current')
document.widget:runAction('refresh')
eq(false,requested.request.is_current(),'refresh invalidates the previous chapter request')
eq(true,refresh_request.is_current(),'refresh uses the same cancellation boundary')
eq(true,cancellations>=1,'replaced chapter handle is cancelled')
document:resumeReading()
local chapter_callback=callbacks.chapter
callbacks.chapter=function() return false end
local cancelled_before=cancellations
local refused=document:requestChapter(2,false)
eq(nil,refused,'false from the chapter callback is reported as failure')
document:requestChapter(2,false)
eq(cancelled_before+1,cancellations,'failed requests do not repeatedly cancel an already released handle')
callbacks.chapter=chapter_callback
assert(document:refreshAppearance());assert(document.chrome:refresh())
refused_flush=true;local closed=document:close()
eq(nil,closed,'failed final flush refuses document closure')
eq(false,document.closed,'failed final flush leaves proxy usable');refused_flush=false
local position=document:getPosition();assert(document:close());assert(document:close())
eq(1,counts.closed,'close callback occurs exactly once')
eq(false,refresh_request.is_current(),'closed document invalidates refresh results')
eq(position.char,document:getPosition().char,'closed proxy retains final position')
eq(old,owner.current_document,'closing an uncommitted proxy preserves current owner')
eq(0,counts.failure,'normal lifecycle does not invoke startup failure')
eq(0,#h.tasks,'close clears all candidate jobs')
local before_calls=#calls;local rejected=0
local no,err=Adapter.open(owner,{state=state,body=body,progress=progress},{ready=function() return nil,{code='STORAGE_ERROR',message='拒绝'} end,
    failure=function(error) rejected=rejected+1;eq('STORAGE_ERROR',error.code,'ready rejection preserves the original error') end,
    close=function() error('rejected candidate must not close an active session') end,
    page_update=function() error('rejected candidate must not publish page state') end})
eq(nil,no,'rejected readiness returns no document');eq(1,rejected,'ready failure is reported once')
eq(0,#h.tasks,'rejected candidate is disposed without leaked jobs')
eq(before_calls,#calls,'failed candidate never exits to bookshelf')
local no,err=Adapter.open(owner,{state=state,body='<p>正文<img src="a"></p>'}, {ready=function() error('unsupported chapter cannot become ready') end,
    failure=function() counts.failure=counts.failure+1 end})
eq(nil,no,'unsupported content fails construction');eq('UNSUPPORTED_CONTENT',err.code,'construction error is preserved')
eq(1,counts.failure,'construction failure is reported once')
eq(old,owner.current_document,'construction failure preserves the old owner')
local allocated=#h.buffers
local no,err=Adapter.open({settings={get=function(_,key) if key=='reader_background' then error('background settings failed') end end}},
    {state=state,body=body},{close=function() error('unbuilt candidate must not close a session') end})
eq(nil,no,'constructor exceptions return a failed candidate')
for i=allocated+1,#h.buffers do eq(1,h.buffers[i].freed,'failed construction releases each already allocated text buffer') end
local native_fraction=assert(Adapter.open(owner,{state={book=state.book,chapters=state.chapters,index=1,restore_fraction=.6},body=body,progress=progress},{}))
eq(.6,native_fraction:getProgressFraction(),'explicit mode-switch fraction wins over an older independent cursor')
native_fraction:close()
-- Use the baseline UIManager implementation for stack ordering and its actual
-- FlushSettings -> CloseWidget sequence; screen IO still uses the host harness.
local file=assert(io.open((os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader')..'/frontend/ui/uimanager.lua','rb'))
local source=file:read('*a');file:close()
local first=assert(source:find('function UIManager:show(',1,true))
local last=assert(source:find('--- Shift the execution times',first,true))
local manager={covers_fullscreen=true,handleEvent=function() end}
local exposed,watch=0,false
local real_ui=setmetatable({_window_stack={{widget=manager}},_dirty={}},{__index=h.ui})
local function top() return real_ui._window_stack[#real_ui._window_stack].widget end
real_ui.setDirty=function(self,widget)
    self._dirty[widget]=true
    if watch and top()==manager then exposed=exposed+1 end
end
real_ui._refresh=function() if watch and top()==manager then exposed=exposed+1 end end
local chunk=assert(loadstring(source:sub(first,last-1)))
setfenv(chunk,{UIManager=real_ui,logger={dbg=function() end},Input={},Event=require('ui/event'),table=table,tostring=tostring})
chunk()
local stack_owner={ui_manager=real_ui}
local old_flush=0
local old_document=assert(Adapter.open(stack_owner,{state=state,body=body,progress={immersive_style={page_transition='swipe'}}},
    {flush=function() old_flush=old_flush+1;return true end}))
real_ui:show(old_document.widget)
stack_owner.current_document=old_document
old_document.widget:nextPage()
eq(true,old_document.widget.animation:isRunning(),'replacement starts while an old animation is pending')
local new_document=assert(Adapter.open(stack_owner,{state=state,body=body,progress={immersive_style={page_transition='off'}}},{}))
local before_refresh=#h.refreshes
watch=true
if not new_document.reuses_widget then real_ui:show(new_document.widget) end
stack_owner.current_document=new_document
assert(old_document:close())
real_ui:setDirty(new_document.widget,'ui')
eq(new_document.widget,top(),'new fullscreen view covers the stack while the old one closes')
eq(0,exposed,'real UIManager replacement never schedules an exposed FileManager')
eq(before_refresh,#h.refreshes,'cancelling the old animation submits no old screen refresh')
eq(0,old_flush,'same-window adapter handoff leaves the single persistence operation to Session')
eq(new_document,stack_owner.current_document,'old closure cannot clear the newly committed owner')
watch=false;assert(new_document:close())
eq(nil,stack_owner.current_document,'closing the current proxy clears its owner')
eq(0,#h.tasks,'real stack replacement leaves no orphaned scheduled jobs')
eq(nil,package.loaded['apps/reader/readerui'],'session adapter never loads ReaderUI')
return n
