package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local BB=require('ffi/blitbuffer')
local Device=require('device')
local Owner=require('legado.lib.koreader_reader_ui')
require('ffi/util').usleep=function() end
local function raster(w,height)
    local b={w=w,h=height,pixels={}}
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getType() return 1 end
    function b:fill(v) for i=0,self.w*self.h-1 do self.pixels[i]=v end end
    function b:paintRect(x,y,width,hh,v)
        for yy=y,y+hh-1 do for xx=x,x+width-1 do self.pixels[yy*self.w+xx]=v end end
    end
    function b:blitFrom(src,x,y,sx,sy,width,hh)
        assert(not self.freed and not src.freed,'no freed page may be painted')
        assert(x>=0 and y>=0 and x+width<=self.w and y+hh<=self.h)
        assert(sx>=0 and sy>=0 and sx+width<=src.w and sy+hh<=src.h)
        for yy=0,hh-1 do for xx=0,width-1 do
            self.pixels[(y+yy)*self.w+x+xx]=src.pixels[(sy+yy)*src.w+sx+xx]
        end end
    end
    function b:free() assert(not self.freed,'page freed twice');self.freed=true end
    b.colorblitFrom=b.blitFrom
    return b
end
local W,H=320,480
h.dimensions.w,h.dimensions.h=W,H
BB.new=raster;h.screen.bb=raster(W,H)
local panel=raster(W,H)
for _,name in ipairs{'refreshUI','refreshNoMergeUI','refreshFast'} do
    h.screen[name]=function(_,x,y,w,hh) panel:blitFrom(h.screen.bb,x,y,x,y,w,hh) end
end
local queued={}
h.ui.setDirty=function(_,widget,mode,region) queued[#queued+1]={widget=widget,region=region} end
local function repaint(view)
    local requests=queued;queued={}
    if #requests==0 then return end
    local dirty=false
    for _,r in ipairs(requests) do if r.widget==view then dirty=true end end
    if dirty then view:paintTo(h.screen.bb,0,0) end
    -- setDirty during paint contributes refreshes to the same composition.
    for _,r in ipairs(queued) do requests[#requests+1]=r end;queued={}
    for _,r in ipairs(requests) do
        local g=r.region or {x=0,y=0,w=W,h=H}
        h.screen:refreshUI(g.x,g.y,g.w,g.h)
    end
end
local function visible(value,message)
    local complete=true
    for i=0,W*H-1 do if panel.pixels[i]~=value then complete=false;break end end
    eq(true,complete,message)
end
local function fixture(effect,cleanup,prepared)
    local owner=Owner.new{ui_manager=h.ui}
    local chapters={{uid='one',title='第一章'},{uid='two',title='第二章'}}
    local state={source={id='source'},book={id='book'},chapters=chapters,index=1}
    local style={page_transition=effect,chapter_clean_wave_enabled=cleanup}
    local first=assert(owner:openChapter({state=state,body='<p>'..string.rep('甲乙',250)..'</p>',
        progress={immersive_style=style}},{}))
    h:drain();queued={}
    local body='<p>'..string.rep('丙丁',350)..'</p>'
    if prepared then assert(owner:prepareChapter(state,chapters[2],body));h:drain() end
    -- Keep real pagination/widgets/cursor, replacing only font rasterization.
    first.widget._paintTo=function(view,bb)
        bb:fill(view.chapter.uid=='one' and 7 or (view.page.start_position.char==1 and view.page.start_position.paragraph==1 and 42 or 43))
    end
    h.screen.bb:fill(7);panel:fill(7)
    local next_state={source=state.source,book=state.book,chapters=chapters,index=2}
    local second=assert(owner:openChapter({state=next_state,body=body,progress={immersive_style=style}},{}))
    return second.widget,second
end

-- The cleanup wave's first frame contains old text and a black edge. A rapid
-- second tap must finish chapter two's first page, not cancel it for page two.
for _,effect in ipairs{'swipe','swipe_classic','ripple','side_ripple','ripple_in','wave','off'} do
for _,prepared in ipairs{false,true} do
    Device.canDoSwipeAnimation=function() return false end
    local view,document=fixture(effect,effect=='swipe',prepared)
    local first=view.page.start_position
    if effect=='swipe' then
        while view.animation.chapter_wave.step_index==0 do assert(h:step()) end
        eq(0,panel.pixels[W-1],'reproduces the black edge before chapter cleanup completes')
        eq(7,panel.pixels[0],'old chapter remains on most of the panel at this point')
    end
    local late=view.animation.pending_frame or view.animation.chapter_wave.pending_frame
    assert(view:nextPage())
    eq(first,view.page.start_position,effect..': early tap presents the first page without advancing')
    repaint(view);h:drain();repaint(view)
    if late then late() end
    visible(42,effect..': first page is fully visible, without old text or black edge')
    assert(view:nextPage());h:drain();repaint(view)
    eq(true,view.page.start_position~=first,effect..': subsequent tap advances normally')
    visible(43,effect..': second page follows the visible first page')
    document:close();h:drain();queued={}
end
end

for _,effect in ipairs{'swipe','side_ripple','off'} do
    local view,document=fixture(effect,effect=='swipe',false)
    local first=view.page.start_position
    assert(view:previousPage())
    eq(first,view.page.start_position,'early backward turn also presents the entry screen')
    repaint(view);h:drain();repaint(view)
    visible(42,'backward input completes the same first screen')
    document:close();h:drain();queued={}
end

-- A normally completed transition (including the synchronous native submit)
-- does not require an extra tap and keeps ordinary fast page turns unchanged.
for _,native in ipairs{false,true} do
    Device.canDoSwipeAnimation=function() return native end
    local view,document=fixture(native and 'original' or 'swipe_classic',false,true)
    if not native then h:drain() end
    visible(42,'completed entry already presents the first screen')
    local first=view.page.start_position
    assert(view:nextPage())
    eq(true,view.page.start_position~=first,'completed entry advances on the next tap')
    h:drain();repaint(view)
    visible(43,'normal native/software navigation reaches page two')
    document:close();h:drain();queued={}
end
Device.canDoSwipeAnimation=function() return false end

-- A host footer redraw can fail after animation capture succeeded (font or
-- chrome rendering). Retain that captured page until the redraw is accepted.
local view,document=fixture('swipe',true,true)
while view.animation.chapter_wave.step_index==0 do assert(h:step()) end
local late=view.animation.chapter_wave.pending_frame
view._paintTo=function() error('injected host redraw failure') end
queued={}
h.ui:setDirty(view,'ui',{x=0,y=H-10,w=W,h=10})
repaint(view)
late()
visible(42,'failed footer redraw cannot strand the previous chapter and black band')
eq(false,view.animation:isRunning(),'failed redraw retires the transition')
eq(true,view.last_error~=nil,'redraw failure is still reported, not silently swallowed')
document:close();h:drain()

local view,document=fixture('swipe',true,true)
local late=view.animation.chapter_wave.pending_frame
document:close();local count=#queued
late();h:drain()
eq(count,#queued,'closed chapter cannot request a late repaint')
eq(0,#h.tasks,'closing the reader clears entry and background tasks')
return n
