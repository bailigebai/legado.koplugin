require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local tasks,delay,dirty,closed,cancelled,returned={},nil,0,0,0,0
local progress,complete
local ui={show=function() end,close=function() closed=closed+1 end,setDirty=function() dirty=dirty+1 end,
    scheduleIn=function(_,seconds,action) delay=seconds;tasks[action]=true end,unschedule=function(_,action) tasks[action]=nil end}
local app={storage={listShelf=function() return {{id='a'}} end},service={checkUpdates=function(_,_,done,tick)
    complete,progress=done,tick;return {cancel=function() cancelled=cancelled+1 end}
end}}
local p=require('legado.ui.presenter').new{app=app,ui_manager=ui}
p._shelf=function() returned=returned+1 end
local menu=p:_checkUpdates({kind='bookshelf'})
for i=1,100 do progress({total=100,checked=i,updated=1,failed=0}) end
eq(6,delay,'update status uses a six-second refresh interval')
eq(0,dirty,'per-source results do not repaint immediately')
local count=0;for action in pairs(tasks) do count=count+1;tasks[action]=nil;action() end
eq(1,count,'many updates coalesce into one render')
eq(1,dirty,'one scheduled status repaint')
complete({total=100,checked=100,updated=1,failed=0})
eq('检查更新完成',menu.title,'completion is visible')
menu.close_callback()
eq(1,closed,'return closes the complete progress menu')
eq(1,cancelled,'return cancels outstanding update work')
eq(1,returned,'return remains in the plugin bookshelf')
progress({total=100,checked=100,updated=1,failed=0})
eq(2,dirty,'late callback never resurrects closed menu')
return n
