package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Animation=require('legado.lib.leko_animation')
local Blitbuffer=require('ffi/blitbuffer')
local original_new=Blitbuffer.new
local buffers={}
local function raster(w,height)
    local b={w=w,h=height,pixels={},writes={},freed=0}
    function b:getWidth() return self.w end
    function b:getHeight() return self.h end
    function b:getType() return 1 end
    function b:fill(value) for i=0,self.w*self.h-1 do self.pixels[i]=value end end
    function b:blitFrom(src,x,y,sx,sy,width,hh)
        assert(self.freed==0 and src.freed==0,'ripple uses a freed page')
        assert(x>=0 and y>=0 and x+width<=self.w and y+hh<=self.h,'ripple writes outside the screen')
        assert(sx>=0 and sy>=0 and sx+width<=src.w and sy+hh<=src.h,'ripple reads outside its target')
        for yy=0,hh-1 do for xx=0,width-1 do
            local at=(y+yy)*self.w+x+xx
            self.pixels[at]=src.pixels[(sy+yy)*src.w+sx+xx]
            self.writes[at]=(self.writes[at] or 0)+1
        end end
    end
    function b:free() self.freed=self.freed+1;assert(self.freed==1,'double free') end
    buffers[#buffers+1]=b;return b
end
Blitbuffer.new=raster
local target={paintTo=function(_,bb) bb:fill(42) end}
for _,effect in ipairs{'ripple','side_ripple','ripple_in','wave'} do
for _,size in ipairs{{120,160},{160,120},{119,157},{157,119},{5,7},{1,1}} do
    for _,direction in ipairs{'forward','backward'} do
        local w,height=size[1],size[2]
        local screen={bb=raster(w,height),alignment_constraint=8}
        screen.bb:fill(7)
        local frames,completed,submitted={},0,nil
        local function refresh(_,x,y,rw,rh)
            assert(x>=0 and y>=0 and rw>0 and rh>0 and x+rw<=w and y+rh<=height)
            assert(x%8==0 and y%8==0,'refresh origin must honor driver alignment')
            assert((x+rw)%8==0 or x+rw==w,'right edge must align or reach the screen edge')
            assert((y+rh)%8==0 or y+rh==height,'bottom edge must align or reach the screen edge')
            frames[#frames+1]={x=x,y=y,w=rw,h=rh}
        end
        screen.refreshUI=refresh;screen.refreshFast=refresh
        local native=false
        screen.setSwipeAnimations=function(_,enabled) native=enabled end
        screen.setSwipeDirection=function() end
        local animation=Animation:new{screen=screen,ui_manager=h.ui,device={canDoSwipeAnimation=function() return true end}}
        assert(animation:begin(target,direction,function(_,painted) completed=completed+1;submitted=painted end,
            {effect=effect,refresh_mode='fast',portrait_delay_ms=30,landscape_delay_ms=10}))
        eq(false,native,'ripple always uses software even on hardware-swipe devices')
        h:step()
        if w>10 and height>10 then
          if effect=='ripple' then
            eq(42,screen.bb.pixels[math.floor(height/2)*w+math.floor(w/2)],'first ripple reveals the center')
            eq(7,screen.bb.pixels[0],'first ripple preserves the old corner')
            eq(7,screen.bb.pixels[math.floor(height/2)*w],'first ripple preserves the old side')
            eq(true,frames[1].x>0 and frames[1].y>0,'circular reveal refreshes a center region, not a full-height wipe')
          elseif effect=='side_ripple' then
            eq(42,screen.bb.pixels[math.floor(height/3)*w+w-1],'side ripple starts at the right edge one third down in either direction')
            eq(7,screen.bb.pixels[math.floor(height/2)*w+math.floor(w/2)],'side ripple has not reached the screen center')
            eq(7,screen.bb.pixels[(height-1)*w],'side ripple initially preserves the distant corner')
          elseif effect=='ripple_in' then
            eq(7,screen.bb.pixels[math.floor(height/2)*w+math.floor(w/2)],'converging ripple keeps the center until later')
            eq(42,screen.bb.pixels[0],'converging ripple reveals the outside first')
            eq(42,screen.bb.pixels[w*height-1],'converging ripple begins at both far corners')
          else
            local leading=direction=='forward' and w-1 or 0
            eq(42,screen.bb.pixels[math.floor(height/2)*w+leading],'wave advances from the turn direction')
            eq(7,screen.bb.pixels[math.floor(height/2)*w+w-1-leading],'wave preserves the trailing edge initially')
            -- A curved front must not degenerate into the existing straight wipe.
            local function revealed(y)
                local count=0;for x=0,w-1 do if screen.bb.pixels[y*w+x]==42 then count=count+1 end end
                return count
            end
            eq(true,revealed(math.floor(height/4))~=revealed(math.floor(height*3/4)),'wave has a non-straight front')
          end
            eq(w>height and .01 or .03,h.tasks[1].delay,'ripple honors per-orientation frame timing')
        end
        h:drain()
        local all_target=true
        for i=0,w*height-1 do if screen.bb.pixels[i]~=42 then all_target=false;break end end
        eq(true,all_target,'ripple reaches every pixel including odd-size corners')
        local once=true;for _,count in pairs(screen.bb.writes) do if count~=1 then once=false end end
        eq(true,once,effect..' '..w..'x'..height..' '..direction..': each pixel is revealed once, including the final frame')
        eq(1,completed,'completion fires once')
        eq(true,submitted,'successful ripple tells the reader its final page is already painted')
        eq(true,#frames<=4*(w>height and 6 or 8),'geometry uses at most four bounded regions per frame')
        eq(false,animation:isRunning(),'ripple releases the running state')
        eq(0,#h.tasks,'completed ripple leaves no scheduled work')

        assert(animation:begin(target,direction,function() completed=completed+1 end,{effect=effect}))
        local stale=h.tasks[1].fn
        animation:cancel();local before=#frames;stale();h:drain()
        eq(before,#frames,'late cancelled ripple cannot repaint menus')
        eq(1,completed,'cancel does not call completion')
        assert(animation:begin(target,direction,function() completed=completed+1 end,{effect=effect}))
        h:step();assert(animation:settle());h:drain()
        eq(2,completed,'settling submits the whole target exactly once')
        screen.bb:free()
    end
end
end
for _,buffer in ipairs(buffers) do eq(1,buffer.freed,'every retained target is released once') end
Blitbuffer.new=original_new

-- An event-loop scheduling failure must not escape from a later frame.
local animation=Animation:new{screen=h.screen,ui_manager=h.ui,device=require('device')}
local completed=0
assert(animation:begin(target,'forward',function() completed=completed+1 end,{effect='ripple'}))
local schedule=h.ui.scheduleIn
h.ui.scheduleIn=function() error('scheduler unavailable') end
local stepped=pcall(h.step,h)
eq(true,stepped,'rescheduling failure stays inside the animation boundary')
eq(false,animation:isRunning(),'rescheduling failure frees the pending animation')
eq(1,completed,'rescheduling failure requests one normal repaint')
local started,why=animation:begin(target,'forward',nil,{effect='ripple'})
eq(nil,started,'initial scheduling failure refuses animation safely')
eq(true,type(why)=='string','initial scheduling failure has a diagnostic')
h.ui.scheduleIn=schedule
eq(0,#h.tasks,'failed scheduling leaves no late callbacks')

local old_bb=h.screen.bb
assert(animation:begin(target,'forward',function() completed=completed+1 end,{effect='ripple'}))
local refresh_count=#h.refreshes
h.screen.bb=h:buffer(800,600)
h:drain()
eq(refresh_count,#h.refreshes,'a changed framebuffer never receives an old-size target')
eq(false,animation:isRunning(),'rotation during a scheduled frame cancels the animation')
h.screen.bb:free();h.screen.bb=old_bb

local fast=h.screen.refreshFast
h.screen.refreshFast={}
assert(animation:begin(target,'backward',nil,{effect='ripple',refresh_mode='fast'}));h:drain()
eq('UI',h.refreshes[#h.refreshes].kind,'ripple falls back to UI when Fast is not callable')
h.screen.refreshFast=fast

local Reader=require('legado.ui.leko_reader')
local saved
local options={book={id='ripple',name='水波纹'},chapter={uid='c1',title='第一章'},
    body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',150)..'</p>',
    callbacks={style_changed=function(_,style) saved=style;return true end}}
local view=assert(Reader.new(options));h.ui:show(view);h:drain()
eq(12,view.style.margin_left,'new book starts with 12 left margin')
eq(12,view.style.margin_right,'new book starts with 12 right margin')
eq('side_ripple',view.style.page_transition,'side ripple is the default')
assert(view:applyStyle{page_transition='swipe'})
view:showLayoutMenu()
for _,row in ipairs(view.layout_dialog.buttons) do for _,button in ipairs(row) do
    if button.text=='动画效果：擦除渐显' then button.callback() end
end end
eq('ripple',view.style.page_transition,'visible animation control can select ripple')
eq('ripple',saved.page_transition,'selected ripple goes through the per-book save callback')
view:_closeDialog('layout_dialog');view:resumeReading();h:drain()
local before=h.dirty
assert(view:nextPage());h:drain()
eq(before,h.dirty,'successful ripple does not add a redundant final repaint')
local refresh=h.screen.refreshUI
h.screen.refreshUI=function() return false end
before=h.dirty;assert(view:nextPage());h:drain()
eq(true,h.dirty>before,'failed refresh requests a normal readable repaint')
eq(false,view.animation:isRunning(),'failed refresh releases the animation')
h.screen.refreshUI=refresh
for i=1,20 do assert(view:animateEntry(i%2==0 and 'forward' or 'backward',true));h:step() end
view:close();h:drain()
eq(0,#h.tasks,'rapid chapter/page changes and close leave no frames or background jobs')
options.style=saved;options.callbacks={}
local restored=assert(Reader.new(options))
eq('ripple',restored:getReaderSettings().page_transition,'restoring the next chapter retains ripple')
restored:close()
for _,effect in ipairs{'side_ripple','ripple_in','wave'} do
    options.style={page_transition=effect,margin_left=36,margin_right=36}
    local custom=assert(Reader.new(options))
    eq(effect,custom:getReaderSettings().page_transition,'new effects survive per-book restore')
    eq(36,custom.style.margin_left,'explicit per-book margins override new defaults')
    custom:showLayoutMenu()
    local selected=false
    for _,row in ipairs(custom.layout_dialog.buttons) do for _,button in ipairs(row) do
        if button.text:find('动画效果：',1,true)==1 then button.callback();selected=true end
    end end
    eq(true,selected,'every new effect can be changed through the visible control')
    custom:close();h:drain()
end
return n
