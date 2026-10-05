local A=require('assertions')
local Loader=require('legado.lib.cover_loader')
local Mapper=require('legado.lib.weread_mapper')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local sent,writes={},{}
local fs={ensureDirectory=function() end,readBounded=function() end,
    atomicWrite=function(_,path,bytes) writes[#writes+1]=path;return true end}
local loader=Loader.new{fs=fs,root='cache/covers/avatars',priority='background',max_bytes=512*1024,max_redirects=0,timeout=8,
    validate_url=Mapper.avatarUrl,request_engine={execute=function(_,spec,cb)
        local r={spec=spec,cb=cb};sent[#sent+1]=r;return {cancel=function() r.cancelled=true end} end}}
local path,err
local first=loader:load({id='a',source_id='weread-avatar',cover_url='https://wx.qlogo.cn/a/0'},function(value,error) path,err=value,error end)
eq('background',sent[1].spec.priority,'avatar cannot outrank chapter text')
eq(512*1024,sent[1].spec.max_bytes,'avatar bytes use the smaller configured bound')
eq(0,sent[1].spec.max_redirects,'avatar cannot redirect outside trusted hosts')
eq(8,sent[1].spec.timeout,'optional avatar has a short timeout')
eq(nil,sent[1].spec.headers,'avatar carries no authenticated headers')
local second=loader:load({id='a',source_id='weread-avatar',cover_url='https://wx.qlogo.cn/a/0'},function() end)
eq(1,#sent,'same visible avatar shares one request')
first:cancel();eq(nil,sent[1].cancelled,'another visible subscriber can finish')
second:cancel();eq(true,sent[1].cancelled,'last subscriber close cancels transport')
sent[1].cb{body='\255\216\255test\255\217'}
eq(0,#writes,'late avatar cannot write cache after cancellation')
for _,url in ipairs{'https://wx.qlogo.cn.evil.test/a','http://wx.qlogo.cn/a','https://wx.qlogo.cn:443/a','https://user@wx.qlogo.cn/a'} do
    loader:load({cover_url=url},function(value,error) path,err=value,error end)
    eq(nil,path,'untrusted avatar is unavailable')
end
eq(1,#sent,'untrusted URL produces no request')
loader:load({id='b',cover_url='https://res.weread.qq.com/wravatar/b/0'},function(value,error) path,err=value,error end)
sent[2].cb{body='\255\216\255'..string.rep('x',512*1024)..'\255\217'}
eq(nil,path,'oversized decoded response does not become an avatar path')
eq(0,#writes,'oversized avatar is not cached')
return n
