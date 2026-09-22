local A = require('assertions')
local count = 0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local Settings = require('legado.lib.settings')
local saved = {}
local settings = Settings.new({read=function() return saved end,write=function(v) saved=v;return true end})
eq('local', settings:set('shelf_source','local'), 'local shelf setting stays a string')
eq('mixed', settings:set('shelf_source','mixed'), 'mixed shelf setting stays a string')
eq(false,settings:set('progress_bar',false),'footer preference can be disabled')
eq(false,Settings.new({read=function() return saved end}):get('progress_bar'),'footer preference survives reload')

local Adapter = require('legado.lib.koreader_reader_ui')
local queue, log = {}, {}
package.loaded['ui/uimanager']={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}
local reader={onClose=function() log[#log+1]='close' end,handleEvent=function() end,
    onHome=function() error('must not route to Moon') end,
    toc={onShowToc=function() error('generated file has only a single chapter') end},
    menu={registered_widgets={},onTapCloseMenu=function() log[#log+1]='menu' end,
        registerToMainMenu=function(self,w) self.registered_widgets[#self.registered_widgets+1]=w end,
        setUpdateItemTable=function(self) self.tab_item_table={{icon='native'}} end,
        _getTabIndexFromLocation=function() return 9 end}}
local adapter=Adapter.new({ReaderUI={showReader=function(_,_,_,_,_,ready) ready(reader) end},
    on_exit=function() log[#log+1]='shelf' end,on_toc=function() log[#log+1]='toc' end,
    on_settings=function() log[#log+1]='settings' end})
local doc=assert(adapter:openDocument('chapter.html',{end_of_book=function() end}))
reader.menu:setUpdateItemTable()
eq(true,reader.menu.tab_item_table[1].legado_reader,'first native tab is the plugin toolbar')
eq('目录',reader.menu.tab_item_table[1][1].text,'toolbar starts with catalog')
eq(1,reader.menu:_getTabIndexFromLocation({pos={x=599}}),'top-right opens plugin toolbar')
reader.toc:onShowToc()
eq('toc',log[#log],'native TOC delegates to web catalog without closing reader')
reader:onHome()
eq('menu',log[#log],'home closes menus before scheduling reader exit')
queue[#queue]()
eq('shelf',log[#log],'home returns to Legado after reader teardown')
eq('close',log[#log-1],'reader closes before showing shelf')

local original_footer={disable_progress_bar=false}
reader.footer={settings=original_footer,refreshFooter=function() end}
adapter:applyProgressBar(reader,false)
eq(true,reader.footer.settings.disable_progress_bar,'toggle controls the actual native progress bar')
eq(false,original_footer.disable_progress_bar,'plugin does not mutate shared global footer settings')

require('library_screen_stub')
local shown,cancelled={},0
queue={}
local ui={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end,show=function(_,w) shown[#shown+1]=w end,close=function() end}
local Presenter=require('legado.ui.presenter')
local presenter=Presenter.new{ui_manager=ui}
local finish,update
presenter:_startReading(function(done,progress)
    finish,update=done,progress
    return {cancel=function() cancelled=cancelled+1 end}
end)
update(2,'正在准备第一章')
eq('正在准备章节',shown[#shown].title,'pending read displays preparation screen')
eq(.25,shown[#shown].progress,'progress reflects completed preparation stages')
shown[#shown].actions[1].callback()
eq(1,cancelled,'cancel stops the active fetch')
local before=#shown
finish({},nil)
eq(before,#shown,'late reader completion after cancel does not reopen UI')
presenter:_startReading(function(done) done({});return {} end)
eq(before,#shown,'cached synchronous success skips a transient loading screen')
eq(nil,presenter.library_view,'cached synchronous success leaves no transient preparation view')

-- Returning from settings reopens a freshly scanned shelf; reading settings stay over the reader.
local App=require('legado.ui.app')
local app=App.new{settings=settings,storage={},show=function(view) presenter:show(view) end}
local shelf_calls,shelf_mode=0,nil
function app:openBookshelf(mode) shelf_calls=shelf_calls+1;shelf_mode=mode end
local settings_view=app:openSettings()
settings_view.local_directories_changed=true
shown[#shown].close_callback()
eq(1,shelf_calls,'closing shelf settings returns to plugin rather than file manager')
eq('local',shelf_mode,'added directories return to a fresh local shelf')
app:openSettings({reader={}})
shown[#shown].close_callback()
eq(1,shelf_calls,'closing reading settings leaves the active reader visible')
return count
