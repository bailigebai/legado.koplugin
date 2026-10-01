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
    {chapterUid=11,chapterIdx=1,title='第一章',wordCount=30,
        tar='https://res.weread.qq.com/wrco/tar_11'},
    {chapterUid=0,chapterIdx=0,title='封面',wordCount=0},
}}}},book)
eq(2,#chapters,'remote catalog creates two readable chapters')
eq('11',chapters[1].remote_uid,'catalog follows source chapter order')
eq('book-local',chapters[1].book_id,'chapter identity belongs to local book')
eq('https://res.weread.qq.com/wrco/tar_11',chapters[1].resource_tar,
    'catalog preserves the per-chapter image resource package')
local index,fraction=Mapper.progress({book={chapterUid=22,chapterOffset=2500}},chapters)
eq(2,index,'cloud progress chooses the matching chapter')
eq(0.25,fraction,'cloud offset resumes at chapter fraction')
local body='xk=SG'
local shard=md5(body):upper()..body
local calls={}
local session={vid='v',access_token='a'}
local requests={execute=function(_,spec,callback)
    calls[#calls+1]=spec
    if spec.url:find('/e_0',1,true) then callback({status=200,body='{"bookId":"remote-1"}'})
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
eq(3,#calls,'normal chapter load only fetches three text shards')
eq(true,calls[1].url:find('/e_0',1,true)~=nil,'chapter starts with the content endpoint')
eq(true,type(calls[1].body.ps)=='string' and #calls[1].body.ps>0,'chapter request signs generated reader state')
eq(true,calls[1].headers.Referer:find('/web/reader/',1,true)~=nil,'content request carries reader referer')
local fallback_calls,fallback_first={},true
local fallback_content,fallback_error
Client.new{auth={session=function() return session end},requests={execute=function(_,spec,callback)
    fallback_calls[#fallback_calls+1]=spec
    if spec.url:find('/e_0',1,true) then
        if fallback_first then fallback_first=false; callback({status=200,body='{}'})
        else callback({status=200,body='{"bookId":"remote-1"}'}) end
    elseif spec.url:find('/web/reader/',1,true) then
        callback({status=200,body='<script>{"psvts":"server-psvts"}</script>'})
    elseif spec.url:find('/t_0',1,true) then callback({status=200,body=shard})
    elseif spec.url:find('/t_1',1,true) then callback({status=200,body=''}) end
    return {cancel=function() end}
end}}:chapterContent('remote-1','11',function(value,err) fallback_content,fallback_error=value,err end)
eq(nil,fallback_error,'empty fast response recovers with server reader state')
eq('Hi',fallback_content,'fallback still returns decoded content')
eq(5,#fallback_calls,'reader page is requested only after an empty fast response')
eq(true,fallback_calls[2].url:find('/web/reader/',1,true)~=nil,'fallback loads reader state')
eq('server-psvts',fallback_calls[3].body.ps,'fallback retries with server reader state')
local missing_calls,missing_error=0,nil
Client.new{auth={session=function() return session end},requests={execute=function(_,spec,callback)
    missing_calls=missing_calls+1
    callback({status=200,body=spec.url:find('/e_0',1,true) and '{}' or '<html>reader unavailable</html>'})
    return {cancel=function() end}
end}}:chapterContent('remote-1','11',function(_,err) missing_error=err end)
eq(2,missing_calls,'missing fallback reader state does not send more shard requests')
eq('微信读书阅读页缺少章节验证参数',missing_error,'missing server state has a clear error')
return count
