local Cache=require('legado.lib.cache_store');local Fs=require('legado.lib.fs')
local paths={['/cache']={mode='directory'},['/cache/s']={mode='directory'},['/cache/s/b']={mode='directory'},
    ['/cache/s/b/chapters']={mode='directory'},['/cache/s/b/chapters/a.body']={mode='file',size=70,modification=1},
    ['/cache/s/b/chapters/z.body']={mode='file',size=50,modification=2},['/cache/s/b/catalog.json']={mode='file',size=10,modification=0}}
local lfs={attributes=function(p)return paths[p] end,symlinkattributes=function(p)return paths[p] end}
function lfs.dir(path)
    local names={'.','..'};for p in pairs(paths) do local suffix=p:sub(#path+2)
        if p:sub(1,#path+1)==path..'/' and suffix~='' and not suffix:find('/',1,true) then names[#names+1]=suffix end end
    local i,state=0,{};return function(s)i=i+1;return names[i]end,state
end
local fs=Fs.new{lfs=lfs};function fs:ensureDirectory()return true end;function fs:removeFile(path)paths[path]=nil;return true end
local cache=Cache.new{root='/cache',fs=fs};local usage=assert(cache:usage());assert(usage.bytes==130 and usage.files==3)
local result=assert(cache:enforceLimit(0.0001,0.00008,0.00006))
assert(result.removed==1 and result.bytes==60,'oldest removable cache is evicted to the retain target')
assert(paths['/cache/s/b/chapters/a.body']==nil and paths['/cache/s/b/chapters/z.body'] and paths['/cache/s/b/catalog.json'])
local Fakes=require('support.network_fakes')
local count=3
local function eq(want,got,message) count=count+1; assert(want==got,message..': expected '..tostring(want)..', got '..tostring(got)) end
local function fixture(limit,threshold,retain)
    local entries={['/cache']={mode='directory'}}
    local disk={}
    local api={attributes=function(path)return entries[path]end,symlinkattributes=function(path)return entries[path]end}
    function api.dir(path)
        local names={'.','..'}
        for child in pairs(entries) do
            local suffix=child:sub(#path+2)
            if child:sub(1,#path+1)==path..'/' and suffix~='' and not suffix:find('/',1,true) then names[#names+1]=suffix end
        end
        table.sort(names)
        local index=0;return function()index=index+1;return names[index]end
    end
    local io_fs=Fs.new{lfs=api}
    function io_fs:ensureDirectory() return true end
    function io_fs:atomicWrite(path,value)
        local parent=path:match('^(.*)/[^/]+$')
        while parent and parent~='' do entries[parent]={mode='directory'};parent=parent:match('^(.*)/[^/]+$') end
        disk[path]=value;entries[path]={mode='file',size=#value,modification=1};return true
    end
    function io_fs:removeFile(path)entries[path]=nil;disk[path]=nil;return true end
    local values={cache_limit_mb=(limit or 1000)/1048576,cache_cleanup_threshold_mb=(threshold or 800)/1048576,cache_retain_mb=(retain or 500)/1048576}
    local scheduler=Fakes.scheduler()
    local store=Cache.new{root='/cache',fs=io_fs,settings={get=function(_,key)return values[key]end},scheduler=scheduler}
    local scans=0;local scan=store._scan
    function store:_scan()scans=scans+1;return scan(self)end
    return store,scheduler,io_fs,disk,function()return scans end
end

do
    local store,scheduler,_,disk,scans=fixture()
    store:setActive{source_id='s',book_id='b'}
    assert(store:writeHtml('s','b',{uid='a'},string.rep('a',10)))
    assert(store:writeHtml('s','b',{uid='b'},string.rep('b',15)))
    assert(store:writeHtml('s','b',{uid='a'},'new'))
    eq(1,scans(),'only unknown initial usage scans synchronously during a write burst')
    eq(1,#scheduler.queue,'body and html writes share one idle cleanup')
    scheduler:runAll()
    eq(2,scans(),'idle callback performs one coalesced full scan')
    local usage=assert(store:usage())
    eq(18,usage.bytes,'replacement subtracts the old payload size')
    local path=assert(store:writeBody('s','b',{uid='c'},'chapter'))
    eq(18+#disk[path],store.known_bytes,'envelope bytes, not only body bytes, count toward the hard cap')
end

do
    local store,_,io_fs,disk=fixture(100,90,40)
    io_fs:atomicWrite('/cache/s/old/html/old.html',string.rep('o',60))
    store:setActive{source_id='s',book_id='new'}
    local path=assert(store:writeHtml('s','new',{uid='a'},string.rep('n',50)))
    eq(nil,disk['/cache/s/old/html/old.html'],'near-cap admission removes eligible old files before writing')
    eq(50,#disk[path],'admitted write stays under the hard limit')
end

do
    local store,_,io_fs,disk=fixture(100,90,40)
    io_fs:atomicWrite('/cache/s/b/html/old.html',string.rep('o',80))
    store:setActive{source_id='s',book_id='b'}
    local path,err=store:writeHtml('s','b',{uid='new'},string.rep('n',30))
    eq(nil,path,'active book cannot grow past hard cap when nothing can be evicted')
    eq('STORAGE_ERROR',err and err.code,'hard-cap admission failure is structured')
    eq(nil,disk['/cache/s/b/html/new.html'],'rejected write leaves no new file')
    eq(80,#disk['/cache/s/b/html/old.html'],'active book is never evicted to admit new work')
end

do
    local store,_,io_fs,disk=fixture()
    io_fs.lfs.dir=function()error('scan unavailable')end
    local path,err=store:writeHtml('s','b',{uid='a'},'new')
    eq(nil,path,'unknown usage with failed scan fails closed')
    eq('STORAGE_ERROR',err and err.code,'scan failure reaches the caller')
    eq(err,store.last_cleanup_error,'returned cleanup error is retained for diagnostics')
    eq(nil,next(disk),'failed capacity check never writes a file')
end

do
    local store,scheduler,io_fs=fixture(100,60,20)
    store:setActive{source_id='s',book_id='b'}
    assert(store:writeHtml('s','b',{uid='a'},string.rep('n',50)))
    io_fs:atomicWrite('/cache/s/old/html/old.html',string.rep('o',30))
    local expected={code='STORAGE_ERROR',message='remove failed'}
    function io_fs:removeFile()return nil,expected end
    scheduler:runAll()
    eq(expected,store.last_cleanup_error,'idle cleanup retains the second error return from enforceLimit')
end

do
    local store,scheduler,io_fs,disk=fixture(250,100,50)
    io_fs:atomicWrite('/cache/s/current/html/a.html',string.rep('a',60))
    io_fs:atomicWrite('/cache/s/current2/html/a.html',string.rep('x',60))
    store:setActive{source_id='s',book_id='current'}
    assert(store:writeBody('s','candidate',{uid='b'},'chapter'))
    assert(store:writeHtml('s','candidate',{uid='b'},'<p>chapter</p>'))
    scheduler:runAll()
    eq(60,#disk['/cache/s/current/html/a.html'],'active book stays protected during another book preparation')
    eq(nil,disk['/cache/s/current2/html/a.html'],'book protection does not match a sibling id prefix')
    eq(true,disk['/cache/s/candidate/chapters/b.body']~=nil,'candidate body survives its following HTML write and idle cleanup')
    eq(true,disk['/cache/s/candidate/html/b.html']~=nil,'candidate HTML survives the same cleanup cycle')
    eq(nil,next(store.pending_keep),'completed maintenance releases temporary preparation protection')
end

do
    local store,scheduler=fixture(100,80,50)
    function scheduler:scheduleIn()error('scheduler stopped')end
    assert(store:writeHtml('s','b',{uid='a'},'new'))
    eq('STORAGE_ERROR',store.last_cleanup_error and store.last_cleanup_error.code,'scheduling failure remains visible without failing a committed write')
    eq(nil,next(store.pending_keep),'scheduling failure cannot permanently pin every previously written book')
end

do
    local store,_,_,disk=fixture(100,90,40)
    store.scheduler=nil
    store:setActive{source_id='s',book_id='b'}
    assert(store:writeHtml('s','b',{uid='a'},string.rep('x',80)))
    local path,err=store:writeHtml('s','b',{uid='next'},string.rep('y',30))
    eq(nil,path,'scheduler-free fallback still enforces capacity')
    eq('STORAGE_ERROR',err and err.code,'scheduler-free capacity failure is structured')
    eq(nil,disk['/cache/s/b/html/next.html'],'scheduler-free failure does not write past capacity')
end

do
    local store=fixture()
    store.settings=nil
    assert(store:writeHtml('s','b',{uid='a'},'chapter'))
    eq(1,assert(store:clear()),'standalone cache writes do not acquire permanent preparation pins')
end

do
    local store,scheduler,io_fs,disk=fixture()
    local path=assert(store:writeHtml('s','b',{uid='a'},'original'))
    scheduler:runAll()
    function io_fs:atomicWrite()error('write panicked')end
    local result,err=store:writeHtml('s','b',{uid='a'},'replacement')
    eq(nil,result,'atomic backend exception becomes a failed cache write')
    eq('STORAGE_ERROR',err and err.code,'atomic backend exception remains structured')
    eq('original',disk[path],'failed atomic replacement preserves the old file')
    eq(nil,next(store.pending_keep),'failed atomic replacement releases its temporary book protection')
end

do
    local store,scheduler,_,disk=fixture()
    assert(store:writeHtml('s','b',{uid='a'},'original'))
    scheduler:runAll()
    function store.settings:get()error('settings unavailable')end
    local ok,path,err=pcall(store.writeHtml,store,'s','candidate',{uid='a'},'new')
    eq(true,ok,'capacity setting failure stays within the cache error boundary')
    eq(nil,path,'unreadable capacity never admits a new write')
    eq('STORAGE_ERROR',err and err.code,'capacity setting failure is structured')
    eq(nil,disk['/cache/s/candidate/html/a.html'],'capacity failure creates no candidate file')
    eq(nil,next(store.pending_keep),'capacity exception releases candidate protection')
end

return count
