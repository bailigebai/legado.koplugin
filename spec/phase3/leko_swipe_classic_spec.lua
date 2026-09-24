package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local BB=require('ffi/blitbuffer')
local function raster(w,height)
    local b={w=w,h=height,pixels={}}
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getType() return 1 end
    function b:fill(value) for i=0,self.w*self.h-1 do self.pixels[i]=value end end
    function b:paintRect(x,y,width,hh,value)
        for yy=y,y+hh-1 do for xx=x,x+width-1 do self.pixels[yy*self.w+xx]=value end end
    end
    function b:blitFrom(src,x,y,sx,sy,width,hh)
        assert(not self.freed and not src.freed)
        assert(x>=0 and y>=0 and x+width<=self.w and y+hh<=self.h)
        assert(sx>=0 and sy>=0 and sx+width<=src.w and sy+hh<=src.h)
        for yy=0,hh-1 do for xx=0,width-1 do
            self.pixels[(y+yy)*self.w+x+xx]=src.pixels[(sy+yy)*src.w+sx+xx]
        end end
    end
    function b:free() assert(not self.freed);self.freed=true end
    b.colorblitFrom=b.blitFrom -- Glyph masks are irrelevant to the repaint ownership check.
    return b
end

-- Unlike a framebuffer-only check, this models what the panel has received.
-- A footer-only refresh must not strand old text when it interrupts a reveal.
local Owner=require('legado.lib.koreader_reader_ui')
local original_new,original_bb,original_refresh,original_dirty=BB.new,h.screen.bb,h.screen.refreshUI,h.ui.setDirty
local original_w,original_h=h.dimensions.w,h.dimensions.h
h.dimensions.w,h.dimensions.h=320,480
BB.new=raster;h.screen.bb=raster(320,480)
local panel=raster(320,480)
h.screen.refreshUI=function(_,x,y,w,hh) panel:blitFrom(h.screen.bb,x,y,x,y,w,hh) end
local queued={}
h.ui.setDirty=function(_,widget,mode,region) queued[#queued+1]={widget=widget,region=region} end
local body='<p>'..string.rep('甲乙丙丁',60)..'</p>'
for _,effect in ipairs{'swipe','ripple','side_ripple','ripple_in','wave'} do
    local owner=Owner.new{ui_manager=h.ui}
    local state={source={id='s'},book={id='book'},chapters={{uid='c1'},{uid='c2'}},index=1}
    local first=assert(owner:openChapter({state=state,body=body,progress={immersive_style={page_transition=effect}}},{}))
    h:drain()
    -- Glyph rendering is external to this test: each chapter paints a distinct page.
    first.widget._paintTo=function(view,bb) bb:fill(view.chapter.uid=='c2' and 42 or 7) end
    h.screen.bb:fill(7);panel:fill(7)
    local state2={source=state.source,book=state.book,chapters=state.chapters,index=2}
    local second=assert(owner:openChapter({state=state2,body=body,progress={immersive_style={page_transition=effect}}},{}))
    while second.widget.animation.strip_index==0 do assert(h:step()) end
    local old=false;for i=0,320*480-1 do if panel.pixels[i]==7 then old=true;break end end
    eq(true,old,'interruption occurs while some of the previous chapter is still visible')
    queued={}
    local late=second.widget.animation.pending_frame
    h.ui:setDirty(second.widget,'ui',{x=0,y=470,w=320,h=10})
    assert(second.widget:paintTo(h.screen.bb,0,0))
    -- KOReader paints upper widgets after the reader and refreshes only after composition.
    h.screen.bb:paintRect(0,0,20,10,99)
    for _,request in ipairs(queued) do
        local r=request.region or {x=0,y=0,w=320,h=480}
        h.screen:refreshUI(r.x,r.y,r.w,r.h)
    end
    if late then late() end
    local complete=true
    for y=0,479 do for x=0,319 do
        local want=(y<10 and x<20) and 99 or 42
        if panel.pixels[y*320+x]~=want then complete=false end
    end end
    eq(true,complete,effect..': a partial host repaint leaves the complete next chapter and its overlay visible')
    eq(false,second.widget.animation:isRunning(),'interrupted chapter reveal has no remaining frame owner')
    second:close();h:drain()
end
BB.new,h.screen.bb,h.screen.refreshUI,h.ui.setDirty=original_new,original_bb,original_refresh,original_dirty
h.dimensions.w,h.dimensions.h=original_w,original_h

-- Swipe's upstream wipe must finish within one scheduled turn, without a
-- background pagination or repaint task being interleaved between strips.
local Animation=require('legado.lib.leko_animation')
local ffiutil=require('ffi/util');local original_sleep=ffiutil.usleep
BB.new=raster
for _,landscape in ipairs{false,true} do
for _,direction in ipairs{'forward','backward'} do
    local w,height=landscape and 192 or 128,landscape and 128 or 192
    local screen={bb=raster(w,height),alignment_constraint=16}
    local visible=raster(w,height);visible:fill(7);screen.bb:fill(7)
    local calls,delays,before,after={}, {},0,0
    screen.beforePaint=function() before=before+1 end
    screen.afterPaint=function() after=after+1 end
    screen.refreshUI=function(_,x,y,width,hh)
        visible:blitFrom(screen.bb,x,y,x,y,width,hh);calls[#calls+1]={x=x,w=width}
    end
    screen.refreshFast=function() error('Swipe preset must use upstream default UI refresh') end
    screen.setSwipeAnimations=function(_,enabled) assert(not enabled,'Swipe is always software') end
    screen.setSwipeDirection=function() end
    ffiutil.usleep=function(microseconds) delays[#delays+1]=microseconds end
    local animation=Animation:new{screen=screen,ui_manager=h.ui,device={canDoSwipeAnimation=function()return true end}}
    local done
    assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},direction,function(_,painted) done=painted end,
        {effect='swipe_classic'}))
    local background=false;h.ui:scheduleIn(0,function()background=true end)
    h:step()
    eq(true,done,'one Swipe task submits a complete new page')
    eq(false,background,'unrelated UI work does not interleave with upstream wipe strips')
    eq(false,animation:isRunning(),'Swipe releases its target before the next task')
    eq(landscape and 6 or 8,#calls,'Swipe keeps upstream orientation-specific strip count')
    eq(#calls-1,#delays,'upstream waits only between strip submissions')
    eq(1,before,'Swipe opens one paint transaction')
    eq(1,after,'Swipe closes one paint transaction')
    for i,call in ipairs(calls) do
        eq(direction=='forward' and w-i*(landscape and 32 or 16) or (i-1)*(landscape and 32 or 16),call.x,'strip direction matches upstream')
        eq(landscape and 32 or 16,call.w,'aligned strips have no overlap or gaps')
    end
    for _,delay in ipairs(delays) do eq(landscape and 10000 or 20000,delay,'default wait matches upstream microseconds') end
    local full=true;for i=0,w*height-1 do if visible.pixels[i]~=42 then full=false end end
    eq(true,full,'Swipe reaches every visible pixel')
    h:drain()
    delays={}
    assert(animation:begin({paintTo=function(_,bb) bb:fill(99) end},direction,nil,
        {effect='swipe_classic',portrait_delay_ms=40,landscape_delay_ms=40,
            refresh_mode='fast',chapter_changed=true,chapter_clean_wave_enabled=true}))
    h:step()
    eq(false,animation:isRunning(),'Swipe preset is not replaced by the separate chapter cleanup wave')
    eq((landscape and 6 or 8)-1,#delays,'old settings do not remove the upstream waits')
    for _,delay in ipairs(delays) do eq(landscape and 10000 or 20000,delay,'Swipe ignores saved custom delays and retains upstream defaults') end
end
end
for _,fault in ipairs{'refresh','sleep','cancel','resize'} do
    local screen={bb=raster(128,192),alignment_constraint=16}
    local animation,completed,painted,submissions,target
    submissions=0
    screen.refreshUI=function() submissions=submissions+1;if fault=='refresh' then return false end end
    ffiutil.usleep=function()
        if fault=='sleep' then error('wait failed')
        elseif fault=='cancel' then animation:cancel()
        elseif fault=='resize' then screen.bb=raster(192,128) end
    end
    animation=Animation:new{screen=screen,ui_manager=h.ui,device={canDoSwipeAnimation=function()return false end}}
    assert(animation:begin({paintTo=function(_,bb) target=bb;bb:fill(42) end},'forward',function(_,value)
        completed=true;painted=value
    end,{effect='swipe_classic'}))
    local late=animation.pending_frame
    eq(true,pcall(h.step,h),fault..' cannot escape the animation task')
    eq(false,animation:isRunning(),fault..' ends frame ownership')
    eq(true,target.freed,fault..' frees the captured page')
    eq(1,submissions,fault..' cannot submit additional strips')
    late();eq(1,submissions,fault..' ignores stale callbacks')
    if fault=='cancel' then eq(nil,completed,'cancelled Swipe does not notify completion')
    else eq(false,painted,'failed Swipe requests an ordinary complete repaint') end
end
for _,size in ipairs{{1,1},{5,7},{119,157},{157,119}} do
    for _,direction in ipairs{'forward','backward'} do
        local w,height=size[1],size[2]
        local screen={bb=raster(w,height),alignment_constraint=16}
        local visible=raster(w,height);visible:fill(7)
        screen.refreshUI=function(_,x,y,width,hh) visible:blitFrom(screen.bb,x,y,x,y,width,hh) end
        screen.refreshFast={} -- Old hosts may have a non-callable Fast placeholder.
        ffiutil.usleep=function(delay) eq(w>height and 10000 or 20000,delay,'saved zero delay cannot alter Swipe preset') end
        local animation=Animation:new{screen=screen,ui_manager=h.ui,device={canDoSwipeAnimation=function()return false end}}
        assert(animation:begin({paintTo=function(_,bb) bb:fill(42) end},direction,nil,
            {effect='swipe_classic',refresh_mode='fast',portrait_delay_ms=0,landscape_delay_ms=0}))
        h:step()
        local full=true;for i=0,w*height-1 do if visible.pixels[i]~=42 then full=false end end
        eq(true,full,'odd/small panels keep complete Swipe coverage with Fast fallback')
        eq(false,animation:isRunning(),'fixed-preset Swipe completes without another frame')
    end
end
BB.new=original_new;ffiutil.usleep=original_sleep

local Reader=require('legado.ui.leko_reader')
local saved
local view=assert(Reader.new{book={id='controls'},chapter={uid='c'},body=body,
    style={page_transition='swipe_classic',swipe_portrait_delay_ms=30},
    callbacks={style_changed=function(_,style) saved=style;return true end}})
view:showLayoutMenu()
local named,mode_button=false
for _,row in ipairs(view.layout_dialog.buttons) do for _,button in ipairs(row) do
    if button.text=='动画效果：Swipe动画' then named=true;mode_button=button end
    eq(false,button.text:find('帧延迟',1,true)~=nil or button.text:find('帧间隔',1,true)~=nil,'Swipe preset exposes no delay controls')
    eq(false,button.text:find('刷新模式',1,true)~=nil or button.text:find('跨章净屏动画',1,true)~=nil,'Swipe preset exposes no competing effect controls')
end end
eq(true,named,'visible mode is named Swipe动画 and survives normalization')
mode_button.callback() -- Return to the existing independently adjustable wipe.
eq('swipe',saved.page_transition,'changing away from Swipe preset restores another effect')
local delay
for _,row in ipairs(view.layout_dialog.buttons) do for _,button in ipairs(row) do
    if button.text=='竖屏帧间隔：30ms' then delay=button end
end end
assert(delay);eq(true,delay.enabled~=false,'other effects retain their saved adjustable delay')
delay.callback()
eq(40,saved.swipe_portrait_delay_ms,'editing delay saves the chosen per-book value')
eq('swipe',saved.page_transition,'editing another effect does not switch back to Swipe preset')
view:close();h:drain()
return n
