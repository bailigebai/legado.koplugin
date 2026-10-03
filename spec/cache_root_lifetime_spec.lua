local A=require('assertions')
local Fs=require('legado.lib.fs')
local Cache=require('legado.lib.cache_store')
local count=0
local function eq(a,b,m) count=count+1;A.equal(a,b,m) end
local state={ino=10,held=0,closed=0,files={}}
local sys={arch='arm'}
function sys:open(path,flags)
    eq('cache',path,'root handle opens the selected directory')
    eq(573440,flags,'ARM directory handle is read-only and refuses final symlinks')
    state.held=state.held+1;state.pinned_ino=state.ino;return 10
end
function sys:identity() return {dev='7',ino=tostring(state.pinned_ino)} end
function sys:close() state.held=state.held-1;state.closed=state.closed+1;return 0 end
local function attributes(path,key)
    local value=state.files[path] and {mode='file',size=#state.files[path],dev=7,ino=100}
        or {mode='directory',dev=7,ino=state.ino}
    return key and value[key] or value
end
local lfs={attributes=attributes,symlinkattributes=attributes,
dir=function() return function() return nil end end}
local fs=Fs.new{lfs=lfs,posixSyscalls=sys,atomicBackend=function(_,path,data,options)
    eq(tostring(state.ino),options.root_identity.ino,'atomic writes use the pinned root identity')
    state.files[path]=data;return true
end,open=function(path)
    local data=state.files[path]
    if data then return {read=function() return data end,close=function() end} end
end}
local cache=Cache.new{fs=fs,root='cache',settings={}}
-- FAT may reconstruct an unreferenced inode after an idle interval. An open
-- directory keeps that inode referenced without weakening replacement checks.
if state.held==0 then state.ino=state.ino+1 end
local usage,err=cache:usage()
eq(nil,err,'idle inode recycling does not invalidate a live cache root')
eq(0,usage and usage.bytes,'live root can still be scanned after idle')
local chapter={uid='chapter',index=1,title='One',url='https://example.test/one',source_id='source',book_id='book'}
eq(true,cache:writeBody('source','book',chapter,'<p>Ready</p>')~=nil,'download can write after idle')
eq('<p>Ready</p>',cache:readBody('source','book',chapter),'reading uses the downloaded body')
state.ino=9009
usage,err=cache:usage()
eq(nil,usage,'replacement of the actual directory remains rejected')
eq('cache root identity changed',err and err.message,'actual replacement retains its diagnosis')
cache=nil;collectgarbage('collect');collectgarbage('collect')
eq(0,state.held,'collecting a cache releases its directory handle')
eq(1,state.closed,'directory handle is closed exactly once')
return count
