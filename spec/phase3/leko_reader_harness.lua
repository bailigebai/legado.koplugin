local Harness = {}
function Harness.install()
    package.path = 'spec/phase3/?.lua;' .. package.path
    local h = require('native_library_harness').install()
    local util = require('util')
    require('ui/bidi').rtlUIText=function() return false end
    for _,name in ipairs{'ltr','rtl','flipDirectionIfMirroredUILayout'} do require('ui/bidi')[name]=function(value) return value end end
    package.loaded['ffi/util']={orderedPairs=pairs,template=function(value,...) local args={...};return (value:gsub('%%(%d)',function(i) return tostring(args[tonumber(i)]) end)) end}
    function util.splitToChars(value)
        local out = {}; for ch in tostring(value):gmatch('[%z\1-\127\194-\244][\128-\191]*') do out[#out+1]=ch end
        return out
    end
    local function width(text, face) return #util.splitToChars(text) * face.size end
    local render = require('ui/rendertext')
    render.sizeUtf8Text=function(_,_,_,face,text) return {x=width(text,face)} end
    render.getSubTextByWidth=function(_,text,face,w)
        local chars=util.splitToChars(text);return table.concat(chars,'',1,math.min(#chars,math.max(1,math.floor(w/face.size))))
    end
    render.truncateTextByWidth=render.getSubTextByWidth
    h.tasks,h.refreshes,h.buffers={}, {}, {}
    function h.ui:scheduleIn(delay,fn) h.tasks[#h.tasks+1]={delay=delay,fn=fn} end
    function h.ui:nextTick(fn) self:scheduleIn(0,fn) end
    function h.ui:unschedule(fn) for i=#h.tasks,1,-1 do if h.tasks[i].fn==fn then table.remove(h.tasks,i) end end end
    function h:step()
        for i,task in ipairs(self.tasks) do
            if task.delay<60 then table.remove(self.tasks,i);task.fn();return true end
        end
        return false
    end
    function h:drain(limit) for _=1,limit or 10000 do if not self:step() then return end end;error('scheduler did not settle') end
    function h:buffer(w,hh)
        local b={w=w,h=hh,pixels={},freed=0}
        function b:getWidth() return self.w end
        function b:getHeight() return self.h end
        function b:getType() return 1 end
        function b:getRotation() return 0 end
        function b:setRotation() end
        function b:fill(value) for x=0,self.w-1 do self.pixels[x]=value end end
        function b:paintRect(x,y,rw,rh,value) for xx=math.max(0,x),math.min(self.w-1,x+rw-1) do self.pixels[xx]=value end end
        b.fillRect=b.paintRect
        function b:blitFrom(src,dx,dy,sx,sy,rw,rh)
            assert(self.freed==0 and src.freed==0,'use after free')
            for x=0,rw-1 do self.pixels[dx+x]=src.pixels[sx+x] end
        end
        function b:colorblitFrom(src,dx,dy,sx,sy,rw,rh,color)
            assert(self.freed==0 and src.freed==0,'mask use after free')
            self.masks=(self.masks or 0)+1
            for x=0,rw-1 do if src.pixels[sx+x]~=0 then self.pixels[dx+x]=color end end
        end
        function b:free() self.freed=self.freed+1;assert(self.freed==1,'double free') end
        b:fill(255);self.buffers[#self.buffers+1]=b;return b
    end
    require('ffi/blitbuffer').new=function(w,hh) return h:buffer(w,hh) end
    h.screen.bb=h:buffer(h.dimensions.w,h.dimensions.h)
    for _,kind in ipairs{'UI','Fast','Partial','Full','NoMergeUI'} do
        h.screen['refresh'..kind]=function(_,x,y,w,hh) h.refreshes[#h.refreshes+1]={kind=kind,x=x,y=y,w=w,h=hh} end
    end
    h.screen.setSwipeAnimations=function(_,value) h.swipe=value end
    h.screen.setSwipeDirection=function(_,value) h.direction=value end
    require('device').canDoSwipeAnimation=function() return false end
    require('device').hasFrontlight=function() return false end
    require('device').hasKeyboard=function() return false end
    require('device').hasScreenKB=function() return false end
    h.screen.getSize=function() return require('ui/geometry'):new{w=h.dimensions.w,h=h.dimensions.h} end
    require('device').isKobo=function() return false end
    require('device').hasColorScreen=function() return false end
    h.ui.getTopmostVisibleWidget=function() return h.shown end
    package.preload['apps/reader/readerui']=function() error('independent reader attempted ReaderUI') end
    package.loaded['apps/reader/readerui']=nil
    return h
end
return Harness
