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
h.ui.setDirty=function(_,widget,mode,region) queued[#queued+1]={widget=widget,mode=mode,region=region} end
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

-- Every chapter boundary belongs to the host compositor, regardless of the
-- chapter-internal effect or whether the next chapter was prepared in advance.
for _,effect in ipairs{'original','swipe','swipe_classic','ripple','side_ripple','ripple_in','wave','off'} do
for _,prepared in ipairs{false,true} do
for _,cleanup in ipairs{false,true} do
    Device.canDoSwipeAnimation=function() return false end
    local view,document=fixture(effect,cleanup,prepared)
    local first=view.page.start_position
    eq(false,view.animation:isRunning(),effect..': no regional transition across chapters')
    eq(nil,view.animation.pending_frame,'no delayed strip may overwrite the entry screen')
    local whole=0
    for _,r in ipairs(queued) do if r.widget==view and not r.region then
        whole=whole+1;eq(cleanup and 'full' or 'partial',r.mode,'cleanup controls whole-page refresh strength')
    end end
    eq(1,whole,'one full-page composition is requested at the boundary')
    assert(view:nextPage())
    eq(first,view.page.start_position,effect..': early tap presents the first page without advancing')
    repaint(view);h:drain();repaint(view)
    visible(42,effect..': first page is fully visible, without old text or black edge')
    assert(view:nextPage());h:drain();repaint(view)
    eq(true,view.page.start_position~=first,effect..': subsequent tap advances normally')
    visible(43,effect..': second page follows the visible first page')
    document:close();h:drain();queued={}
end
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
    eq(false,view.animation:isRunning(),'native capability cannot bypass chapter composition')
    repaint(view);h:drain();repaint(view)
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
repaint(view);h:drain();repaint(view)
assert(view:nextPage())
while view.animation.strip_index==0 do assert(h:step()) end
local late=view.animation.pending_frame
view._paintTo=function() error('injected host redraw failure') end
queued={}
h.ui:setDirty(view,'ui',{x=0,y=H-10,w=W,h=10})
repaint(view)
late()
visible(43,'failed footer redraw retains the captured ordinary page')
eq(false,view.animation:isRunning(),'failed redraw retires the transition')
eq(true,view.last_error~=nil,'redraw failure is still reported, not silently swallowed')
document:close();h:drain()

local view,document=fixture('swipe',true,true)
document:close();local count=#queued
h:drain()
eq(count,#queued,'closed chapter cannot request a late repaint')
eq(0,#h.tasks,'closing the reader clears entry and background tasks')

-- Exercise the real session, paginator and KOReader text widgets. Only glyph
-- rasterization is replaced, so old chapter widgets cannot pass a flat-fill test.
-- Also use the unmodified host composition/refresh queues in this section.
local function noop() end
Device._UIManagerReady=noop
require('ui/time').now=function() return 0 end
require('dbg').v=noop
G_reader_settings.isFalse=function(_,name) return name=='flash_ui' end
h.screen.beforePaint,h.screen.afterPaint=noop,noop
h.screen.getDPI=function() return 300 end
local submissions={}
for _,name in ipairs{'refreshA2','refreshFast','refreshUI','refreshPartial','refreshNoMergeUI',
    'refreshNoMergePartial','refreshFlashUI','refreshFlashPartial','refreshFull'} do
    h.screen[name]=function(_,x,y,w,hh)
        submissions[#submissions+1]={kind=name,x=x,y=y,w=w,h=hh}
        panel:blitFrom(h.screen.bb,x,y,x,y,w,hh)
    end
end
package.loaded['ui/uimanager']=nil
local host=require('ui/uimanager')
host.scheduleIn,host.nextTick,host.unschedule=h.ui.scheduleIn,h.ui.nextTick,h.ui.unschedule
host.FULL_REFRESH_COUNT=100000
local Render=require('ui/rendertext')
local draws={}
Render.renderUtf8Text=function(_,bb,x,y,face,text)
    draws[#draws+1]=text
    for ch in tostring(text):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if x>=0 and x+2<=bb:getWidth() and y>=1 and y<=bb:getHeight() then
            bb:paintRect(x,y-1,2,1,ch:byte(#ch))
        end
        x=x+face.size
    end
end
local Session=require('legado.lib.reader_session')
local chapters={{uid='c1',title='ONE',index=1},{uid='c2',title='TWO',index=2},{uid='c3',title='THREE',index=3}}
local bodies={c1='<p>'..string.rep('AAA',300)..'</p>',c2='<p>'..string.rep('BBB',300)..'</p>',c3='<p>'..string.rep('CCC',300)..'</p>'}
for _,effect in ipairs{'original','swipe_classic','swipe','ripple','side_ripple','ripple_in','wave','off'} do
for _,cleanup in ipairs{false,true} do
    local progress={immersive_style={page_transition=effect,chapter_clean_wave_enabled=cleanup}}
    local owner=Owner.new{ui_manager=host}
    local session=Session.new{ui=owner,scheduler=host,
        settings={get=function(_,k) if k=='prefetch' then return 3 end end},
        storage={getProgress=function() return progress end,putProgress=function(_,p) progress=p;return true end},
        cache={readBody=function(_,_,_,c) return bodies[c.uid] end},
        service={getContent=function() error('bodies are cached') end}}
    assert(session:open({id='s'},{id='b',source_id='s'},chapters,1,{backend='immersive'}))
    h:drain();local view=owner.current_document.widget;host:_repaint()
    assert(view:setProgressFraction(1));h:drain();host:_repaint()
    assert(view:nextPage());eq(2,session.active.index,'session commits the next chapter')
    eq(false,view.animation:isRunning(),'real session uses full-page chapter composition')
    -- Let footer/index tasks run before the first composition: their smaller
    -- refresh regions must merge into, never replace, the full chapter request.
    draws={};submissions={};h:drain();host:_repaint()
    eq(1,#submissions,'real host merges boundary and footer into one submission')
    eq(cleanup and 'refreshFull' or 'refreshPartial',submissions[1].kind,'host retains chapter refresh strength')
    eq(W,submissions[1].w,'host refresh spans the entire width')
    eq(H,submissions[1].h,'host refresh spans the entire height')
    local text=table.concat(draws)
    eq(true,text:find('BBB',1,true)~=nil,'new chapter text reaches the host framebuffer')
    eq(nil,text:find('AAA',1,true),'old chapter body is not drawn at the boundary')
    local want=raster(W,H);view:_paintTo(want,0,0)
    local complete=true
    for i=0,W*H-1 do if panel.pixels[i]~=want.pixels[i] then complete=false;break end end
    eq(true,complete,'visible panel matches the complete new chapter, including its right edge')
    want:free()
    assert(view:previousPage());h:drain();host:_repaint()
    eq(1,session.active.index,'backward boundary returns to the previous chapter')
    eq(true,view.page.at_end,'backward boundary presents the previous chapter last page')
    assert(view:requestChapter(3,false));h:drain();host:_repaint()
    eq(3,session.active.index,'directory jump commits the selected chapter')
    eq(1,view.page.start_position.char,'directory jump keeps its first screen')
    session:close();h:drain();host:_repaint()
    eq(0,#host._window_stack,'closed chapter leaves no host reader window')
end end
return n
