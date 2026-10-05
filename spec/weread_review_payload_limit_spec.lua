local A=require('assertions')
local Client=require('legado.lib.weread_client')
local Engine=require('legado.lib.request_engine')
local Json=require('legado.lib.json_codec')
local Fakes=require('support.network_fakes')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local function payload(size)
    local reviews={}
    for index=1,size do reviews[index]={review={reviewId=tostring(index),bookId='book',chapterUid=136,
        content=string.rep('想法',210)},likesCount=index} end
    return Json.encode{reviews=reviews,chapterTotalCount=648}
end
local default_body=payload(500)
eq(true,#default_body>512*1024,'realistic 500-item default exceeds the production review limit')
local scheduler=Fakes.scheduler()
local transport=Fakes.transport({function(request)
    local amount=tonumber(request.url:match('[?&]count=(%d+)')) or 500
    return {status=200,headers={['Content-Type']='application/json'},body=payload(amount)}
end,{status=200,headers={['Content-Type']='application/json'},body=default_body}})
local engine=Engine.new{scheduler=scheduler,transport=transport,subprocess=Fakes.subprocess{enabled=false},
    logger={debug=function() end,warn=function() end}}
local client=Client.new{requests=engine,auth={session=function() return {vid='fixture-account',access_token='fixture-token'} end}}
local result,failure
client:chapterDiscussions('book','136',function(data,err) result,failure=data,err end)
scheduler:runAll()
eq(nil,failure,'chapter discussions remain readable through the actual byte-limited request engine')
eq(20,#result.reviews,'initial list is bounded before transferring and parsing reviews')
eq(0,transport.aborted,'normal bounded response is not aborted as oversized')
client:chapterDiscussions('book','136',function(data,err) result,failure=data,err end)
scheduler:runAll()
eq(nil,result,'a server ignoring the count cannot bypass the response byte limit')
eq('string',type(failure),'oversized failure remains an error rather than an empty review list')
eq(1,transport.aborted,'oversized response is aborted at the transport boundary')
return count
