local A = require('assertions')
local count = 0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local h = require('native_library_harness').install()
local scheduled, cancelled = {}, {}
h.ui.scheduleIn = function(_,delay,fn) scheduled[fn]=delay end
h.ui.unschedule = function(_,fn) cancelled[fn]=true; scheduled[fn]=nil end
local Settings = require('legado.lib.settings')
local settings = Settings.new({read=function() return {} end,write=function() return true end})
local page, total, margins = 7, 15, nil
local reader = {doc_props={display_title='Local book'},document={
    getPageCount=function() return total end,
},getCurrentPage=function() return page end,
    rolling={getLastPercent=function() return page/total end},
    typeset={unscaled_margins={10,5,10,8},onSetPageMargins=function(_,values) margins=values end},
    view={view_modules={},footer_visible=true,footer={getHeight=function() return 20 end}},
}
reader.view.registerViewModule=function(self,name,module) self.view_modules[name]=module; module.ui=reader end
h.ui.getTopmostVisibleWidget=function() return reader end
local chapters={}; for i=1,100 do chapters[i]={title='第 '..i..' 章'} end
local proxy={reading_state={book={name='测试小说：真正的书名'},chapters=chapters,index=20,catalog_complete=true},
    getProgressFraction=function() return .5 end}
local Chrome=require('legado.lib.reader_chrome')
local chrome=assert(Chrome.new(reader,settings,proxy)):start()
eq(chrome,reader.view.view_modules.legado_chrome,'chrome draws within reader, without a separate window')
eq(nil,h.shown,'chrome never covers menus with a UIManager window')
eq(23,margins[2],'small header reserves readable space above body')
eq(27,margins[4],'small footer reserves its band and gap above native footer')
eq(5,reader.typeset.unscaled_margins[2],'temporary header margin does not overwrite book settings')
local bb={paintRect=function() end}
chrome:paintTo(bb,0,0)
eq('测试小说：真正的书名',chrome.labels.tc.text,'web reader uses novel title instead of chapter HTML title')
eq('7/15',chrome.labels.tr.text,'web chapter page is current document page')
eq('第 20 章',chrome.labels.bl.text,'chapter label uses the online catalog')
eq('约 19.5%',chrome.labels.br.text,'novel progress combines chapter index with chapter fraction')
page=1;chrome:paintTo(bb,0,0)
eq(os.date('%H:%M'),chrome.labels.tl.text,'time remains visible on chapter first page')
settings:set('reader_header_font_size',9);settings:set('reader_footer_font_size',14)
chrome:refresh();chrome:paintTo(bb,0,0)
eq(9,chrome.labels.tc.face.size,'header size changes immediately')
eq(14,chrome.labels.bl.face.size,'footer has independent size')
settings:set('reader_header_font_size',11);settings:set('reader_footer_font_size',11)
chrome:refresh();page=7
local dirty=h.dirty
chrome:paintTo(bb,0,0)
eq(dirty,h.dirty,'painting does not schedule an endless repaint')
for key,label in pairs(chrome.labels) do
    local size=label:getSize()
    eq(true,label.dimen.x>=0 and label.dimen.x+size.w<=600,'label '..key..' stays on screen')
    eq(true,label.dimen.y>=0 and label.dimen.y+size.h<=800,'label '..key..' stays vertically on screen')
end
eq(true,chrome.labels.tc.dimen.x>=chrome.labels.tl.dimen.x+chrome.labels.tl:getSize().w,'title does not overlap clock')
eq(true,chrome.labels.tc.dimen.x+chrome.labels.tc:getSize().w<=chrome.labels.tr.dimen.x,'title does not overlap page number')
proxy.reading_state.catalog_complete=false
chrome:paintTo(bb,0,0)
eq('目录加载中',chrome.labels.br.text,'partial catalog never pretends to be whole-book percentage')
proxy.reading_state=nil
reader.toc={getTocTitleByPage=function() return 'Local chapter' end,
    getChapterPageCount=function() return 10 end,getChapterPagesDone=function() return 4 end}
chrome:paintTo(bb,0,0)
eq('5/10',chrome.labels.tr.text,'local books derive chapter page from native TOC')
eq('Local book',chrome.labels.tc.text,'local book title comes from native document metadata')
settings:set('reader_corner_tl','chapter')
settings:set('reader_corner_br','off')
chrome:refresh()
chrome:paintTo(bb,0,0)
eq('Local chapter',chrome.labels.tl.text,'any corner can change its content immediately')
eq('',chrome.labels.br.text,'a disabled corner is blank')
h.dimensions.w,h.dimensions.h=800,600
chrome:paintTo(bb,0,0)
eq(true,chrome.labels.tr.dimen.x+chrome.labels.tr:getSize().w<=800,'rotation recalculates corner positions')
eq(true,chrome.labels.bl.dimen.y<580,'footer stays above native status bar after rotation')
eq(60,scheduled[chrome.tick],'clock updates at most once per minute')
local regions={}
h.ui.setDirty=function(_,_,_,region) regions[#regions+1]=region end
settings:set('reader_corner_tl','time')
chrome.tick()
eq(23,regions[1].h,'clock refresh is limited to the header band')
h.ui.getTopmostVisibleWidget=function() return {} end
chrome.tick()
eq(1,#regions,'clock does not repaint through menus or sleep screen')
for _,key in ipairs({'tl','tc','tr','bl','br'}) do settings:set('reader_corner_'..key,'off') end
chrome:refresh()
eq(5,margins[2],'disabling the header restores the original top margin')
eq(8,margins[4],'disabling the footer restores the original bottom margin')
chrome:close()
eq(nil,reader.view.view_modules.legado_chrome,'closing reader unregisters chrome')
eq(true,cancelled[chrome.tick],'closing reader cancels its timer')
eq(false,chrome:close(),'duplicate close is harmless')

-- Native Font scales its size argument itself; the chrome must not scale it twice.
package.loaded.fontlist={fontdir='/fonts',getFontList=function() return {} end}
package.loaded.util.splitFilePathName=function(path) return '',path end
package.loaded['ffi/freetype']={newFaceSize=function(_,size)
    return {getHeightAndAscender=function() return size,math.floor(size*.8) end}
end}
package.loaded['ui/font']=nil
G_reader_settings.has=function() return false end
local native_font=require('ui/font')
h.dimensions.w,h.dimensions.h=1200,1600
h.screen.scaleBySize=function(_,n) return n*2 end
local high_settings=Settings.new{read=function() return {} end,write=function() return true end}
local high=assert(Chrome.new(reader,high_settings,proxy)):start()
high:paintTo(bb,0,0)
eq(22,high.labels.tc.face.size,'native font scales 11 exactly once on a 1200px screen')
eq(true,high.labels.tc:getSize().h<52,'font has padding within the scaled header band')
high:close()
h.screen.scaleBySize=function(_,n) return n end
h.dimensions.w,h.dimensions.h=600,800

-- Exercise settings persistence, all menu choices, error handling and return to the reader.
local persisted,fail={},false
local adapter={read=function() return persisted end,write=function(values) if fail then return false end; persisted=values; return true end}
local stored=Settings.new(adapter)
local App=require('legado.ui.app')
local refreshed=0
local doc={chrome={refresh=function() refreshed=refreshed+1 end}}
local app=App.new{settings=stored}
local view=app:openSettings(doc,true)
local Presenter=require('legado.ui.presenter')
local menu={new=function(_,options) return options end}
local presenter=Presenter.new{ui_manager=h.ui,menu=menu,info_message=menu}
presenter:_settings(view)
local expected={'time','title','chapter_page','chapter','progress','off'}
for i,key in ipairs({'tl','tc','tr','bl','br'}) do
    for j,value in ipairs(expected) do
        presenter.settings_widget.item_table[i].sub_item_table[j].callback()
        eq(value,stored:get('reader_corner_'..key),'menu selection saves '..key..' as '..value)
    end
end
eq(30,refreshed,'successful choices update the current reader immediately')
eq('off',Settings.new(adapter):get('reader_corner_br'),'corner preference survives reopening settings')
fail=true
local last=presenter.settings_widget
last.item_table[1].sub_item_table[1].callback()
eq('off',stored:get('reader_corner_tl'),'failed settings write preserves previous value')
eq(30,refreshed,'failed write leaves reader layout unchanged')
last.close_callback()
eq(last,h.closed[#h.closed],'settings return closes the whole menu')
return count
