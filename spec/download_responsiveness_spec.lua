local A=require('assertions')
local Manager=require('legado.lib.download_manager')
local Downloads=require('legado.ui.downloads')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local function ok(value,why) n=n+1;A.truthy(value,why) end
local function fixture(total,cached,synchronous,kind)
    local now,jobs,pending,writes,catalog,bodies,cancelled=0,{},{},0,nil,{},0
    local source={bookSourceUrl='https://example.test'}
    local book={id='long-book',source_id=require('legado.lib.models').sourceId(source),name='长目录'}
    local chapters={}
    for index=1,total do chapters[index]={uid='c'..index,index=index,book_id=book.id,source_id=book.source_id}
        if cached then bodies['c'..index]='<p>缓存</p>' end end
    local scheduler={scheduleIn=function(_,delay,fn) jobs[#jobs+1]={at=now+delay,fn=fn} end,
        unschedule=function(_,fn) for _,job in ipairs(jobs) do if job.fn==fn then job.cancelled=true end end end}
    local stored={}
    local storage={listDownloadTasks=function() return {} end,listSources=function() return {source} end,
        listChapters=function() return chapters end,replaceChapters=function() return true end,
        putDownloadTask=function(_,task) writes=writes+1;stored[task.id]=task;return task end}
    local cache={readBody=function(_,s,b,c) return bodies[c.uid] end,
        writeBody=function(_,s,b,c,text) bodies[c.uid]=text;return true end,
        readCatalog=function() return catalog end,writeCatalog=function(_,s,b,value) catalog=value;return true end}
    local service={getChapters=function(_,s,b,cb) cb(chapters,nil,{catalog_complete=true});return {cancel=function() end} end,
        getContent=function(_,s,b,c,cb,options)
            local request={chapter=c,cb=cb,options=options};pending[#pending+1]=request
            if synchronous then cb({content='正文'}) end
            return {cancel=function() request.cancelled=true;cancelled=cancelled+1 end}
        end}
    local built,export_files=0,{}
    local options={storage=storage,cache=cache,offline_cache=cache,book_service=service,
        scheduler=scheduler,chapter_concurrency=2,now=function() return math.floor(now) end,
        builder={write=function(_,path) built=built+1;return path end,
            prepare=function(_,path) built=built+1;export_files[path]='new archive';return {path=path,size=11} end,
            publish=function(_,part,path) export_files[path]=export_files[part.path];export_files[part.path]=nil;return path end,
            fs={removeFile=function(_,path) export_files[path]=nil;return true end}},
        standby={acquire=function() end,release=function() end}}
    local manager=Manager.new(options)
    local task=kind=='epub' and assert(manager:enqueue(book,chapters)) or assert(manager:enqueueCache(book))
    local function step()
        table.sort(jobs,function(a,b) return a.at<b.at end)
        local job=table.remove(jobs,1)
        if not job then return false end
        now=job.at;if not job.cancelled then job.fn() end;return true
    end
    local function drain(limit) for i=1,limit or 20000 do if not step() then return end end;error('worker did not yield/settle') end
    return {manager=manager,task=task,book=book,pending=pending,step=step,drain=drain,bodies=bodies,
        writes=function() return writes end,cancelled=function() return cancelled end,built=function() return built end,
        stored=stored,storage=storage,options=options,export_files=export_files}
end

do
    local f=fixture(8)
    f.step();f.step()
    eq(2,#f.pending,'download fills only two bounded chapter slots')
    eq('background',f.pending[1].options and f.pending[1].options.priority,'bulk content uses background priority')
    f.pending[2].cb({content='第二章'})
    eq(1,f.manager:get(f.task.id).completed,'out-of-order success updates live progress')
    eq(2,#f.pending,'completion yields before launching the next request')
    f.step();eq(3,#f.pending,'one freed slot accepts the next chapter')
    local late=f.pending[1].cb
    ok(f.manager:cancel(f.task.id),'cancel remains available between completions')
    eq(2,f.cancelled(),'cancel terminates both remaining handles')
    late({content='已取消'});f.pending[3].cb({content='已取消'})
    f.drain();eq(3,#f.pending,'cancelled worker never starts queued chapters')
    eq(nil,f.bodies.c1,'late cancellation response is discarded')
    eq('cancelled',f.stored[f.task.id].status,'cancellation is immediately durable')
end
do
    local f=fixture(1406,true)
    f.step()
    ok(f.manager:get(f.task.id).completed<=2,'initial task does not synchronously walk the entire book')
    f.step();ok(f.manager:get(f.task.id).completed<=2,'each UI turn processes at most two cached chapters')
    f.drain()
    eq('completed',f.manager:get(f.task.id).status,'long cached book completes')
    eq(1406,f.manager:get(f.task.id).completed,'live progress counts every cached chapter')
    ok(f.writes()<=146,'1406 chapters need at most 146 durable task saves, not 2816')
    eq(nil,f.manager:list(true)[1].chapters,'progress list does not clone the catalog')
    eq(1406,#f.manager:get(f.task.id).chapters,'full task snapshot remains available explicitly')
end
do
    local f=fixture(50,false,true,'epub')
    f.step();eq(0,#f.pending,'EPUB download initially yields to the screen')
    f.step();eq(2,#f.pending,'synchronous responses do not recurse into every chapter')
    f.drain();eq('completed',f.manager:get(f.task.id).status,'synchronous responses eventually complete')
    eq(1,f.built(),'EPUB publishes exactly once after all bodies')
end
do
    local f=fixture(3)
    f.step();f.step()
    f.pending[1].cb(nil,{code='NETWORK_ERROR',message='offline'})
    eq('failed',f.manager:get(f.task.id).status,'one request failure settles the task')
    eq(1,f.cancelled(),'failure cancels the other request')
    f.pending[2].cb({content='too late'});f.drain()
    eq(nil,f.bodies.c2,'late result cannot write after another chapter failed')
end
do
    local f=fixture(1)
    f.step();f.step()
    f.storage.putDownloadTask=function() return nil,{code='STORAGE_ERROR'} end
    f.pending[1].cb({content='正文已保存'});f.drain()
    eq(true,f.manager.persistence_blocked,'failed final progress persistence blocks further downloads')
    eq('<p>正文已保存</p>',f.bodies.c1,'failed checkpoint preserves atomically cached content')
end
do
    local Worker=require('legado.lib.download_worker')
    local failed
    local w=Worker.new{valid=function() return true end,chapters={},completed=function() error('disk failure') end,
        failed=function(err) failed=err end}
    w:start();eq('STORAGE_ERROR',failed and failed.code,'thrown completion cannot leave a running task stranded')
end
do
    local f=fixture(3,true,false,'epub')
    local child,done,payload,terminated={},false,nil,0
    f.manager.export_subprocess={available=function() return true end,start=function(_,job) child.job=job;return child end,
        poll=function() return done,payload end,reap=function() return true end,
        terminate=function() terminated=terminated+1 end,close=function() end}
    for i=1,4 do f.step() end
    eq('running',f.manager:get(f.task.id).status,'task remains running while EPUB child assembles')
    eq(0,f.built(),'parent does not assemble EPUB on its UI turn')
    local saved_before=f.writes()
    payload=assert(require('legado.lib.wire_codec').encode(child.job()));done=true
    eq(saved_before,f.writes(),'child assembly never saves task state through inherited storage')
    f.step();eq('completed',f.manager:get(f.task.id).status,'parent commits the child result')
    eq(1,f.built(),'background export produces one EPUB')
end
do
    local f=fixture(3,true,false,'epub')
    local child,terminated={},0
    f.manager.export_subprocess={available=function() return true end,start=function(_,job) child.job=job;return child end,
        poll=function() return false end,reap=function() return true end,
        terminate=function() terminated=terminated+1 end,close=function() end}
    for i=1,4 do f.step() end
    ok(f.manager:cancel(f.task.id),'task cancellation reaches an active EPUB child')
    eq(1,terminated,'EPUB cancellation terminates assembly')
    f.drain();eq('cancelled',f.stored[f.task.id].status,'late child polls cannot revive cancelled export')
end
do
    local jobs,refreshes,summary={},0,false
    local task={id='live',book={name='下载中'},status='running',completed=0,total=1406}
    local view=Downloads.new{manager={list=function(_,light) summary=light;return {task} end},
        scheduler={scheduleIn=function(_,delay,fn) jobs[#jobs+1]=fn end,unschedule=function() end},
        on_refresh=function() refreshes=refreshes+1 end}
    eq(true,summary,'download view requests lightweight records')
    jobs[1]();eq(0,refreshes,'unchanged progress does not rebuild the menu')
    task.completed=1;jobs[2]();eq(1,refreshes,'changed progress repaints once')
    view:close();jobs[3]();eq(1,refreshes,'closed screen ignores its scheduled repaint')
end
do
    local f=fixture(3,true,false,'epub')
    local child,reaped={},false
    f.manager.export_subprocess={available=function() return true end,start=function(_,job) child.job=job;return child end,
        poll=function() return false end,reap=function() return reaped end,terminate=function() end,close=function() end}
    for i=1,4 do f.step() end
    local prepared=child.job();f.export_files[f.task.final_path]='old EPUB'
    assert(f.manager:cancel(f.task.id))
    eq('new archive',f.export_files[prepared.path],'cancel waits for child ownership to end before removing stage')
    eq('old EPUB',f.export_files[f.task.final_path],'cancelled preparation preserves existing EPUB')
    reaped=true;f.drain()
    eq(nil,f.export_files[prepared.path],'cancel cleans exactly the owned stage after reaping')
end
do
    local f=fixture(3,true,false,'epub')
    f.step()
    local task=f.manager:get(f.task.id)
    local stage=task.final_path..'.'..require('legado.lib.identity').hash(task.id..':'..task.generation)..'.part'
    f.export_files[stage]='unfinished';f.export_files[stage..'.backup']='unfinished backup'
    f.export_files['unrelated.part']='keep'
    f.storage.listDownloadTasks=function() return {f.stored[task.id]} end
    local restarted=Manager.new(f.options)
    eq('interrupted',restarted:get(task.id).status,'host restart interrupts the prior generation')
    eq(nil,f.export_files[stage],'restart cleans the previous generation exact stage')
    eq(nil,f.export_files[stage..'.backup'],'restart cleans the previous generation partial backup')
    eq('keep',f.export_files['unrelated.part'],'restart never sweeps unrelated files')
end
for _,fail_terminal in ipairs({false,true}) do
    local f=fixture(3,true,false,'epub');local child,done,payload={},false,nil
    f.manager.export_subprocess={available=function() return true end,start=function(_,job) child.job=job;return child end,
        poll=function() return done,payload end,reap=function() return true end,terminate=function() end,close=function() end}
    local owned
    f.options.builder.publish=function(_,prepared)
        owned=prepared.path..'.backup';f.export_files[owned]='recoverable old EPUB'
        return nil,{code='STORAGE_ERROR',details={recoverable_backup=true}}
    end
    if fail_terminal then
        local put=f.storage.putDownloadTask;local rejected=false
        f.storage.putDownloadTask=function(self,task)
            if task.status=='failed' and not rejected then rejected=true;return nil,{code='STORAGE_ERROR'} end
            return put(self,task)
        end
    end
    for i=1,4 do f.step() end
    payload=assert(require('legado.lib.wire_codec').encode(child.job()));done=true;f.step()
    eq(fail_terminal and 'interrupted' or 'failed',f.manager:get(f.task.id).status,'publication recovery failure settles the task')
    eq('recoverable old EPUB',f.export_files[owned],'cleanup preserves the only recoverable backup')
    f.storage.listDownloadTasks=function() return {f.stored[f.task.id]} end
    local restarted=Manager.new(f.options)
    eq('recoverable old EPUB',f.export_files[owned],'startup retains a protected recovery backup')
    local retried,err=restarted:retry(f.task.id)
    eq(nil,retried,'retry cannot discard a protected previous generation')
    eq('STORAGE_ERROR',err.code,'protected backup reports an actionable failure')
end
do
    local f=fixture(1,true,false,'epub');local started=0
    f.manager.export_subprocess={available=function() return true end,start=function() started=started+1;return {} end}
    f.manager.tasks[f.task.id].final_path='old-output/old.epub'
    f.drain()
    eq('failed',f.manager:get(f.task.id).status,'old output path cannot bypass parent publication')
    eq(0,started,'invalid stage refuses to start a direct child writer')
    eq(0,f.built(),'invalid output leaves all existing EPUB files untouched')
end
return n
