-- Real production Session/owner/independent widgets. Only platform IO, network,
-- and native document rendering are substitutes. Never resolve staged modules.
package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local staged='staging/phase3/?.lua;'
local first,last=package.path:find(staged,1,true)
if first then package.path=package.path:sub(1,first-1)..package.path:sub(last+1) end
local A=require('assertions');local count=0;local failures={}
local function eq(want,got,why)
    count=count+1
    local ok,err=pcall(A.equal,want,got,why)
    if not ok then failures[#failures+1]=err end
end
local function copy(value) return require('util').tableDeepCopy(value) end
local function noop() end
local Adapter=require('legado.lib.koreader_reader_ui')
local Session=require('legado.lib.reader_session')
local Independent=require('legado.lib.leko_reader_ui')
local Reader=require('legado.ui.leko_reader')
for _,fn in ipairs{Adapter.openDocument,Session.open,Independent.open,Reader.new} do
    local source=debug.getinfo(fn,'S').source:gsub('\\','/')
    eq(true,source:find('legado.koplugin/legado/',1,true)~=nil,'integration loads production code from the runtime directory')
    eq(nil,source:find('/staging/',1,true),'integration cannot accidentally verify staged code')
end

-- Execute the baseline stack and FlushSettings/CloseWidget implementations.
local upstream=os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader'
local file=assert(io.open(upstream..'/frontend/ui/uimanager.lua','rb'))
local source=file:read('*a');file:close()
local start=assert(source:find('function UIManager:show(',1,true))
local finish=assert(source:find('--- Shift the execution times',start,true))
local manager={covers_fullscreen=true,handleEvent=noop}
local exposed,watch=0,false
h.ui._window_stack={{widget=manager}};h.ui._dirty={}
local function top() return h.ui._window_stack[#h.ui._window_stack].widget end
h.ui.getTopmostVisibleWidget=top
h.ui.setDirty=function(self,widget)
    if widget then self._dirty[widget]=true end
    if watch and top()==manager then exposed=exposed+1 end
end
h.ui._refresh=function() if watch and top()==manager then exposed=exposed+1 end end
local chunk=assert(loadstring(source:sub(start,finish-1)))
setfenv(chunk,setmetatable({UIManager=h.ui,Input={},Event=require('ui/event'),logger={dbg=noop}},{__index=_G}));chunk()
package.loaded['libs/libkoreader-lfs']={attributes=function() return 'file' end}

local values={immersive_reader=true,prefetch=0}
local defaults=require('legado.lib.settings').DEFAULTS
local settings={get=function(_,key) if values[key]~=nil then return values[key] end;return defaults[key] end}
local disk,fail_write={},false
local fs={read=function(_,path) return disk[path] end,atomicWrite=function(_,path,data)
    if fail_write then return nil,{code='STORAGE_ERROR',message='disk full'} end
    disk[path]=data;return true
end}
local function new_store()
    return assert(require('legado.lib.storage').new{path='phase3-session-memory.lua',fs=fs,sqlite_loader=function() end})
end
local store=new_store()
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',240)..'</p>'
local bodies={}
local function cache_key(book_id,chapter) return book_id..':'..chapter.uid end
local cache={readBody=function(_,_,book_id,chapter)
    local value=bodies[cache_key(book_id,chapter)]
    if value==false then return nil,{code='STORAGE_ERROR',message='chapter body unavailable'} end
    return value or body
end,writeBody=function(_,_,book_id,chapter,value) bodies[cache_key(book_id,chapter)]=value;return true end,
    writeHtml=function(_,_,book_id,chapter) return '/cache/'..book_id..'-'..chapter.uid..'.html' end}
local requests={}
local service={getContent=function(_,site,book,chapter,callback)
    local request={book=book,chapter=chapter,callback=callback,cancelled=0}
    function request:cancel() self.cancelled=self.cancelled+1 end
    requests[#requests+1]=request;return request
end}

-- The production native adapter still collects native settings and observes
-- ReadSettings/SaveSettings. The native document engine is intentionally tiny.
local allow_native,native_calls=false,0
local host={}
function host:handleEvent(event)
    if event.handler=='onReadSettings' then self.font_size=self.doc_settings:readSetting('copt_font_size') or 21
    elseif event.handler=='onSaveSettings' then self.doc_settings:saveSetting('copt_font_size',self.font_size)
    elseif event.handler=='onFlushSettings' and self.onFlushSettings then return self:onFlushSettings()
    elseif event.handler=='onCloseWidget' and self.onCloseWidget then return self:onCloseWidget() end
end
function host:new(options)
    local sidecar={}
    local reader=setmetatable({document=options.document,view={},covers_fullscreen=true,doc_props={display_title='原生章节'},
        config={options={prefix='copt',{options={{name='font_size'},{name='h_page_margins'}}}}},
        doc_settings={readSetting=function(_,key) return sidecar[key] end,saveSetting=function(_,key,value) sidecar[key]=copy(value) end,flush=noop},
        rolling={fraction=0,getLastPercent=function(self) return self.fraction end,
            onGotoPercent=function(self,n) self.fraction=n/100 end},
    },{__index=host})
    self.instance=reader;reader.dialog=reader
    reader:handleEvent(require('ui/event'):new('ReadSettings'))
    options.after_open_callback(reader)
    return reader
end
local native_file=assert(io.open(upstream..'/frontend/apps/reader/readerui.lua','rb'))
local native_source=native_file:read('*a');native_file:close()
package.loaded['apps/filemanager/filemanager']={}
package.loaded.readhistory={updateLastBookTime=noop};package.loaded.readcollection={updateLastBookTime=noop}
G_reader_settings.flush=noop
h.ui.avoidFlashOnNextRepaint=noop
local native_env=setmetatable({ReaderUI=host,UIManager=h.ui,Event=require('ui/event'),
    Screen={getSize=function() return {w=600,h=800} end,setWindowTitle=noop},
    Device={notifyBookState=noop},PluginLoader={finalize=noop},DocSettings={saveSettingsArcFile=noop},
    DocCache={serialize=noop},BookList={setBookInfoCacheProperty=noop},logger={info=noop,warn=noop,dbg=noop},
    DocumentRegistry={openDocument=function(_,path)
        return {file=path,getPageCount=function() return 20 end,isEdited=function() return false end,close=noop}
    end},
},{__index=_G})
for _,range in ipairs{{'doShowReader(','unlockDocumentWithPassword('},{'saveSettings(','dealWithLoadDocumentFailure('}} do
    local from=assert(native_source:find('function ReaderUI:'..range[1],1,true))
    local to=assert(native_source:find('function ReaderUI:'..range[2],from+1,true))
    local native_chunk=assert(loadstring(native_source:sub(from,to-1)));setfenv(native_chunk,native_env);native_chunk()
end
function host:showReader(path,_,_,_,after)
    native_calls=native_calls+1
    assert(allow_native,'immersive flow must never call ReaderUI.showReader')
    self.after_open_callback=after
    h.ui:scheduleIn(0,function() self:doShowReader(path,{},true) end)
end
local diagnostics={}
local toc_calls=0
local owner=Adapter.new{ReaderUI=host,settings=settings,on_toc=function() toc_calls=toc_calls+1;return true end}
local function new_session()
    return Session.new{cache=cache,storage=store,ui=owner,service=service,settings=settings,scheduler=h.ui,
        diagnostics=function(stage,err) diagnostics[#diagnostics+1]={stage=stage,error=err} end}
end
local session=new_session()
local chapters={{uid='c1',index=1,title='第一章'},{uid='c2',index=2,title='第二章'},{uid='c3',index=3,title='第三章'}}
cache.readCatalog=function() return {chapters=copy(chapters),complete=true} end
local site={id='site-a'}
local book={id='book-a',source_id=site.id,name='测试小说',author='作者'}
assert(store:putProgress{book_id=book.id,chapter_uid='c1',chapter_index=1,fraction=0,
    reader_settings={copt_font_size=42,copt_h_page_margins={18,18}},immersive_style={body_font_size=30,page_transition='off'}})
local function current() return assert(session.active and session.active.document,'expected an active document') end
local function open(target_site,target_book,index,options)
    local result,err=session:open(target_site,target_book,chapters,index,options)
    assert(result,err and err.message or 'open failed');h:drain()
    return current()
end
local doc=open(site,book,1)
eq('immersive',doc.backend,'enabled first read selects the independent backend')
eq(nil,doc.reader,'independent session has no fake ReaderUI member')
eq(0,native_calls,'first read did not invoke the native reader')
eq(doc,owner.current_document,'owner commits the active independent proxy')
eq(doc.widget,top(),'first independent widget is actually shown')
watch=true
assert(doc.widget:applyStyle{body_font_size=32})
assert(doc:flushProgress())
eq(32,store:getProgress(book.id).immersive_style.body_font_size,'independent style is persisted through real Session callbacks')
eq(42,store:getProgress(book.id).reader_settings.copt_font_size,'independent save preserves native reader settings')
h:drain();assert(doc:setProgressFraction(1));local chapter_one_last=doc:getPosition();doc.widget:nextPage();h:drain()
local next_doc=current()
eq(2,session.active.index,'real chapter-end event activates the next chapter')
eq(true,doc.closed,'successful chapter replacement closes the old proxy')
eq(next_doc,owner.current_document,'old close cannot clear the new owner')
eq(32,next_doc:getReaderSettings().body_font_size,'independent layout follows the next chapter')
next_doc.widget:previousPage();h:drain()
eq(1,session.active.index,'previous at chapter start opens the preceding chapter')
eq(chapter_one_last.char,current():getPosition().char,'previous chapter opens its complete final page, not only its last character')
next_doc=current()
next_doc.widget:requestChapter(3,false);h:drain()
eq(3,session.active.index,'directory-style chapter request reaches the requested chapter')
eq(0,native_calls,'next chapter and catalog navigation stay independent')
doc=current();assert(doc:setProgressFraction(.37));local exact=doc:getPosition()
assert(doc:flushProgress());watch=false;session:close()
store=new_store();local saved=assert(store:getProgress(book.id))
saved.fraction=.01;assert(store:putProgress(saved)) -- Exact cursor must win over the approximate scalar.
session=new_session();assert(session:resume(site,book,chapters,nil,{backend='immersive'}));h:drain();doc=current()
eq(exact.char,doc:getPosition().char,'fresh Session/Storage reopen restores the exact persisted cursor')
eq(32,doc:getReaderSettings().body_font_size,'fresh Session/Storage reopen restores independent style')
eq(0,native_calls,'reopen never invokes native ReaderUI')
watch=true

-- Both directions use the public open backend + before_commit contract.
local live=doc:getProgressFraction();local commits=0
local native_metrics={};session.timing=function(metric) native_metrics[metric.stage]=metric end
allow_native=true
local native=open(site,book,3,{backend='native',restore_fraction=live,before_commit=function()
    commits=commits+1;values.immersive_reader=false;return true
end})
eq(true,native_metrics.native_engine_open~=nil,'native engine opening is measured separately from Session readiness')
eq(true,native_metrics.native_adapter_init~=nil,'native adapter setup has its own timing boundary')
eq('native',native.backend,'explicit native backend wins over the enabled preference')
eq(live,native:getProgressFraction(),'independent to native switch preserves live position')
eq(42,native.reader.font_size,'native backend restores its own style instead of independent style')
eq(1,commits,'successful mode commit occurs once')
eq(native,owner.current_document,'native target remains owner after old independent close')
session:open(site,book,chapters,3,{backend='immersive',restore_fraction=.5,before_commit=function() return false end})
h:drain()
eq(native,current(),'rejected independent target preserves the old native session')
eq(native.reader,host.instance,'rejected independent target keeps the actual native instance alive')
eq(true,native.reader.document~=nil,'rejected independent target never closes its native document')
native.reader.font_size=43;assert(native:flushProgress());assert(native:setProgressFraction(.53))
doc=open(site,book,3,{backend='immersive',restore_fraction=native:getProgressFraction(),before_commit=function()
    commits=commits+1;values.immersive_reader=true;return true
end})
allow_native=false
eq(.53,doc:getProgressFraction(),'native live position overrides older independent cursor')
eq(32,doc:getReaderSettings().body_font_size,'switching back keeps independent style')
eq(43,store:getProgress(book.id).reader_settings.copt_font_size,'native style changes remain isolated and persisted')
eq(2,commits,'one preference commit per completed direction')

-- Consecutive source switches inherit layout once, then own their saved state.
for index=2,3 do
    local target_site={id='site-'..index}
    local target_book={id='book-source-'..index,source_id=target_site.id,name=book.name,author=book.author}
    doc=open(target_site,target_book,1,{backend='immersive',restore_fraction=.25,reader_settings_book_id=book.id})
    eq(32+index-2,doc:getReaderSettings().body_font_size,'source switch inherits the previous source current layout')
    assert(doc.widget:applyStyle{body_font_size=32+index-1});assert(doc:flushProgress())
    eq(43,(store:getProgress(target_book.id).reader_settings or {}).copt_font_size,'source switch preserves the separate native layout for later mode switching')
    site,book=target_site,target_book
end
eq(1,native_calls,'continuous source switches do not reopen native ReaderUI')

-- Failed save/construction/preference commit all retain a readable old session.
doc=current();local old_state=session.active
fail_write=true
local no,err=session:open(site,book,chapters,2,{backend='immersive'})
eq(nil,no,'progress save failure rejects chapter replacement')
eq(doc,current(),'progress save failure retains old session')
eq(false,doc.closed,'failed save leaves old widget open')
local changed=doc.widget:applyStyle{body_font_size=40}
eq(nil,changed,'style persistence failure is returned through the live widget')
eq(34,doc:getReaderSettings().body_font_size,'failed style persistence retains old layout')
local toc_before=toc_calls
local paused=doc.widget:runAction('toc')
eq(nil,paused,'failed pause save refuses the external navigation')
eq(toc_before,toc_calls,'failed pause save never invokes the external action')
eq(false,doc.widget.paused,'failed pause save leaves widget reading active')
eq(false,session.active.paused==true,'failed pause save leaves Session reading active')
fail_write=false
doc:resumeReading()
bodies[cache_key(book.id,chapters[2])]='<p>图片章节<img src="cover.png"></p>'
no,err=session:open(site,book,chapters,2,{backend='immersive'})
eq(nil,no,'unsupported candidate construction rejects the switch')
eq('UNSUPPORTED_CONTENT',err.code,'candidate failure retains its specific error code')
eq(doc,current(),'construction failure preserves the old active document')
eq(doc,owner.current_document,'construction failure preserves owner current_document')
bodies[cache_key(book.id,chapters[2])]=nil
allow_native=true
session:open(site,book,chapters,1,{backend='native',restore_fraction=.5,before_commit=function() return nil,{code='STORAGE_ERROR',message='preference save failed'} end})
h:drain();allow_native=false
eq(doc,current(),'rejected preference commit preserves the old backend session')
eq(true,values.immersive_reader,'rejected preference commit preserves the mode preference')
eq(false,doc.closed,'rejected preference commit leaves old document usable')
eq(doc,owner.current_document,'failed native target restores old independent owner')
eq(doc.widget,top(),'failed target removes its own view and reveals the prior reader')

-- In-flight foreground results cannot revive an old reader or overwrite cache.
bodies[cache_key(book.id,chapters[3])]=false
doc.widget:requestChapter(3,false)
local late=assert(requests[#requests],'missing foreground request')
eq(doc,current(),'pending remote chapter retains the current reader')
local replacement=open(site,book,2,{backend='immersive'})
eq(true,late.cancelled>=1,'new navigation cancels the old foreground handle')
late.callback({content='迟到章节正文'});h:drain()
eq(replacement,current(),'late network callback cannot replace the active reader')
eq(false,bodies[cache_key(book.id,chapters[3])],'late callback does not write cancelled chapter data')

local cached=cache:readBody(site.id,book.id,chapters[2])
replacement.widget:runAction('refresh')
local refresh=assert(requests[#requests]);eq(true,refresh~=late,'explicit refresh really requests fresh content')
refresh.callback(nil,{code='NETWORK_ERROR',message='offline'});h:drain()
eq(replacement,current(),'failed forced refresh retains old active reader')
eq(false,replacement.closed,'failed refresh never destroys cached reading view')
eq(cached,cache:readBody(site.id,book.id,chapters[2]),'failed refresh preserves cached body')
eq(false,replacement.widget.paused,'failed refresh resumes the old independent reader')
eq(false,session.active.paused==true,'failed refresh resumes Session accounting')
eq(replacement,owner.current_document,'failed refresh retains current owner')

-- Native initialization that was queued before a later independent intent is stale.
allow_native=true
local stale_commit=0
session:open(site,book,chapters,1,{backend='native',before_commit=function() stale_commit=stale_commit+1;return true end})
local superseding=assert(session:open(site,book,chapters,2,{backend='immersive'}))
h:drain();allow_native=false
eq(superseding,current(),'late native startup cannot replace a newer independent session')
eq(superseding,owner.current_document,'late native cleanup preserves the current independent owner')
eq(0,stale_commit,'stale native readiness never commits mode preferences')
eq(nil,host.instance,'stale native target is closed through the real native lifecycle')

-- Cached offline navigation and failed refresh must never start transport work.
local network_before=#requests
assert(session:openOffline(site,book,1));h:drain();local offline=current()
eq(true,session.active.offline,'offline entry retains its session mode')
offline.widget:requestChapter(2,false);h:drain();offline=current()
eq(2,session.active.index,'offline navigation can open a cached target')
offline.widget:requestChapter(3,false);h:drain()
eq(offline,current(),'offline missing target keeps the readable cached page')
offline.widget:runAction('refresh');h:drain()
eq(offline,current(),'offline refresh keeps its original cached page')
eq(network_before,#requests,'offline navigation and refresh issue no network calls')
eq(false,offline.widget.paused,'offline refresh rejection restores reading')
eq(0,exposed,'reading transitions and rejected candidates never expose FileManager')
watch=false;session:close();h:drain()
eq(nil,owner.current_document,'closing the final session releases its owner')
eq(0,#h.tasks,'final close cancels reader jobs and session background tasks')

-- Display failure after candidate readiness must reclaim only that candidate.
local existing=open(site,book,1,{backend='immersive'})
local show=h.ui.show
h.ui.show=function(self,widget,...)
    if widget~=existing.widget then error('target display failed') end
    return show(self,widget,...)
end
local rejected,display_error=session:open(site,{id='display-failure-book',source_id=site.id},chapters,2,{backend='immersive'})
h.ui.show=show
eq(nil,rejected,'target display exception rejects the candidate')
eq(existing,current(),'target display exception restores the old active session')
eq(existing,owner.current_document,'target display exception retains the old owner')
eq(existing.widget,top(),'target display exception keeps the old widget visible')
session:close();h:drain()
eq(0,#h.tasks,'target display exception releases the rejected candidate clock and pagination')

-- Reading context uses observed progress and excludes the entire pause interval.
local real_time=os.time;local now=real_time();local began=now
os.time=function() return now end
local timed_book={id='timed-book',source_id=site.id,name='计时书籍'}
values.prefetch=2
bodies[cache_key(timed_book.id,chapters[2])]=false
local timed=open(site,timed_book,1,{backend='immersive'})
local prefetch=assert(requests[#requests])
local context=timed:getReadingContext()
eq(2,context.prefetch.total,'context exposes the actual requested prefetch count')
eq(1,context.prefetch.cached,'an in-flight chapter does not hide another chapter already cached in the window')
prefetch.callback({content=body});h:drain()
context=timed:getReadingContext()
eq(2,context.prefetch.cached,'finished request and already cached chapter update real prefetch progress')
local read_body,read_progress=cache.readBody,store.getProgress
local paint_reads=0
cache.readBody=function(...) paint_reads=paint_reads+1;return read_body(...) end
store.getProgress=function(...) paint_reads=paint_reads+1;return read_progress(...) end
timed:getReadingContext();timed.widget:paintTo(h.screen.bb,0,0)
cache.readBody,store.getProgress=read_body,read_progress
eq(0,paint_reads,'context and footer painting never read storage or cached files')
now=began+5;assert(timed:setProgressFraction(.5))
eq(nil,timed:getReadingContext().chapter_remaining,'less than ten reading seconds remains unestimated')
now=began+12;context=timed:getReadingContext()
eq(12,context.reading_seconds,'context includes current unsaved reading time')
eq(12,context.chapter_remaining,'remaining time uses actual chapter progress and active seconds')
assert(timed:pauseReading());now=began+612
context=timed:getReadingContext()
eq(12,context.reading_seconds,'time spent under a covering page is not reading time')
eq(12,context.chapter_remaining,'paused wall time does not inflate the remaining-time estimate')
assert(timed:resumeReading());now=began+620
context=timed:getReadingContext()
eq(20,context.reading_seconds,'resume adds only subsequent active reading time')
eq(20,context.chapter_remaining,'estimate excludes the full ten-minute pause after resume')
assert(timed:flushProgress())
eq(20,store:getProgress(timed_book.id).reading_seconds,'persisted history excludes the pause interval')
now=began+625;fail_write=true
local sleep_saved=timed.widget:onSuspend()
eq(nil,sleep_saved,'physical suspend reports a failed progress flush')
eq(true,timed.widget.paused,'physical suspend pauses the widget even when storage fails')
eq(true,session.active.paused,'physical suspend also stops Session accounting after save failure')
local suspended=timed:getReadingContext().reading_seconds
now=began+1225
eq(suspended,timed:getReadingContext().reading_seconds,'failed suspend save never counts the following ten-minute sleep')
fail_write=false;timed.widget:onResume();now=began+1232
assert(timed:flushProgress())
eq(32,store:getProgress(timed_book.id).reading_seconds,'retry retains five seconds before failed suspend plus seven after resume')
eq(32,timed:getReadingContext().chapter_remaining,'post-resume estimate also includes the recovered pre-suspend reading interval')
session:close();h:drain();os.time=real_time;values.prefetch=0

-- Retaining a farther in-flight chapter must also prepare the new widget's
-- immediate cached chapter; an early return alone leaves its first page cold.
do
    local extended=copy(chapters)
    extended[4]={uid='c4',index=4,title='第四章'}
    extended[5]={uid='c5',index=5,title='第五章'}
    local prepared_book={id='farther-prefetch-book',source_id=site.id,name='远章预取'}
    bodies[cache_key(prepared_book.id,extended[4])]=false
    bodies[cache_key(prepared_book.id,extended[5])]=false
    values.prefetch=3
    assert(session:open(site,prepared_book,extended,1,{backend='immersive'}));h:drain()
    local fourth=assert(requests[#requests]);local requested=#requests
    eq('c4',fourth.chapter.uid,'cached second and third chapters leave fourth chapter in flight')
    current().widget:requestChapter(2,false);h:drain()
    eq(0,fourth.cancelled,'real independent transition preserves the fourth chapter request')
    local duplicate=0
    for _,request in ipairs(requests) do if request.book.id==prepared_book.id and request.chapter.uid=='c4' then duplicate=duplicate+1 end end
    eq(1,duplicate,'real independent transition does not duplicate the fourth chapter')
    local prepared=owner.prepared_chapters[1] and owner.prepared_chapters[1].prepared
    eq(true,prepared and prepared.key:find('\nc3\n',1,true)~=nil,'new independent widget prepares the immediate third chapter')
    eq(true,prepared and prepared.page~=nil,'new independent preparation includes the first page')
    fourth.callback({content=body});h:drain()
    local fifth=requests[#requests]
    eq('c5',fifth.chapter.uid,'transferred independent chain advances to the new window end')
    fifth.callback({content=body});h:drain()
    eq(3,current():getReadingContext().prefetch.cached,'transferred independent chain accounts for all cached chapters')
    session:close();h:drain();values.prefetch=0
end

-- Opt-in stress uses these same production controllers and upstream UI stack.
-- The screen, font metrics, network and native document engine remain substitutes.
if os.getenv('LEGADO_SOAK')=='1' then
    local samples,heap={},{}
    local baseline_buffers
    bodies[cache_key(book.id,chapters[3])]=body
    local function reclaim_harness()
        local live={}
        for _,buffer in ipairs(h.buffers) do
            if buffer.freed==0 then live[#live+1]=buffer end
        end
        baseline_buffers=baseline_buffers or #live
        assert(#live<=baseline_buffers+8,'soak drawing buffers grew across transitions: '..#live)
        h.ui._dirty={};h.buffers=live;h.refreshes={}
        collectgarbage('collect')
    end
    open(site,book,1,{backend='immersive'});watch=true
    local toc_app=require('legado.ui.app').new{reader_session=session}
    local toc_references=setmetatable({},{__mode='v'})
    values.prefetch=3
    for i=1,500 do
        local started=os.clock()
        if i%5==0 then
            local toc=toc_app:openReadingCatalog(session.active,current())
            local completions=0
            local selection=assert(toc:select(i%3+1,function() completions=completions+1 end));h:drain()
            toc_references['catalog'..i],toc_references['navigation'..i]=toc,toc.navigation
            -- Synchronous navigation returns true, which is not a GC object
            -- and never disappears from a weak table. Track real handles only.
            if type(selection)=='table' then toc_references['selection'..i]=selection end
            eq(1,completions,'soak real TOC selection completes exactly once')
        else current().widget:requestChapter(i%3+1,false);h:drain() end
        samples[#samples+1]=(os.clock()-started)*1000
        eq(i%3+1,session.active.index,'soak chapter navigation reaches its target')
        eq(2,#h.ui._window_stack,'soak retains only manager and active reader')
        assert(#h.tasks<=2,'soak leaked scheduler jobs')
        reclaim_harness()
        if i%100==0 then heap[#heap+1]=collectgarbage('count') end
    end
    for i=1,200 do
        local widget=current().widget
        assert(widget:showMenu())
        local menu=assert(widget.menu_dialog)
        eq(menu,top(),'soak menu is visible')
        menu.buttons[#menu.buttons][1].callback();h:drain()
        eq(widget,top(),'soak continue returns to its reading owner')
        reclaim_harness()
    end
    for i=1,50 do
        local widget=current().widget
        widget:onSuspend();widget:onResume();h:drain()
        eq(false,widget.paused,'soak resume releases suspended state')
    end
    allow_native=true
    for i=1,50 do
        local backend=i%2==1 and 'native' or 'immersive'
        open(site,book,1,{backend=backend})
        eq(backend,current().backend,'soak mode switch commits requested backend')
        reclaim_harness()
    end
    allow_native=false
    eq(0,exposed,'soak does not display the file manager during transitions')
    assert(heap[#heap]-heap[1]<1024,'soak retained more than 1 MiB across last 400 transitions: '..table.concat(heap,','))
    table.sort(samples)
    print(string.format('[SOAK] chapters=500 menus=200 mode_switches=50 suspend_resume=50 host_cpu_p50_ms=%.2f host_cpu_p95_ms=%.2f heap_delta_kib=%.2f',samples[250],samples[475],heap[#heap]-heap[1]))
    print('[SOAK] heap_samples_kib_at_100_200_300_400_500='..table.concat(heap,','))
    watch=false;session:close();h:drain()
    collectgarbage('collect')
    local retained={};for key in pairs(toc_references) do retained[#retained+1]=key end;table.sort(retained)
    print('[SOAK] retained_toc_before_trace_flush='..table.concat(retained,','))
    if jit then jit.flush();collectgarbage('collect') end
    eq(nil,next(toc_references),'soak releases every TOC model, selection handle and navigation model')
    eq(0,#h.tasks,'soak close releases every scheduled job')
    eq(1,#h.ui._window_stack,'soak close releases every plugin widget')
end
assert(#failures==0,table.concat(failures,'\n'))
return count
