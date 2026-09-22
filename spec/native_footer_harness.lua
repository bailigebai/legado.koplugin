-- Real ReaderFooter and layout widgets; only platform and unrelated dialogs are shimmed.
local Harness={}
function Harness.install(h)
    h=h or require('native_library_harness').install()
    local noop=function() end
    local no=function() return false end
    local device=package.loaded.device
    for _,name in ipairs{'hasBattery','hasAuxBattery','hasFastWifiStatusQuery','hasFrontlight','hasNaturalLight','isAndroid','isKobo','isCervantes'} do device[name]=no end
    G_defaults.readSetting=function(_,key,default)
        if key=='DMINIBAR_CONTAINER_HEIGHT' then return 14 end
        if key=='DTAP_ZONE_MINIBAR' then return {x=0,y=.95,w=1,h=.05} end
        return default or 24
    end
    package.loaded.gettext=setmetatable({pgettext=function(_,text) return text end},{__call=function(_,text) return text end})
    package.loaded['ffi/util']={template=function(text,...) local args={...};return (text:gsub('%%(%d)',function(i) return tostring(args[tonumber(i)]) end)) end}
    for _,name in ipairs{'ui/widget/booklist','ui/widget/multiinputdialog','ui/widget/spinwidget','ui/presets','datetime'} do package.loaded[name]={} end
    package.loaded['ui/widget/fontchooser']={isFontRegistered=function() return true end}
    h.ui.unschedule=noop
    h.ui.scheduleIn=noop
    package.loaded['ui/bidi'].wrap=function(text) return text end
    local Text=require('ui/widget/textwidget')
    local paint=Text.paintTo
    h.painted=setmetatable({},{__mode='k'})
    Text.paintTo=function(self,bb,x,y)
        h.painted[self]={x=x,y=y,w=self:getSize().w,h=self:getSize().h}
        return paint(self,bb,x,y)
    end
    h.footer_class=require('apps/reader/modules/readerfooter')
    function h:newReader()
        local reader={name='ReaderUI',doc_props={display_title='阳神'},
            view={view_modules={},registerViewModule=function(self,name,module) self.view_modules[name]=module end},
            document={provider='crengine',info={has_pages=true},configurable={b_page_margin=8},
                getPageCount=function() return 13 end,hasHiddenFlows=no,getTotalPagesLeft=function() return 4 end},
            getCurrentPage=function() return 9 end,
            toc={getChapterPagesDone=function() return 8 end,getChapterPageCount=function() return 13 end,
                getChapterPagesLeft=function() return 4 end,getTocTitleByPage=function() return '第一章 天意民意' end},
            statistics={getTimeForPages=function(_,pages) assert(pages==4);return '约 13 分钟' end},
            menu={registerToMainMenu=noop},registerTouchZones=noop,events={},
            handleEvent=function(self,event) self.events[#self.events+1]=event.handler end,
            typeset={unscaled_margins={10,8,10,8},onSetPageMargins=function(self,margins) self.applied=margins end}}
        reader.view.dialog=reader
        local footer=h.footer_class:new{ui=reader,view=reader.view}
        reader.view.footer=footer
        footer.pageno,footer.pages,footer.percent_finished=9,13,9/13
        -- The native ready handler supplies geometry and enables text updates.
        footer.settings={};for key,value in pairs(h.footer_class.default_settings) do footer.settings[key]=value end
        footer.settings.toc_markers=false
        footer:onReaderReady()
        footer:onUpdateFooter()
        return reader,footer
    end
    h.buffer=setmetatable({},{__index=function(_,name)
        if name=='getWidth' then return function() return h.dimensions.w end end
        if name=='getHeight' then return function() return h.dimensions.h end end
        return noop
    end})
    return h
end
return Harness
