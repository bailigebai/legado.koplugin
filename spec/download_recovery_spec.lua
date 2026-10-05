local A=require('assertions')
local Manager=require('legado.lib.download_manager')
local App=require('legado.ui.app')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local function fixture()
    local source={bookSourceUrl='https://example.test'}
    local book={id='recovery',source_id=require('legado.lib.models').sourceId(source),name='失败后阅读'}
    local chapters={{uid='one',index=1,book_id=book.id,source_id=book.source_id},
        {uid='two',index=2,book_id=book.id,source_id=book.source_id}}
    local records,pending,bodies={}, {}, {}
    local storage={listSources=function() return {source} end,listChapters=function() return chapters end,
        replaceChapters=function() return true end, getProgress=function() return nil end,
        listDownloadTasks=function() local out={};for _,v in pairs(records) do out[#out+1]=v end;return out end,
        putDownloadTask=function(_,v) records[v.id]=v;return v end,
        deleteDownloadTask=function(_,id) records[id]=nil;return true end}
    local function cache()
        local catalog
        return {readCatalog=function() return catalog end,writeCatalog=function(_,s,b,v) catalog=v;return true end,
            readBody=function(_,s,b,c) return bodies[c.uid] end,
            writeBody=function(_,s,b,c,v) bodies[c.uid]=v;return true end}
    end
    local online,offline=cache(),cache()
    local catalogs=0
    local service={getChapters=function(_,s,b,cb) catalogs=catalogs+1;cb(chapters,nil,{catalog_complete=true}) end,
        getContent=function(_,s,b,c,cb) pending[#pending+1]=cb;return {cancel=function() end} end}
    local options={storage=storage,cache=online,offline_cache=offline,book_service=service,builder={},
        standby={acquire=function() end,release=function() end}}
    return {book=book,chapters=chapters,records=records,bodies=bodies,pending=pending,online=online,
        offline=offline,storage=storage,service=service,options=options,catalogs=function() return catalogs end}
end
do
    local f=fixture();local m=Manager.new(f.options)
    local task=assert(m:enqueueCache(f.book))
    f.pending[1](nil,{code='NETWORK_ERROR'})
    eq('failed',m:get(task.id).status,'chapter error settles the download')
    eq(true,f.online:readCatalog().complete,'failed body download retains the complete catalog')
    local resumed,options
    local app=App.new{storage=f.storage,book_service=f.service,
        reader_session={cache=f.online,offline_cache=f.offline,
            resume=function(_,s,b,chapters,cb,o) resumed,options=chapters,o;return {} end}}
    app:startReading(f.book)
    eq(1,f.catalogs(),'reading after failure does not refetch the already complete catalog')
    eq(2,#(resumed or {}),'reading uses the saved catalog')
    eq(true,options and options.catalog_complete,'reader can advance beyond the cached chapter')
end
do
    local f=fixture();f.chapters[2]=nil
    f.offline.writeCatalog=function() error('disk failure') end
    local m=Manager.new(f.options);local task=assert(m:enqueueCache(f.book))
    f.pending[1]({content='正文'})
    local result=m:get(task.id)
    eq('failed',result.status,'thrown final catalog save fails safely')
    eq(1,result.completed,'already saved chapter remains completed')
    eq(0,result.failed,'finalization failure is not a second failed chapter')
    eq(false,Manager.new(f.options).persistence_blocked,'finalization failure can be reopened')
end
do
    local f=fixture()
    f.offline:writeCatalog(nil,nil,{chapters=f.chapters,complete=true})
    f.bodies.one='<p>范围缓存</p>'
    local m=Manager.new(f.options)
    eq(false,m:isCached(f.book),'legacy partial catalog must not claim full offline download')
    local task=assert(m:enqueueCache(f.book,nil,1))
    eq('completed',m:get(task.id).status,'range task reuses cached chapter')
    eq(false,m:isCached(f.book),'range task remains partial after completion')
end
do
    local f=fixture();local m=Manager.new(f.options)
    local retried
    local task=assert(m:enqueueCache(f.book,function(v)
        if v.status=='cancelled' then retried=m:retry(v.id) end
    end))
    eq(true,m:remove(task.id),'removal tolerates a terminal callback attempting retry')
    eq(false,retried,'task cannot restart during removal')
    eq(nil,m.active,'removal cannot leave an invisible worker')
    f.pending[1]({content='late'})
    eq(nil,f.records[task.id],'late callback cannot resurrect removed record')
end
do
    local f=fixture();local m=Manager.new(f.options)
    local task=assert(m:enqueueCache(f.book));f.pending[1](nil,{code='NETWORK_ERROR'})
    f.online:readCatalog().complete=nil -- Catalog written by v48 before a body failure.
    m=Manager.new(f.options)
    local resumed
    local app=App.new{storage=f.storage,book_service=f.service,download_manager=m,
        reader_session={cache=f.online,offline_cache=f.offline,
            resume=function(_,s,b,chapters) resumed=chapters;return {} end}}
    app:startReading(f.book)
    eq(1,f.catalogs(),'legacy failed cache task proves the saved full catalog without refetching')
    eq(2,#(resumed or {}),'legacy directory is available immediately for reading')
    eq(true,m:remove(task.id),'legacy failed history can be removed')
    eq(true,f.online:readCatalog().complete,'deletion retains the recovered directory metadata')
end
do
    local f=fixture();f.bodies.one='one';f.bodies.two='two'
    local m=Manager.new(f.options);local task=assert(m:enqueueCache(f.book))
    f.offline:readCatalog().cached_chapters=nil
    eq(true,m:isCached(f.book),'legacy full task proves full download coverage')
    eq(true,m:remove(task.id),'legacy full record can be deleted')
    eq(2,f.offline:readCatalog().cached_chapters,'deletion preserves independent verified coverage')
    eq(true,Manager.new(f.options):isCached(f.book),'legacy full badge survives restart without history')
end
return n
