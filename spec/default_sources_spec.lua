require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Json=require('legado.lib.json_codec')
local Storage=require('legado.lib.storage')
local Importer=require('legado.lib.source_importer')
local Manager=require('legado.ui.source_manager')
local bytes,local_source,reads,requests=nil,nil,0,{}
local function source(name,url)return {bookSourceName=name,bookSourceUrl=url,exploreUrl='分类::/list'}end
local fs={read=function()return bytes end,atomicWrite=function(_,_,text)bytes=text;return true end,
    readBounded=function(_,path)reads=reads+1;eq('my-sources.json',path,'local import only reads the chosen file');return local_source end}
local storage=assert(Storage.new{sqlite_loader=function()end,fs=fs})
local manager=Manager.new{storage=storage,fs=fs,importer=Importer:new{storage=storage},
    request_engine={execute=function(_,request,callback)
        requests[#requests+1]=request.url
        callback({body=Json.encode(source('网址导入','https://web.test')),final_url=request.url})
        return {cancel=function()end}
    end}}
local app=require('legado.ui.app').new{storage=storage,book_service={},source_manager=manager}
eq(0,#storage:listSources(),'fresh source store starts empty')
eq(0,#app:openSearch():sourceChoices(),'search has no supplied sites before manual import')
eq('请先导入书源',app:openDiscovery().empty_text,'empty discovery retains the import guidance')
eq(0,reads,'opening manager/search/discovery does not read a bundled file')
eq(0,#requests,'startup never downloads a supplied collection')
eq(nil,manager.installDefaults,'automatic/default restore entry is absent')
eq(nil,Manager.DEFAULT_SOURCE_URL,'there is no built-in collection address')
manager:importUrl('https://user.test/list.json',function(report,err)
    eq(nil,err,'manual URL import still works');eq(1,report.imported,'manual URL imports a site')
end)
eq('https://user.test/list.json',requests[1],'only the entered URL is fetched')
local_source=Json.encode(source('本地导入','https://local.test'))
eq(1,manager:importLocal('my-sources.json').imported,'manual local JSON import works')
eq(2,#manager:list(),'manually imported sites remain manageable')
eq(2,#app:openDiscovery().sources,'manually imported sites retain discovery')
eq(2,#app:openSearch():sourceChoices(),'manually imported sites retain aggregated search')
local p=require('legado.ui.presenter').new{ui_manager={show=function()end,close=function()end}}
local menu
p._library=function(_,_,opts)menu=opts;return opts end
p:_sources(manager)
eq(2,#menu.actions,'source management only offers local and URL imports')
eq('从本地 JSON 导入',menu.actions[1].text,'local import action remains')
eq('从网址导入',menu.actions[2].text,'URL import action remains')
-- Existing data is never reset: sources, book progress and settings remain user-owned.
assert(storage:putProgress{book_id='saved-book',chapter_index=7,fraction=.4})
assert(storage:updateSource('https://local.test',{enabled=false,hidden_default=true}))
local reopened=assert(Storage.new{sqlite_loader=function()end,fs=fs})
local restored=Manager.new{storage=reopened}
eq(2,#restored:list(),'all saved sites remain manageable, including old hidden records')
eq(false,reopened:getSource('https://local.test').enabled,'disabled source preference survives')
eq(7,reopened:getProgress('saved-book').chapter_index,'reading progress survives reopening')
eq(nil,reopened:getSource('https://missing.test'),'no missing site is silently restored')
return n
