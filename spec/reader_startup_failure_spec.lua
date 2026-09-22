-- Keep the upstream nextTick/coroutine and doShowReader control flow intact.
-- Only document loading, display and reader construction use desktop substitutes.
local A = require('assertions')
local h = require('native_library_harness').install()
local Adapter = require('legado.lib.koreader_reader_ui')
local count = 0
local function eq(want, actual, message) count=count+1; A.equal(want,actual,message) end
local upstream = os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader'
local source_file = assert(io.open(upstream..'/frontend/apps/reader/readerui.lua','rb'))
local source = source_file:read('*a'); source_file:close()
local function native(name, next_name, env)
    local start = assert(source:find('function ReaderUI:'..name,1,true))
    local stop = assert(source:find('function ReaderUI:'..next_name,start+1,true))
    local chunk = assert(loadstring(source:sub(start,stop-1)))
    setfenv(chunk,env); chunk()
end
local noop=function() end
local function scenario(mode)
    local queue, scheduled, shown, manager_files, logs = {}, {}, {}, {}, {}
    local ready, failures, last_error, closes = 0,0,nil,0
    local rui = {}
    package.loaded.logger.warn=function(...) logs[#logs+1]=table.concat({...},' ') end
    h.ui.nextTick=function(_,fn) queue[#queue+1]=fn end
    h.ui.forceRePaint=noop; h.ui.avoidFlashOnNextRepaint=noop
    h.ui.scheduleIn=function(_,_,fn)
        scheduled[fn]=true
        if mode=='timer' then error('https://user:secret@example.test/private') end
    end
    h.ui.unschedule=function(_,fn) scheduled[fn]=nil end
    h.ui.show=function(_,widget)
        if widget.document and mode=='display' then error('display failed') end
        shown[#shown+1]=widget
    end
    local reader
    local original_handle=function() end
    local original_flush=function() end
    local original_home=function() end
    local original_margin=function() end
    local original_update=function() end
    local env=setmetatable({ReaderUI=rui,UIManager=h.ui,
        Screen={getSize=function() return {} end,setWindowTitle=noop},
        Device={setIgnoreInput=noop,notifyBookState=noop},Input={inhibitInputUntil=noop},
        logger={dbg=noop,info=noop,warn=noop},
        InfoMessage={new=function(_,v) return v end},
        T=function(s) return s end,_=function(s) return s end,
        BD={filepath=function(s) return s end},filemanagerutil={abbreviate=function(s) return s end},
    },{__index=_G})
    env.DocumentRegistry={openDocument=function(_,file)
        if file=='other.html' or mode=='engine' then error('engine failed https://user:secret@example.test') end
        if mode=='unsupported' then return nil end
        return {file=file,getPageCount=function() return 10 end}
    end}
    package.loaded['apps/filemanager/filemanager']={}
    native('showReaderCoroutine(','doShowReader(',env)
    native('doShowReader(','unlockDocumentWithPassword(',env)
    rui.showFileManager=function(_,file) manager_files[#manager_files+1]=file end
    rui.new=function(_,options)
        reader={document=options.document,doc_props={display_title='Book'},
            onHome=original_home,onFlushSettings=original_flush,handleEvent=original_handle,
            onClose=function(self) closes=closes+1;self.document=nil;rui.instance=nil end,
            typeset={unscaled_margins={10,10,10,10},onSetPageMargins=original_margin},
            menu={tab_item_table={},setUpdateItemTable=original_update},
            view={view_modules={},registerViewModule=function(self,name,module) self.view_modules[name]=module end},
        }
        rui.instance=reader
        if mode=='chrome' then reader.typeset.onSetPageMargins=function() error('margin failed https://user:secret@example.test') end end
        options.after_open_callback(reader)
        return reader
    end
    rui.showReader=function(self,file,_,seamless,_,after_open)
        self.after_open_callback=after_open
        self:showReaderCoroutine(file,{},seamless)
    end
    local original_do, original_manager = rui.doShowReader, rui.showFileManager
    local adapter=Adapter.new{ReaderUI=rui}
    local proxy=assert(adapter:openDocument('chapter.html',{
        ready=function(doc)
            if mode=='rejected' then return nil,{code='CANCELLED',message='stale intent'} end
            if mode=='refused' then return false end
            ready=ready+1
            eq(true,doc.chrome and doc.chrome.started,'ready follows chrome initialization')
            eq(reader,shown[#shown],'ready follows successful native reader display')
        end,
        failure=function(err) failures=failures+1;last_error=err end,
    }))
    eq(0,ready,'async launch does not report ready before nextTick')
    if mode=='engine' then
        local ok=pcall(rui.doShowReader,rui,'other.html',{},true)
        eq(false,ok,'observer preserves exceptions for other files')
        rui:showFileManager('other.html')
        eq('other.html',manager_files[1],'observer preserves other file-manager requests')
        manager_files={}
    end
    queue[1]()
    if mode=='success' then
        eq(1,ready,'successful asynchronous launch reports ready once')
        eq(0,failures,'successful launch does not report failure')
        reader:onClose()
        eq(nil,next(scheduled),'normal close cancels the chrome timer')
    else
        eq(0,ready,'failed launch never commits reading success')
        eq(1,failures,'asynchronous startup failure reaches the app exactly once')
        eq(mode=='chrome' or mode=='timer' or mode=='rejected' or mode=='refused',
            last_error and last_error.details.reason=='reader_ui_startup','error distinguishes plugin startup from native engine/display')
        if mode=='rejected' then eq('CANCELLED',last_error.code,'a rejected session retains its structured error code') end
        eq(false,tostring(last_error):find('secret',1,true)~=nil,'diagnostic never exposes exception credentials')
        if mode=='unsupported' or mode=='rejected' or mode=='refused' then
            eq(nil,last_error.details.location,'an engine rejection has no invented source location')
        else
            eq(true,last_error.details.location and last_error.details.location:match('^reader_startup_failure_spec%.lua:%d+$')~=nil,
                'caught Lua error retains only its source filename and line')
        end
        eq(1,#logs,'startup failure produces one sanitized diagnostic log')
        eq(false,logs[1]:find('secret',1,true)~=nil,'diagnostic log never includes credentials')
        eq(0,#manager_files,'failed generated chapter does not open its cache directory')
        eq(nil,next(scheduled),'failed launch leaves no chrome timer')
        if reader then
            eq(nil,reader.view.view_modules.legado_chrome,'failed launch removes chrome drawing hook')
            eq(original_handle,reader.handleEvent,'failed launch restores reader event handler')
            eq(original_flush,reader.onFlushSettings,'failed launch restores flush handler')
            eq(original_home,reader.onHome,'failed launch restores Home handler')
            eq(original_update,reader.menu.setUpdateItemTable,'failed launch restores menu update hook')
            eq(1,closes,'failed constructed reader is closed once')
        end
    end
    eq(original_do,rui.doShowReader,'terminal result removes the temporary engine observer')
    eq(original_manager,rui.showFileManager,'terminal result removes the temporary file-manager observer')
    return proxy
end
for _,mode in ipairs{'rejected','refused','engine','unsupported','chrome','timer','display','success'} do scenario(mode) end
do
    local queued,engine_calls,previous_closes,cancelled=nil,0,0,nil
    local previous={document={file='previous.html'},onClose=function() previous_closes=previous_closes+1 end}
    local host={instance=previous,doShowReader=function() engine_calls=engine_calls+1;previous:onClose() end}
    host.showReader=function(self,path) queued=function() self:doShowReader(path) end end
    local adapter=Adapter.new{ReaderUI=host}
    assert(adapter:openDocument('queued.html',{can_open=function() return false end,failure=function(err) cancelled=err end}))
    queued()
    eq(0,engine_calls,'cancelled queued native navigation never opens the engine')
    eq(0,previous_closes,'cancelled queued native navigation cannot close the previous engine')
    eq(previous,host.instance,'cancelled queued native navigation preserves the existing reader instance')
    eq('CANCELLED',cancelled and cancelled.code,'early native cancellation has an explicit terminal error')
end
local native_footer={settings={disable_progress_bar=false},refreshFooter=noop}
local legacy_footer={settings={disable_progress_bar=false},refreshFooter=noop}
local adapter=Adapter.new{}
eq(true,adapter:applyProgressBar({view={footer=native_footer},footer=legacy_footer},false),
    'progress setting finds the native ReaderView footer')
eq(true,native_footer.settings.disable_progress_bar,'native footer receives the saved progress preference')
eq(false,legacy_footer.settings.disable_progress_bar,'native footer takes precedence over a legacy alias')
local filesystem=package.loaded['libs/libkoreader-lfs']
package.loaded['libs/libkoreader-lfs']={attributes=function() return nil end}
local opens,missing_failures,existing_closes=0,0,0
local missing_host={showReader=function() opens=opens+1 end,doShowReader=noop,showFileManager=noop}
missing_host.instance={document={file='missing.epub'},onClose=function() existing_closes=existing_closes+1 end}
local missing_doc,missing_err=Adapter.new{ReaderUI=missing_host}:openDocument('missing.epub',{
    failure=function() missing_failures=missing_failures+1 end,
})
eq(nil,missing_doc,'a missing file cannot leave a permanently pending reader')
eq('reader_engine_open',missing_err and missing_err.details.reason,'missing file reports the engine-open stage')
eq(1,missing_failures,'missing file immediately fails once')
eq(0,opens,'missing-file preflight does not invoke native asynchronous launch')
eq(noop,missing_host.doShowReader,'missing-file preflight leaves native methods untouched')
eq(0,existing_closes,'missing-file failure does not close a reader that predates this launch')
package.loaded['libs/libkoreader-lfs']=filesystem
return count
