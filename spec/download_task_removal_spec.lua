local A=require('assertions')
local Storage=require('legado.lib.storage')
local Manager=require('legado.lib.download_manager')
local Downloads=require('legado.ui.downloads')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local function ok(value,why) n=n+1;A.truthy(value,why) end
local files,fail={},false
local fs={read=function(_,path) return files[path] end,atomicWrite=function(_,path,data)
    if fail then return nil,{code='STORAGE_ERROR'} end;files[path]=data;return true end}
local function open() return assert(Storage.new{fs=fs,path='tasks.lua',sqlite_loader=function() return nil end}) end
local storage=open()
eq('function',type(storage.deleteDownloadTask),'storage supports durable task deletion')
local source=assert(storage:createSource{bookSourceUrl='https://example.test',bookSourceName='测试源'})
local book={id='delete-book',source_id=require('legado.lib.models').sourceId(source),name='下载记录'}
local chapters={{uid='c1',index=1,book_id=book.id,source_id=source.id,title='第1章'}}
local pending,cancelled,catalog,bodies={},0,nil,{}
local cache={readBody=function(_,s,b,c) return bodies[c.uid] end,
    writeBody=function(_,s,b,c,text) bodies[c.uid]=text;return true end,
    readCatalog=function() return catalog end,writeCatalog=function(_,s,b,value) catalog=value;return true end}
local service={getChapters=function(_,s,b,cb) cb(chapters,nil,{catalog_complete=true});return {cancel=function() end} end,
    getContent=function(_,s,b,c,cb) pending[#pending+1]=cb;return {cancel=function() cancelled=cancelled+1 end} end}
local function manager(store) return Manager.new{storage=store or storage,cache=cache,offline_cache=cache,
    book_service=service,builder={write=function() return 'export.epub' end},standby={acquire=function() end,release=function() end}} end
local m=manager()
local task=assert(m:enqueueCache(book))
local late=pending[1]
eq('function',type(m.remove),'manager supports cancel and remove')
ok(m:remove(task.id),'running task may be cancelled and removed')
eq(1,cancelled,'removal cancels its outstanding request')
eq(nil,m:get(task.id),'removed task disappears in memory')
eq(nil,open():getDownloadTask(task.id),'removed task stays absent after storage reopen')
late({content='late body'})
eq(nil,bodies.c1,'late removed callback cannot write cache')
task=assert(m:enqueueCache(book));pending[#pending]({content='正文'})
eq(true,m:isCached(book),'whole cache is marked before deleting record')
ok(m:remove(task.id),'completed record can be removed')
eq('<p>正文</p>',bodies.c1,'removal preserves downloaded chapters')
eq(true,m:isCached(book),'download badge survives deleting its history')
eq(true,manager(open()):isCached(book),'download badge survives restart without history')
task=assert(m:enqueueCache(book));eq('completed',m:get(task.id).status,'cache reuses existing body')
fail=true
local removed,err=m:remove(task.id)
eq(nil,removed,'failed deletion is not reported as success')
eq('STORAGE_ERROR',err.code,'delete failure retains actual error')
ok(m:get(task.id),'failed deletion retains visible task')
fail=false
local view=Downloads.new{manager=m}
eq('function',type(view.remove),'view delegates record removal')
ok(view:remove(task.id),'view removes completed record')
eq(0,#view.items,'removed record is no longer listed')
view:close();eq(false,view:remove(task.id),'closed view ignores stale deletion')
-- A shorter cache job must not downgrade a previously complete catalog.
local second={uid='c2',index=2,book_id=book.id,source_id=book.source_id,title='第2章'}
chapters[2]=second
task=assert(m:enqueueCache(book));pending[#pending]({content='第二章'})
eq(true,m:isCached(book),'full two-chapter cache is complete')
task=assert(m:enqueueCache(book,nil,1))
eq(true,m:isCached(book),'shorter task preserves an already complete catalog')
return n
