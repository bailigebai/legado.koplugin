local h=require('native_library_harness').install()
package.loaded['ffi/util']={}
package.loaded.device.hasKeyboard=function() return false end
package.loaded['ui/bidi'].rtlUIText=function() return false end
package.loaded['ui/bidi'].ltr=function(text) return text end
local NativeMenu=require('ui/widget/menu')
local Presenter=require('legado.ui.presenter')
local Downloads=require('legado.ui.downloads')
local A=require('assertions')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
-- Keep official Menu select / close ordering; replace geometry, unrelated to lifecycle.
local paints=0
local Menu=NativeMenu:extend{
    init=function(self) self.item_table_stack={} end,
    onCloseWidget=function() end,
    switchItemTable=function(self,title,items) self.title=title;self.item_table=items;paints=paints+1 end,
}
local jobs,returned,cancelled,removed={},0,0,0
h.ui.scheduleIn=function(_,delay,fn) jobs[#jobs+1]={fn=fn} end
h.ui.unschedule=function(_,fn) for _,job in ipairs(jobs) do if job.fn==fn then job.cancelled=true end end end
local task={id='active',kind='cache',book={name='下载中'},status='running',completed=0,total=1406}
local manager={list=function() return task and {task} or {} end,
    cancel=function() cancelled=cancelled+1;task.status='cancelled';return true end,
    remove=function() removed=removed+1;task=nil;return true end}
local view=Downloads.new{manager=manager,scheduler=h.ui}
view._back=function() returned=returned+1 end
local p=Presenter.new{menu=Menu,ui_manager=h.ui}
local list=p:show(view)
jobs[1].fn();eq(0,paints,'unchanged native menu is not repeatedly rebuilt')
task.completed=1;jobs[2].fn();eq(1,paints,'changed progress updates the current native menu')
list:onCloseAllMenus()
eq(false,view.alive,'official close icon disposes the download view immediately')
eq(1,returned,'official close icon returns once')
eq(0,cancelled,'exiting leaves the download running')
jobs[3].fn();eq(1,paints,'late polling cannot rebuild a dismissed menu')
list:onCloseAllMenus();eq(1,returned,'duplicate native close does not return twice')
view=Downloads.new{manager=manager,scheduler=h.ui};list=p:show(view)
list:onMenuSelect(list.item_table[1])
local popup=h.shown
eq('下载操作',popup.title,'native selection opens task actions')
eq(true,view.alive,'native selection close keeps the view for its action popup')
eq('取消并删除记录',popup.item_table[2].text,'running task offers cancellation and deletion')
popup:onMenuSelect(popup.item_table[2])
eq(1,removed,'native task action delegates record removal once')
eq('暂无下载记录',h.shown.item_table[1].text,'native callback close cannot reopen a stale task list')
return n
