local A=require('assertions')
local Mapper=require('legado.lib.weread_mapper')
local Client=require('legado.lib.weread_client')
local Service=require('legado.lib.weread_service')
local md5=require('legado.lib.safe_functions').functions.md5
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local book={id='book-local',remote_id='remote-1',source_id='weread',name='测试书'}
local chapters=Mapper.chapters({data={{bookId='remote-1',updated={
    {chapterUid=22,chapterIdx=2,title='第二章',wordCount=20},
    {chapterUid=11,chapterIdx=1,title='第一章',wordCount=30},
    {chapterUid=0,chapterIdx=0,title='封面',wordCount=0},
}}}},book)
eq(2,#chapters,'remote catalog creates two readable chapters')
eq('11',chapters[1].remote_uid,'catalog follows source chapter order')
eq('book-local',chapters[1].book_id,'chapter identity belongs to local book')
local index,fraction=Mapper.progress({book={chapterUid=22,chapterOffset=2500}},chapters)
eq(2,index,'cloud progress chooses the matching chapter')
eq(0.25,fraction,'cloud offset resumes at chapter fraction')
local body='xk=SG'
local shard=md5(body):upper()..body
local calls={}
local session={vid='v',access_token='a'}
local requests={execute=function(_,spec,callback)
    calls[#calls+1]=spec
    if spec.url:find('/web/reader/',1,true) then
        callback({status=200,body='<script>window.__INITIAL_STATE__={"reader":{"psvts":"server-psvts"}};</script>'})
    elseif spec.url:find('/e_0',1,true) then callback({status=200,body='{"bookId":"remote-1"}'})
    elseif spec.url:find('/t_0',1,true) then callback({status=200,body=shard})
    elseif spec.url:find('/t_1',1,true) then callback({status=200,body=''}) end
    return {cancel=function() end}
end}
local client=Client.new{requests=requests,auth={session=function() return session end}}
local content,error_value
Service.new(client):getContent({id='weread'},book,chapters[1],function(value,err)
    content,error_value=value,err
end)
eq(nil,error_value,'content request succeeds')
eq('Hi',content and content.content,'decoded chapter reaches reader service')
eq(4,#calls,'reader state is fetched before three text shard calls')
eq('server-psvts',calls[2].body.ps,'chapter request uses server reader state')
eq(true,calls[2].headers.Referer:find('/web/reader/',1,true)~=nil,'content request carries reader referer')
local missing_calls,missing_error=0,nil
Client.new{auth={session=function() return session end},requests={execute=function(_,spec,callback)
    missing_calls=missing_calls+1
    callback({status=200,body='<html>reader unavailable</html>'})
    return {cancel=function() end}
end}}:chapterContent('remote-1','11',function(_,err) missing_error=err end)
eq(1,missing_calls,'missing reader state does not send invalid shard requests')
eq('微信读书阅读页缺少章节验证参数',missing_error,'missing server state has a clear error')
return count
