local A=require('assertions')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local found,Export=pcall(require,'legado.lib.download_export')
eq(true,found,'EPUB assembly has an asynchronous cancellable worker')
local Wire=require('legado.lib.wire_codec')
local function fixture()
    local jobs,now,child,starts,closed,terminated,done,payload={},0,{},0,0,0,false,nil
    local scheduler={scheduleIn=function(_,delay,fn) jobs[#jobs+1]={at=now+delay,fn=fn} end,
        unschedule=function(_,fn) for _,job in ipairs(jobs) do if job.fn==fn then job.cancelled=true end end end}
    local adapter={available=function() return true end,start=function(_,job) starts=starts+1;child.job=job;return child end,
        poll=function() return done,payload end,reap=function() return true end,
        terminate=function() terminated=terminated+1 end,close=function() closed=closed+1 end}
    local delivered,err,cleaned=nil,nil,0
    local handle=Export.start{scheduler=scheduler,subprocess=adapter,now=function() return now end,
        job=function() return {path='book.epub'} end,callback=function(value,cause) delivered,err=value,cause end,
        cleanup=function() cleaned=cleaned+1 end}
    local function step() local item=table.remove(jobs,1);if item then now=item.at;if not item.cancelled then item.fn() end end end
    return {handle=handle,step=step,jobs=jobs,child=child,adapter=adapter,finish=function(value) done=true;payload=assert(Wire.encode(value)) end,
        delivered=function() return delivered,err end,stats=function() return starts,closed,terminated end,
        cleaned=function() return cleaned end}
end
do
    local f=fixture()
    f.adapter.start=function() f.handle:cancel();return f.child end
    f.step()
    local starts,closed,terminated=f.stats()
    eq(1,terminated,'cancel during process start owns and terminates the returned child')
    eq(1,closed,'cancel during process start closes the late pipe')
end
do
    local f=fixture();local reaped=false
    f.adapter.reap=function() return reaped end
    f.step();f.finish({path='ready.epub'});f.step()
    eq(nil,f.delivered(),'result waits for resource cleanup')
    eq(true,f.handle:cancel(),'pending cleanup result can still be cancelled')
    reaped=true;f.step();eq(nil,f.delivered(),'cleanup cannot deliver a cancelled result')
end
do
    local f=fixture();eq(0,f.stats(),'opening export does not synchronously build the EPUB')
    f.step();eq(1,f.stats(),'worker starts on a later UI turn')
    f.finish(f.child.job());f.step()
    eq('book.epub',f.delivered().path,'finished child publishes its result once')
    local starts,closed=f.stats();eq(1,closed,'finished child pipe is closed')
end
do
    local f=fixture();f.step();f.handle:cancel();f.finish({path='late.epub'});f.step()
    eq(nil,f.delivered(),'cancelled export ignores a late result')
    local starts,closed,terminated=f.stats();eq(1,terminated,'cancel terminates the export process')
    eq(1,closed,'cancel releases the export pipe')
end
do
    local f=fixture();f.handle:cancel();f.step();eq(0,f.stats(),'cancel before dispatch never starts the exporter')
end
do
    local f=fixture();f.step();f.finish({panic='private child message'});f.step()
    local value,err=f.delivered();eq(nil,value,'child panic cannot become successful completion')
    eq('STORAGE_ERROR',err.code,'child panic yields a stable error')
    eq(nil,err.message:find('private',1,true),'panic payload is not exposed')
end
do
    local f=fixture();local reaped=false
    f.adapter.reap=function() return reaped end
    f.step();f.handle:cancel()
    for i=1,10 do f.step() end
    eq(0,f.cleaned(),'cancel does not delete a stage still owned by a live child after eight polls')
    local starts,closed=f.stats();eq(0,closed,'unreaped child is not forgotten')
    reaped=true;f.step()
    eq(1,f.cleaned(),'owned stage is cleaned once after the child is reaped')
    eq(nil,f.delivered(),'cancel cleanup never publishes the stage')
end
return n
