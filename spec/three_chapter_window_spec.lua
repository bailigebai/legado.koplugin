local A=require('assertions')
local Session=require('legado.lib.reader_session')
local Scheduler=require('support.network_fakes').scheduler
local n=0
local function eq(want,got,why)n=n+1;A.equal(want,got,why)end
local function fixture(count, timing)
    local f={bodies={c1='<p>one</p>'},requests={},catalog={},opened={},prepared={}}
    f.chapters={};for i=1,7 do f.chapters[i]={uid='c'..i,index=i,title='chapter '..i,url='https://test/'..i}end
    f.scheduler=Scheduler()
    local cache={readBody=function(_,_,_,chapter)return f.bodies[chapter.uid],{code='STORAGE_ERROR'}end,
        writeBody=function(_,_,_,chapter,body)f.bodies[chapter.uid]=body;return true end,
        writeCatalog=function()return 'catalog.json'end}
    local ui={prepareChapter=function(_,state,chapter)f.prepared[chapter.uid]=true;return true end,
        openChapter=function(_,payload,callbacks)
            local doc={backend='immersive',getProgressFraction=function()return 0 end,close=function()end}
            f.opened[#f.opened+1]={doc=doc,callbacks=callbacks};callbacks.ready(doc);return doc
        end}
    local service={getContent=function(_,_,_,chapter,callback,options)
        local req={chapter=chapter,callback=callback,priority=options.priority,cancelled=0}
        function req:cancel()self.cancelled=self.cancelled+1 end
        function req:promote(value)self.priority=value end
        f.requests[#f.requests+1]=req;return req
    end,getChapters=function(_,_,_,callback,options)
        local req={callback=callback,options=options,cancelled=0}
        function req:cancel()self.cancelled=self.cancelled+1 end
        f.catalog[#f.catalog+1]=req;return req
    end}
    f.session=Session.new{cache=cache,ui=ui,service=service,scheduler=f.scheduler,timing=timing,
        settings={get=function(_,key)if key=='prefetch'then return 3 end end},
        storage={putProgress=function()return true end,getProgress=function()return {}end}}
    local chapters={};for i=1,count or 7 do chapters[i]=f.chapters[i]end
    assert(f.session:open({id='s'},{id='b',source_id='s'},chapters,1,{backend='immersive',catalog_complete=(count==nil)}))
    function f:finish(uid,err)
        for _,r in ipairs(self.requests)do if r.chapter.uid==uid and not r.done and r.cancelled==0 then
            r.done=true;r.callback(not err and {content='<p>'..uid..'</p>'}or nil,err);return r
        end end
        error('no active request '..uid)
    end
    return f
end
-- Session readiness precedes the adapter's atomic visible commit. Public callbacks wait.
do
    local f=fixture();f.bodies.c2='<p>two</p>'
    local candidate,called= nil,0
    f.session.ui.openChapter=function(_,payload,callbacks)
        local doc={backend='immersive',defer_notification=true,getProgressFraction=function()return 0 end,close=function()end}
        candidate={callbacks=callbacks,doc=doc};callbacks.ready(doc);return doc
    end
    assert(f.session:navigate(2,{on_complete=function()called=called+1 end}))
    eq(0,called,'logical readiness cannot expose a temporary candidate to public callbacks')
    candidate.callbacks.committed(candidate.doc)
    eq(1,called,'visible commit notifies the caller exactly once')
    candidate.callbacks.committed(candidate.doc)
    eq(1,called,'duplicate commit notification is harmless')
    eq(nil,f.session.active.previous,'committed state releases its old reader')
    f.session:close()
end
-- A newer explicit chapter selection owns the screen, even if older work completes later.
do
    local f=fixture();f.scheduler:runNext()
    f.session:navigate(2)
    f.bodies.c3='<p>three</p>'
    assert(f.session:navigate(3))
    f.requests[1].callback({content='<p>late two</p>'})
    eq(3,f.session.active.index,'old joined completion cannot override a newer cached selection')
    f.session:close()
end
do
    local f=fixture();f.bodies.c2='<p>two</p>'
    local pending
    f.session.ui.openChapter=function(_,payload,callbacks)
        pending={callbacks=callbacks,doc={backend='immersive',getProgressFraction=function()return 0 end,close=function()end}}
        return pending.doc
    end
    assert(f.session:navigate(2));local old=pending
    f.session:navigate(6) -- newer foreground download has not yet produced a reader
    eq(nil,old.callbacks.ready(old.doc),'old candidate cannot commit while a newer selection downloads')
    eq(1,f.session.active.index,'current page remains while the newest selection downloads')
    f.session:close()
end
-- Turning off speculative work cannot cancel a chapter the reader is awaiting.
do
    local f=fixture();f.scheduler:runNext()
    f.opened[1].callbacks.end_of_book(f.opened[1].doc)
    f.session.settings.get=function()return 0 end
    f:finish('c3')
    eq(0,f.requests[1].cancelled,'disabling background work retains the foreground subscriber')
    f:finish('c2')
    eq(2,f.session.active.index,'awaited chapter still opens with automatic prefetch disabled')
    eq(nil,f.session.foreground_state,'joined completion releases foreground ownership')
    f.session:close()
end
-- A reader opened asynchronously must not commit after the device suspends.
do
    local f=fixture();f.bodies.c2='<p>two</p>'
    local pending
    f.session.ui.openChapter=function(_,payload,callbacks)
        pending={callbacks=callbacks,doc={backend='immersive',getProgressFraction=function()return 0 end,close=function()end}}
        return pending.doc
    end
    assert(f.session:navigate(2))
    eq(true,f.session.pending~=nil,'candidate is waiting for asynchronous readiness')
    eq(true,pending.callbacks.can_open(),'queued engine open is allowed for the current pending candidate')
    f.opened[1].callbacks.pause(f.opened[1].doc,true)
    eq(false,pending.callbacks.can_open(),'queued engine open is rejected before touching old engine after suspend')
    local accepted=pending.callbacks.ready(pending.doc)
    eq(nil,accepted,'late readiness after suspend is rejected')
    eq(1,f.session.active.index,'late readiness cannot advance sleeping reader')
    eq(true,f.session.active.paused,'sleep remains paused')
    eq(nil,f.session.pending,'suspend releases the pending candidate')
    f.session:close()
end
-- Suspend must also work from an already-paused menu; catalogue demand is retried.
do
    local f=fixture(3);f.scheduler:runNext()
    local opened=f.opened[1]
    opened.callbacks.pause(opened.doc,false)
    opened.callbacks.pause(opened.doc,true)
    eq(1,f.requests[1].cancelled,'suspend from a paused menu cancels nearest worker')
    eq(1,f.requests[2].cancelled,'suspend from a paused menu cancels later worker')
    eq(1,f.catalog[1].cancelled,'suspend from a paused menu cancels catalog request')
    f.requests[1].callback({content='<p>stale</p>'})
    eq(nil,f.bodies.c2,'paused-menu suspended worker cannot publish late content')
    opened.callbacks.resume(opened.doc);f.scheduler:runNext()
    eq(2,#f.catalog,'resume retries the unfinished three-chapter catalog demand')
    eq(4,f.catalog[2].options.max_chapters,'resumed request still targets all three successors')
    f.session:close()
end
-- Suspending cancels both workers; stale completions cannot write, and resume refills.
do
    local f=fixture();f.scheduler:runNext()
    local opened=f.opened[1]
    opened.callbacks.pause(opened.doc,true)
    eq(1,f.requests[1].cancelled,'suspend cancels nearest worker')
    eq(1,f.requests[2].cancelled,'suspend cancels later worker')
    f.requests[1].callback({content='<p>stale</p>'})
    eq(nil,f.bodies.c2,'late suspended worker cannot publish')
    opened.callbacks.resume(opened.doc);f.scheduler:runNext()
    eq(4,#f.requests,'resume restarts the bounded window')
    f.session:close()
end
-- Timings correlate cache, save, readiness and UI submission, and ignore private fields.
do
    local metrics={}
    local f=fixture(nil,function(metric)metrics[#metrics+1]=metric end)
    f.scheduler:runNext();f:finish('c2');f:finish('c3');f:finish('c4')
    f.session:navigate(2)
    local callbacks=f.opened[#f.opened].callbacks
    callbacks.timing('paint_submit',callbacks.now(),{key='private',pages=1,over_budget=true})
    local paint=metrics[#metrics]
    eq('paint_submit',paint.stage,'UI reports actual submit stage')
    eq(2,paint.attempt,'second chapter has its own transition attempt')
    eq(true,paint.total_ms>=paint.ms,'total includes work before reader construction')
    eq(nil,paint.key,'diagnostics do not retain arbitrary or private payload')
    local saved=false
    for _,metric in ipairs(metrics)do
        if metric.stage=='progress_save' and metric.attempt==paint.attempt then saved=true end
    end
    eq(true,saved,'persistence is measured separately within the same attempt')
    f.session:close()
end

-- A short initial catalog must not hold the third upcoming chapter for six seconds.
do
    local f=fixture(3);f.scheduler:runNext()
    eq(1,#f.catalog,'partial catalog is immediately extended to the complete prefetch window')
    eq(4,f.catalog[1].options.max_chapters,'prepares three chapters after current, not three including current')
    eq(0,f.scheduler.now_value,'display refresh throttle does not delay catalog requests')
    f.catalog[1].callback(f.chapters,nil,{catalog_complete=true})
    f.session:close()
end
-- Slow N+1 cannot prevent N+2/N+3 downloads; no more than two are active.
do
    local f=fixture();f.scheduler:runNext()
    eq(2,#f.requests,'starts a bounded pair of content requests')
    eq('c2',f.requests[1].chapter.uid,'immediate chapter gets first request')
    eq('next',f.requests[1].priority,'immediate chapter has priority')
    f:finish('c3')
    eq(3,#f.requests,'freed slot starts third chapter without waiting for slow nearest chapter')
    eq('c4',f.requests[3].chapter.uid,'third upcoming chapter enters the window')
    f:finish('c4');f:finish('c2')
    eq(3,f.session.active.prefetch_status.cached,'all three complete bodies are ready')
    eq(true,f.prepared.c2 and f.prepared.c3 and f.prepared.c4,'all three chapters reach preparation')
    f.session.ui.getPreparedChapterStatus=function()return {first_pages=3,paginated=1}end
    local context=f.opened[1].callbacks.context(f.opened[1].doc,{})
    eq(3,context.prefetch.cached,'body readiness remains independent from pagination readiness')
    eq(1,context.prefetch.paginated,'only fully paginated chapters are reported as pagination ready')
    eq(3,context.prefetch.first_pages,'first-page readiness is reported separately')
    eq(nil,f.session.active.prefetch_status.paginated,'view snapshot does not mutate body-cache status')
    f.session.active.offline=true
    for index=2,4 do
        assert(f.session:navigate(index))
        eq(index,f.session.active.index,'offline cached navigation preserves target chapter')
    end
    eq(3,#f.requests,'three offline chapter turns issue no new requests')
    f.session:close()
end
-- Crossing into a still-running chapter joins it, while a completed crossing rolls the window.
do
    local f=fixture();f.scheduler:runNext()
    local next_request=f.requests[1]
    f.session:navigate(2)
    eq(2,#f.requests,'foreground joins the existing nearest chapter request')
    eq('foreground',next_request.priority,'joined request is promoted')
    f:finish('c2');f.scheduler:runNext()
    eq(0,f.requests[2].cancelled,'useful later request survives the chapter transition')
    f:finish('c3');f:finish('c4');f:finish('c5')
    eq(3,f.session.active.prefetch_status.cached,'sliding window fills three new successors')
    local count={};for _,r in ipairs(f.requests)do count[r.chapter.uid]=(count[r.chapter.uid]or 0)+1 end
    eq(1,count.c3,'retained chapter is downloaded exactly once')
    f.session:close()
end
return n
