local A=require('assertions')
local Json=require('legado.lib.json_codec')
local Client=require('legado.lib.weread_client')
local Mapper=require('legado.lib.weread_mapper')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local sent,account={},'account-a'
local client=Client.new{auth={session=function() return {vid=account,access_token='token'} end},
    requests={execute=function(_,spec,callback)
        local request={spec=spec,callback=callback};sent[#sent+1]=request
        return {cancel=function() request.cancelled=true end}
    end}}
eq('function',type(client.chapterDiscussions),'client exposes the verified chapter popular review operation')
local result,failure
local handle=client:chapterDiscussions('book-one','7',function(value,err) result,failure=value,err end)
eq('GET',sent[1].spec.method,'popular chapter thoughts are read-only')
eq('https://weread.qq.com/web/review/list?bookId=book-one&chapterUid=7&listType=8&listMode=3&count=20&maxIdx=0',sent[1].spec.url,
    'bounds the initial popular list using authenticated server-verified count and start parameters')
eq(nil,sent[1].spec.body,'GET has no request body')
eq(512*1024,sent[1].spec.max_bytes,'popular reviews have a bounded response')
eq('background',sent[1].spec.priority,'optional popular reviews cannot outrank chapter text')
sent[1].callback({status=200,body=Json.encode{reviews={
    {review={reviewId='r1',bookId='book-one',chapterUid=7,content='想法',abstract='原文',author={name='读者',avatar='https://res.weread.qq.com/wravatar/test/0',userVid=123}},likesCount=37,commentsCount=2},
    {review={reviewId='wrong-book',bookId='other',chapterUid=7,content='错书'},likesCount=99},
    {review={reviewId='wrong-chapter',bookId='book-one',chapterUid=8,content='错章'},likesCount=99},
}}})
eq(nil,failure,'valid response reaches caller')
local rows=Mapper.chapterDiscussions(result,'book-one','7')
eq(1,#rows,'different book and chapter reviews are excluded')
eq('r1',rows[1].id,'inner review ID is retained')
eq('读者',rows[1].author,'inner author is retained')
eq('https://res.weread.qq.com/wravatar/test/0',rows[1].avatar_url,'official author avatar is retained')
eq('123',rows[1].author_id,'avatar identity comes from the actual author')
eq('想法',rows[1].content,'inner review content is retained')
eq(37,rows[1].likes_count,'likes come from the outer review wrapper')
eq(2,rows[1].comments_count,'discussion reply count comes from the wrapper')
rows=Mapper.chapterDiscussions({reviews={
    {review={id='zero',content='<b>零赞</b>'},likesCount=0},
    {review={id='unknown',content='无数值'}},
    {review={id='bad',content='非法'},likesCount=-1,commentsCount='1'},
    {review={id='fraction',content='小数'},likesCount=1.5},
    {review={id='string',content='字符串'},likesCount='12'},
}},'book-one','7')
eq(0,rows[1].likes_count,'zero likes is a known count')
eq('零赞',rows[1].content,'review HTML is displayed as plain text')
for i=2,5 do eq(nil,rows[i].likes_count,'missing or malformed likes remain unknown') end
local large={reviews={}}
for i=1,105 do large.reviews[i]={review={id=tostring(i),content='想法'},likesCount=i} end
eq(100,#Mapper.chapterDiscussions(large,'book-one','7'),'single popular list is bounded')
client:chapterDiscussions('book-one','7',function(value,err) result,failure=value,err end)
sent[2].callback({status=200,body='{}'})
eq(nil,result,'a successful empty JSON object does not mean an empty discussion list')
eq('本章热门想法返回格式无效',failure,'missing review list is a protocol error')
client:chapterDiscussions('book-one','7',function(value,err) result,failure=value,err end)
sent[3].callback({status=200,body='{"reviews":[]}'})
eq(nil,failure,'explicit empty review list is valid')
eq(0,#result.reviews,'empty list stays empty')
local delivered=0
handle=client:chapterDiscussions('book-one','7',function() delivered=delivered+1 end)
handle:cancel();sent[4].callback({status=200,body=Json.encode{reviews={}}})
eq(true,sent[4].cancelled,'close propagates cancellation to the transport')
eq(0,delivered,'cancelled response cannot update the chapter')
client:chapterDiscussions('book-one','7',function(value,err) result,failure=value,err end)
account='account-b';sent[5].callback({status=200,body=Json.encode{reviews={}}})
eq(nil,result,'old-account result is rejected')
eq('微信读书账号已切换',failure,'switching account cannot deliver reviews to the previous page')
local before=#sent
client:chapterDiscussions('','7',function(_,err) failure=err end)
eq(before,#sent,'invalid identity creates no request')
eq('书籍或章节标识无效',failure,'invalid identity is explicit')
client:chapterDiscussions('book-one','7',function(value,err) result,failure=value,err end)
sent[6].callback({status=200,body='{"reviews":{"unexpected":"object"}}'})
eq(nil,result,'an object review field cannot be presented as an empty array')
eq('本章热门想法返回格式无效',failure,'array type is validated before mapping')

local Discussions=require('legado.lib.weread_chapter_discussions')
local pending,changes={},0
local active=true
local discussion=Discussions.new{book_id='book-one',chapter_uid='7',is_current=function() return active end,
    on_change=function() changes=changes+1 end,
    client={chapterDiscussions=function(_,book,chapter,callback)
        local row={book=book,chapter=chapter,callback=callback};pending[#pending+1]=row
        return {cancel=function() row.cancelled=true end}
    end}}
eq(false,discussion.loading,'controller creation is lazy')
eq(0,#pending,'opening a normal chapter does not request popular reviews')
eq(true,discussion:load(),'reaching chapter end starts asynchronous loading')
eq(false,discussion:load(),'repeated page notifications do not duplicate an active request')
eq('book-one',pending[1].book,'request is bound to remote book')
eq('7',pending[1].chapter,'request is bound to remote chapter')
pending[1].callback(nil,'网络失败')
eq(false,discussion.loading,'network error settles loading')
eq('网络失败',discussion.error,'network failure is exposed for retry')
eq(true,discussion:load(),'explicit retry can restart a failed request')
pending[2].callback({reviews={{review={id='r1',content='想法'},likesCount=37}}})
eq(37,discussion.rows[1].likes_count,'controller carries the original likes count')
eq(true,discussion.loaded,'valid result is marked loaded')
eq(false,discussion:load(),'loaded popular list does not invent a next page')
local before_changes=changes
discussion:close()
eq(false,discussion:current(),'closed controller is invalid')
eq(false,discussion:load(),'closed controller cannot reopen network work')
eq(before_changes,changes,'close does not notify stale page')
local stale=Discussions.new{client=discussion.client,book_id='book-one',chapter_uid='8',
    is_current=function() return active end,on_change=function() changes=changes+1 end}
stale:load();stale:cancelLoad()
eq(true,pending[3].cancelled,'cancelling pending request reaches transport')
pending[3].callback({reviews={{review={id='late',content='迟到'}}}})
eq(0,#stale.rows,'late cancelled result cannot insert rows')
stale:load();active=false
pending[4].callback({reviews={{review={id='other',content='错章'}}}})
eq(0,#stale.rows,'changing owner invalidates successful pending response')
local synchronous=Discussions.new{book_id='b',chapter_uid='c',client={chapterDiscussions=function(_,_,_,callback)
    callback({reviews={}});return {cancel=function() error('completed handle retained') end}
end}}
synchronous:load()
eq(true,synchronous.loaded,'synchronous completion is supported')
eq(nil,synchronous.request,'completed synchronous request is not retained')
synchronous:close()
return count
