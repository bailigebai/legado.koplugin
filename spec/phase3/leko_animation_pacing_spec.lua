package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Reader=require('legado.ui.leko_reader')
local Device=require('device')
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',150)..'</p>'
for _,native in ipairs{false,true} do
    Device.canDoSwipeAnimation=function() return native end
    for _,effect in ipairs{'original','swipe','ripple','side_ripple','ripple_in','wave'} do
        local view=assert(Reader.new{book={id='pacing'},chapter={uid='one'},body=body,
            style={page_transition=effect,swipe_portrait_delay_ms=40}})
        h.ui:show(view);h:drain()
        local dirty=h.dirty
        assert(view:nextPage());h:drain()
        eq(dirty,h.dirty,effect..' completion must not queue a duplicate full-page redraw')
        view:close();h:drain()
    end
end

local cleaning=assert(Reader.new{book={id='clean'},chapter={uid='clean'},body=body,
    style={page_transition='swipe',chapter_clean_wave_enabled=true}})
h.ui:show(cleaning);h:drain()
local clean_dirty=h.dirty
assert(cleaning:animateEntry('forward',true));h:drain()
eq(clean_dirty,h.dirty,'explicit cleanup wave does not append a duplicate whole-page refresh')
cleaning:close();h:drain()

Device.canDoSwipeAnimation=function() return false end
local view=assert(Reader.new{book={id='background'},chapter={uid='one'},body=body,
    style={page_transition='side_ripple'}})
h.ui:show(view)
assert(view:nextPage())
local pages=#view.page_starts;local dirty=h.dirty
h:step() -- previously queued background pagination must yield to the transition
eq(pages,#view.page_starts,'active chapter background pagination waits for the animation')
eq(dirty,h.dirty,'background pagination cannot overwrite a half-revealed page')
h:drain();eq(true,view.page_total~=nil,'pagination resumes after animation')
view:showLayoutMenu()
local found=false
for _,row in ipairs(view.layout_dialog.buttons) do for _,button in ipairs(row) do
    if button.text:find('竖屏帧间隔：',1,true) then
        found=true
        assert(view:applyStyle{swipe_portrait_delay_ms=30});view:showLayoutMenu()
        for _,rr in ipairs(view.layout_dialog.buttons) do for _,bb in ipairs(rr) do
            if bb.text:find('竖屏帧间隔：30ms',1,true)==1 then bb.callback() end
        end end
        eq(40,view.style.swipe_portrait_delay_ms,'visible vertical control offers a 40ms step')
    end
end end
eq(true,found,'delay wording distinguishes frame interval from whole animation time')
view:close();h:drain()

local Owner=require('legado.lib.koreader_reader_ui')
local owner=Owner.new{ui_manager=h.ui}
local state={source={id='s'},book={id='chapter'},chapters={{uid='c1'},{uid='c2'},{uid='c3'}},index=1}
local first=assert(owner:openChapter({state=state,body=body,progress={immersive_style={page_transition='swipe'}}},{}))
h:drain()
local before=h.dirty
local next_state={source=state.source,book=state.book,chapters=state.chapters,index=2}
local second=assert(owner:openChapter({state=next_state,body=body,progress={immersive_style={page_transition='swipe'}}},{}))
eq(first.widget,second.widget,'chapter transition keeps its window')
eq(before,h.dirty,'chapter adapter cannot queue a full repaint before its entry animation')
eq(true,second.widget.animation:isRunning(),'reused chapter starts an actual transition')
local Text=require('legado.lib.leko_text');local parse=Text.parse;local parses=0
Text.parse=function(...) parses=parses+1;return parse(...) end
assert(owner:prepareChapter(next_state,state.chapters[3],body))
eq(0,parses,'content arriving during a transition defers first-page parsing')
-- A host repaint now owns the display; no late animation may draw over it.
local pending=second.widget.animation.pending_frame
assert(second.widget:paintTo(h.screen.bb,0,0))
eq(false,second.widget.animation:isRunning(),'external repaint cancels animation ownership')
local refreshes=#h.refreshes;pending()
eq(refreshes,#h.refreshes,'late transition frame cannot overwrite a host repaint')
h:drain();eq(1,parses,'deferred content is prepared after the transition')
eq(1,owner:getPreparedChapterStatus(next_state).first_pages,'next chapter is usable after deferred preparation')
Text.parse=parse
second:close();h:drain()

-- Driver submission time is part of the selected frame interval.
local now=0
local Animation=require('legado.lib.leko_animation')
local refresh=h.screen.refreshUI
h.screen.refreshUI=function(...) now=now+.025;return refresh(...) end
local animation=Animation:new{screen=h.screen,ui_manager=h.ui,device=Device,clock=function()return now end}
assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},'forward',nil,
    {effect='swipe',portrait_delay_ms=40}))
h:step()
eq(true,math.abs(h.tasks[1].delay-.015)<.000001,'40ms interval subtracts 25ms spent submitting the frame')
animation:cancel();h.screen.refreshUI=refresh

-- UI interruptions may occur before a native submission's completion tick.
Device.canDoSwipeAnimation=function() return true end
assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},'forward',nil,{effect='original'}))
local submitted=#h.refreshes
assert(animation:settle());h:drain()
eq(submitted,#h.refreshes,'opening a menu after native submission must not submit the same page again')

-- Rotation before settling cannot copy an old-size page into the new screen.
for _,cleanup in ipairs{false,true} do
    local painted
    assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},'forward',function(_,value) painted=value end,
        {effect='swipe',chapter_changed=true,chapter_clean_wave_enabled=cleanup}))
    local old=h.screen.bb;h.screen.bb=h:buffer(800,600)
    submitted=#h.refreshes
    assert(animation:settle());h:drain()
    eq(submitted,#h.refreshes,'settle never submits an old-size framebuffer after rotation')
    eq(false,painted,'rotation requests a normal repaint at the new size')
    h.screen.bb:free();h.screen.bb=old
end

local schedule=h.ui.scheduleIn
for _,effect in ipairs{'original','cleanup'} do
    local options={effect='original',chapter_changed=true,chapter_clean_wave_enabled=effect=='cleanup'}
    h.ui.scheduleIn=function() error('scheduler unavailable') end
    local called,started=pcall(animation.begin,animation,{paintTo=function(_,bb) bb:fill(42) end},'forward',nil,options)
    eq(true,called,effect..' initial scheduling failure stays inside animation boundary')
    eq(nil,started,effect..' refuses an unscheduled animation')
    eq(false,animation:isRunning(),effect..' scheduling failure releases state')
    h.ui.scheduleIn=schedule
end
local painted
assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},'forward',function(_,value) painted=value end,
    {effect='swipe',chapter_changed=true,chapter_clean_wave_enabled=true}))
h.ui.scheduleIn=function() error('scheduler unavailable') end
eq(true,pcall(h.step,h),'cleanup rescheduling failure must not escape the event loop')
eq(false,animation:isRunning(),'cleanup rescheduling failure releases state')
eq(false,painted==true,'cleanup rescheduling failure requests a normal repaint')
h.ui.scheduleIn=schedule
animation:cancel();h:drain()

-- Large-panel workload budgets complement the per-pixel small-panel tests.
local BB=require('ffi/blitbuffer');local allocate=BB.new
for _,size in ipairs{{1264,1680},{1680,1264},{1073,1449}} do
for _,effect in ipairs{'original','swipe','ripple','side_ripple','ripple_in','wave'} do
for _,direction in ipairs{'forward','backward'} do
    local width,height=size[1],size[2];local copies,area,submissions=0,0,0
    local function buffer(w,hh)
        return {getWidth=function() return w end,getHeight=function() return hh end,getType=function() return 1 end,
            fill=function() end,free=function() end,blitFrom=function(_,_,x,y,sx,sy,rw,rh)
                assert(x>=0 and y>=0 and x+rw<=w and y+rh<=hh)
                copies=copies+rw*rh
            end}
    end
    BB.new=buffer
    local screen={bb=buffer(width,height),alignment_constraint=16,refreshUI=function(_,x,y,w,hh)
        assert(x>=0 and y>=0 and w>0 and hh>0 and x+w<=width and y+hh<=height)
        area=area+w*hh;submissions=submissions+1
    end}
    local measured=Animation:new{screen=screen,ui_manager=h.ui,device={canDoSwipeAnimation=function() return false end}}
    assert(measured:begin({paintTo=function() end},direction,nil,{effect=effect}));h:drain()
    eq(width*height,copies,effect..' copies the page only once across all frames')
    eq(true,area<=width*height*4,effect..' keeps accumulated driver damage below four screens')
    eq(true,submissions<=4*(width>height and 6 or 8),effect..' bounds driver submission count')
end
end
end
BB.new=allocate

-- Finishing the chapter's page count only changes chrome, never body text.
local indexed=assert(Reader.new{book={id='index'},chapter={uid='one'},body=body})
h.ui:show(indexed)
local dirty_call=h.ui.setDirty;local whole,regions=0,0
h.ui.setDirty=function(ui,widget,mode,region)
    if widget==indexed then if region then regions=regions+1 else whole=whole+1 end end
    return dirty_call(ui,widget,mode,region)
end
h:drain()
eq(true,indexed.page_total~=nil,'background page index finishes')
eq(0,whole,'completed page count does not flash the whole text page')
eq(true,regions>0,'completed page count repaints the header/footer information')
h.ui.setDirty=dirty_call;indexed:close();h:drain()
return n
