require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local shown={}
package.loaded['datastorage']={getDataDir=function() return '/virtual/data' end}
package.loaded['ui/uimanager']={scheduleIn=function() end,show=function(_,widget) shown[#shown+1]=widget end,close=function() end}
package.loaded['ui/widget/infomessage']={new=function(_,options) return options end}
package.loaded['legado.lib.storage']={new=function() return {listShelf=function() return {} end,listSources=function() return {} end} end}
package.loaded['legado.lib.request_engine']={new=function(options) return {scheduler=options.scheduler,execute=function() return {cancel=function() end} end} end}
local app=require('legado.ui.bootstrap').build({ui={}}, {fs={ensureDirectory=function() return true end},
    settings_adapter={read=function() return {} end,write=function() return true end}})
local owner=app.reader_session.ui
local doc={}
for handler,method in pairs{on_toggle_reader='toggleImmersiveReader',on_book_info='openReaderBookInfo',on_add_to_shelf='addReaderToShelf',
    on_exit='exitReader',on_statistics='openNativeStatistics'} do
    local called
    app[method]=function(_,value) called=value;return true end
    eq('function',type(owner[handler]),'Bootstrap connects '..handler)
    eq(true,owner[handler](doc),'reader action forwards its result')
    eq(doc,called,'reader action forwards current proxy')
end
local pauses=0
app.reader_session.active={document={backend='immersive',widget={},pauseReading=function() pauses=pauses+1;return true end}}
app.reader_session.diagnostics('reader',{code='UNSUPPORTED_CONTENT',message='image'})
eq(true,shown[#shown].text:find('本章含图片',1,true)~=nil,'unsupported image chapters have an actionable diagnosis')
eq(true,shown[#shown].text:find('关闭无感阅读',1,true)~=nil,'image diagnosis explains how to select native mode')
app.reader_session.diagnostics('read',{code='READER_ERROR',message='字体加载失败。'})
eq('字体加载失败。',shown[#shown].text,'local independent reader error preserves its safe reason')
eq(2,pauses,'reader diagnostics participate in owned-overlay pause and close lifecycle')
return n
