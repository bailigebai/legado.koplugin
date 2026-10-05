local A=require('assertions')
local Fs=require('legado.lib.fs')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local function fixture(change)
    local files={archive={ino=1,data='new'},old={ino=2,data=string.rep('O',1024*1024)}}
    local largest,synced=0,0
    local fs=Fs.new{lfs={attributes=function(path) local v=files[path];return v and {dev=1,ino=v.ino,size=#v.data} end},
        fileIdentity=function(path) local v=files[path];return v and {dev=1,ino=v.ino} end,
        remove=function(path) files[path]=nil;return true end,
        open=function(path,mode)
            if mode=='rb' then
                local v=files[path];if not v then return nil end
                local offset=1
                return {read=function(_,size) largest=math.max(largest,size);if offset>#v.data then return nil end
                    local chunk=v.data:sub(offset,offset+size-1);offset=offset+#chunk;return chunk end,close=function() return true end}
            end
            files[path]={ino=3,data=''}
            return {write=function(_,data) files[path].data=files[path].data..data;return true end,
                flush=function() if change then files.old={ino=4,data='changed'} end;return true end,
                close=function() return true end}
        end}
    fs.syncFile=function() synced=synced+1;return true end
    fs.read=function() error('old EPUB must be streamed') end
    return fs,files,function() return largest,synced end
end
do
    local fs,files,stats=fixture()
    local replacement=assert(fs:prepareReplacement('archive','old'))
    eq(true,replacement.previous.exists,'child records the old target')
    eq('2',replacement.previous.identity.ino,'old target identity crosses the child boundary')
    eq('archive.backup',replacement.backup.path,'child creates an exactly owned backup')
    eq(files.old.data,files['archive.backup'].data,'child streams all old bytes without changing the original')
    eq(65536,stats(),'backup memory is bounded to 64 KiB chunks')
    local largest,synced=stats();eq(1,synced,'new archive is synced in the child before parent publication')
end
do
    local fs,files=fixture(true)
    local result,err=fs:prepareReplacement('archive','old')
    eq(nil,result,'concurrent replacement rejects the old backup')
    eq('STORAGE_ERROR',err.code,'changed target has a stable error')
    eq('changed',files.old.data,'preparation never restores over a newer target')
    eq(nil,files['archive.backup'],'failed preparation removes only its own backup')
end
return n
