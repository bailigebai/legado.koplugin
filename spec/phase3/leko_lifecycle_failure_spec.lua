package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local R=require('legado.ui.leko_reader');local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local errors=0
local function reader()
    return assert(R.new{book={id='b'},chapter={uid='c',title='章'},body='<p>'..string.rep('正文',1000)..'</p>',
        ui_manager=h.ui,style={page_transition='off'},callbacks={error=function() errors=errors+1 end}})
end
local view=reader();h.ui:show(view)
local requests,cancelled={},0
view.callbacks.chapter=function(_,index,request)
    requests[#requests+1]=request
    return {cancel=function() cancelled=cancelled+1 end}
end
local first=view:requestChapter(2,false)
for _=1,20 do eq(first,view:requestChapter(2,false),'repeated chapter taps share their in-flight handle') end
eq(1,#requests,'repeated taps request the chapter once')
eq(0,cancelled,'repeated taps do not cancel the chapter being awaited')
requests[1].on_complete(nil,{code='NETWORK_ERROR',message='暂时失败'})
view:requestChapter(2,false)
eq(2,#requests,'a completed failure permits explicit retry')
view:requestChapter(3,false)
eq(1,cancelled,'a different target cancels the old subscription once')
requests[2].on_complete(nil,{code='NETWORK_ERROR',message='旧失败'})
eq(3,view.chapter_pending.index,'late completion cannot clear a newer chapter wait')
requests[3].on_complete({})
eq(nil,view.chapter_pending,'successful completion clears the wait state')
view.background_painter=function() error('paint boundary') end
local ok,result=pcall(view.paintTo,view,h.screen.bb,0,0)
eq(true,ok,'paintTo never leaks a Lua exception into UIManager')
eq(false,result,'failed painting is explicit for candidate and animation callers')
local target,why=view.animation:_renderTarget(view)
eq(nil,target,'animation cannot submit a framebuffer after guarded paint failure')
eq(true,type(why)=='string','animation exposes the render failure')
view.background_painter=nil

local pagination=view.pagination_job
view._makePage=function() error('pagination boundary') end
h.ui:unschedule(pagination)
eq(true,pcall(pagination),'background pagination has its own event boundary')
eq(nil,view.pagination_job,'failed pagination does not leave a scheduled handle')
view._makePage=nil
view:_startPagination();local stale=view.pagination_job
view:_startPagination();local latest=view.pagination_job
stale()
eq(latest,view.pagination_job,'late pagination callbacks cannot clear a newer generation handle')
local clock=view.clock_job;local dirty=h.ui.setDirty
h.ui:unschedule(clock)
h.ui.setDirty=function() error('clock refresh boundary') end
eq(true,pcall(clock),'clock errors cannot escape the scheduled callback')
h.ui.setDirty=dirty
local rescheduled=false
for _,task in ipairs(h.tasks) do if task.fn==clock then rescheduled=true end end
eq(true,rescheduled,'a transient refresh failure does not permanently disable the reader clock')
eq(true,errors>=3,'background entry failures reach diagnostics')

local cancel=view.animation.cancel
view.animation.cancel=function() error('animation cancel boundary') end
local before=view:getPosition().char
eq(true,view:nextPage(),'a broken animation still permits the next readable page')
eq(true,view:getPosition().char>before,'animation fallback changes actual text position')
view.animation.cancel=cancel

local original_context=view.getReadingContext
view.getReadingContext=function() error('dispose context boundary') end
assert(view:close())
eq(true,view.closed,'context failure cannot stop disposal')
eq(nil,view.model,'disposed view releases its full chapter text')
eq(0,#h.tasks,'cleanup releases clock and pagination despite earlier failures')
eq(true,pcall(stale),'late pagination after disposal is harmless')
eq(true,pcall(clock),'late clock after disposal is harmless')
eq(0,#h.tasks,'late callbacks never resurrect disposed work')
view.getReadingContext=original_context
for i=2,#h.buffers do eq(1,h.buffers[i].freed,'every allocated native buffer is released exactly once') end
return n
