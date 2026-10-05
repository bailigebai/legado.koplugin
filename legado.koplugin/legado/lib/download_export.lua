local Wire=require('legado.lib.wire_codec')
local Errors=require('legado.lib.errors')
local Export={}

-- Assemble files in a child; only the parent may commit the task's final state.
function Export.start(o)
    local state={cancelled=false,finished=false,starting=false,cleaned=false}
    local handle={}
    local function unschedule()
        local job=state.job;state.job=nil
        if job and o.scheduler.unschedule then pcall(o.scheduler.unschedule,o.scheduler,job) end
    end
    local function clean_stage()
        if state.cleaned then return end
        state.cleaned=true
        if o.cleanup then pcall(o.cleanup) end
    end
    local function cleanup(terminate,after,attempt)
        local child=state.child
        if not child then if after then after() end;clean_stage();return end
        if terminate then pcall(o.subprocess.terminate,o.subprocess,child) end
        local called,reaped=pcall(o.subprocess.reap,o.subprocess,child)
        attempt=attempt or 1
        if called and reaped then
            pcall(o.subprocess.close,o.subprocess,child);state.child=nil
            if after then after() end
            clean_stage()
        else
            -- Never delete an archive while its child could still be writing it.
            -- Reaping remains nonblocking and backs off to one poll per second.
            pcall(o.scheduler.scheduleIn,o.scheduler,math.min(1,.05*2^math.min(attempt-1,5)),function()
                if state.cancelled then pcall(o.subprocess.terminate,o.subprocess,child) end
                cleanup(false,after,attempt+1)
            end)
        end
    end
    local function finish(value,err,terminate)
        if state.finished or state.cancelled then return end
        state.finished=true;unschedule()
        cleanup(terminate,function()
            if not state.cancelled then state.delivered=true;pcall(o.callback,value,err) end
        end)
    end
    local function schedule(delay,fn)
        local job
        job=function() if state.job~=job then return end;state.job=nil;if not state.cancelled and not state.finished then fn() end end
        state.job=job
        local called=pcall(o.scheduler.scheduleIn,o.scheduler,delay,job)
        if not called then state.job=nil;finish(nil,Errors.new(Errors.STORAGE_ERROR,'EPUB worker scheduling failed'),true) end
    end
    function handle:cancel()
        if state.cancelled or state.delivered then return false end
        state.cancelled=true;unschedule()
        if state.child then pcall(o.subprocess.terminate,o.subprocess,state.child) end
        if not state.finished and not state.starting then cleanup(false) end
        return true
    end
    local poll
    poll=function()
        if o.now()>=state.deadline then finish(nil,Errors.new(Errors.TIMEOUT,'EPUB assembly timed out'),true);return end
        local called,done,payload,err=pcall(o.subprocess.poll,o.subprocess,state.child)
        if not called or err then finish(nil,Errors.new(Errors.STORAGE_ERROR,'EPUB worker failed'),true);return end
        if not done then schedule(.05,poll);return end
        local value=Wire.decode(payload)
        if type(value)~='table' or value.panic then
            finish(nil,Errors.new(Errors.STORAGE_ERROR,'EPUB worker result is invalid'),true)
        else finish(value) end
    end
    schedule(.01,function()
        local available,ready=pcall(o.subprocess.available,o.subprocess)
        if not available or not ready then finish(nil,Errors.new(Errors.STORAGE_ERROR,'EPUB background worker is unavailable'));return end
        state.starting=true
        local called,child=pcall(o.subprocess.start,o.subprocess,o.job)
        state.starting=false
        if state.cancelled and (not called or not child) then clean_stage();return end
        if not called or not child then finish(nil,Errors.new(Errors.STORAGE_ERROR,'EPUB background worker could not start'));return end
        state.child=child
        if state.cancelled then cleanup(true);return end
        state.deadline=o.now()+120
        schedule(.05,poll)
    end)
    return handle
end
return Export
