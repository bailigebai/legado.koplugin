-- Platform shims for exercising unmodified KOReader widgets on desktop LuaJIT.
local Harness = {}

function Harness.install(source)
    source = source or os.getenv("LEGADO_KOREADER_SOURCE") or ".tools/koreader"
    package.path = package.path .. ";" .. source .. "/frontend/?.lua;" .. source .. "/common/?.lua"
    local function noop() end
    local function no() return false end
    local function yes() return true end
    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}; for key,item in pairs(value) do result[key]=copy(item) end; return result
    end
    local function chars(text)
        local result={}; for byte in tostring(text):gmatch(".") do result[#result+1]=byte end; return result
    end
    table.pack = table.pack or function(...) return {n=select("#",...),...} end
    G_defaults = {readSetting=function(_,_,default) return default or 24 end}
    G_reader_settings = {nilOrTrue=no,isTrue=no,readSetting=function(_,_,default) return default end}
    local dimensions={w=600,h=800}
    local screen={getWidth=function() return dimensions.w end,getHeight=function() return dimensions.h end,
        scaleBySize=function(_,n) return n end,scaleByDPI=function(_,n) return n end,isColorEnabled=no}
    local back_group={"Back"}
    package.loaded.device={screen=screen,hasDPad=no,hasFewKeys=no,hasKeys=yes,isTouchDevice=yes,input={group={Back=back_group}}}
    package.loaded["ui/bidi"]={mirroredUILayout=no}
    package.loaded.logger={dbg=noop,warn=noop,err=noop,info=noop}
    package.loaded.dbg=setmetatable({guard=noop},{__call=noop})
    package.loaded.gettext=function(text) return text end
    package.loaded.optmath={round=function(n) return math.floor(n+.5) end}
    package.loaded.depgraph={}
    package.loaded["ui/time"]={s=function(n) return n end,ms=function(n) return n/1000 end}
    package.loaded["ffi/utf8proc"]={lowercase=function(text) return text end}
    package.loaded.util={tableDeepCopy=copy,getDefaultArg=function(v,d) if v==nil then return d end return v end,
        splitToChars=chars,isSplittable=yes,utf8Reverse=function(text) return text:reverse() end}
    local function buffer(width,height)
        return {getWidth=function() return width end,getHeight=function() return height end,getType=function() return 1 end,
            fill=noop,free=noop,blitFrom=noop,paintRectRGB32=noop,darkenRect=noop}
    end
    package.loaded["ffi/blitbuffer"]={COLOR_BLACK=0,COLOR_WHITE=255,COLOR_LIGHT_GRAY=204,COLOR_DARK_GRAY=85,TYPE_BB8=1,TYPE_BBRGB32=4,
        isColor8=yes,new=function(width,height) return buffer(width,height) end}
    package.loaded["ui/font"]={getFace=function(_,_,size) size=size or 20; return {size=size,orig_size=size,
        ftsize={getHeightAndAscender=function() return size,math.floor(size*.75) end}} end,
        getAdjustedFace=function(_,face,bold) return face,bold end}
    package.loaded["ui/rendertext"]={sizeUtf8Text=function(_,_,_,face,text) return {x=#tostring(text)*face.size/3} end,
        truncateTextByWidth=function(_,text,face,width) return text:sub(1,math.max(1,math.floor(width*3/face.size))) end,
        getSubTextByWidth=function(_,text,face,width) return text:sub(1,math.max(1,math.floor(width*3/face.size))) end,
        getEllipsisWidth=function(_,face) return face.size/3 end,renderUtf8Text=noop}
    package.loaded["ui/widget/iconwidget"]={}
    local state={closed={},dirty=0,sent=0,dimensions=dimensions,screen=screen,back_group=back_group}
    state.ui={close=function(_,widget) state.closed[#state.closed+1]=widget;if widget.onCloseWidget then widget:onCloseWidget() end end,
        setDirty=function() state.dirty=state.dirty+1 end,sendEvent=function() state.sent=state.sent+1 end,
        show=function(_,widget) state.shown=widget;if widget.getSize then widget:getSize() end end}
    package.loaded["ui/uimanager"]=state.ui
    local Widget=require("ui/widget/widget")
    package.loaded["ui/widget/imagewidget"]=Widget:extend{
        getSize=function(self) if self.file=="bad.jpg" then error("lazy decode") end return {w=self.width,h=self.height} end}
    return state
end

return Harness
