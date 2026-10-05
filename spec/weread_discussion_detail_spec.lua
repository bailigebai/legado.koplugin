local A=require('assertions')
local Json=require('legado.lib.json_codec')
local Client=require('legado.lib.weread_client')
local Mapper=require('legado.lib.weread_mapper')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local sent,account={},'a'
local client=Client.new{auth={session=function() return {vid=account,access_token='fixture'} end},
    requests={execute=function(_,spec,cb) local r={spec=spec,cb=cb};sent[#sent+1]=r
        return {cancel=function() r.cancelled=true end} end}}
eq('function',type(client.discussionDetail),'verified single-review read is available')
local result,err
local function done(value,failure) result,err=value,failure end
local wire={reviewId='r1',review={reviewId='r1',bookId='b',chapterUid=7,content='完整想法',author={name='作者'}},
    likesCount=2,commentsCount=1,likes={{userVid=8,name='赞者',avatar='https://wx.qlogo.cn/a/0'}},
    comments={{reviewId='r1',commentId='c1',content='完整回复',author={name='回复者'},likesCount=0}}}
client:discussionDetail('b','7','r1',done)
eq('https://weread.qq.com/web/review/single?reviewId=r1&likesCount=20&likesDirection=1&synckey=0&likesMaxIdx=0',sent[1].spec.url,'detail seeds bounded likes and replies in one read')
eq('GET',sent[1].spec.method,'detail never writes reactions')
eq('background',sent[1].spec.priority,'optional detail yields to foreground reading')
eq(512*1024,sent[1].spec.max_bytes,'detail response is bounded')
sent[1].cb{status=200,body=Json.encode(wire)}
eq(nil,err,'matching review is accepted')
local review=Mapper.discussionDetail(result,'b','7','r1')
eq('完整想法',review.content,'detail preserves full content')
eq(2,review.likes_count,'real detail count is retained')
local replies=Mapper.discussionReplies(result,'r1')
eq('回复者',replies[1].author,'reply has its own author')
eq(0,replies[1].likes_count,'real reply zero likes survives')
eq(1,#Mapper.discussionLikes(result),'supporters use their own collection')
client:discussionDetail('b','7','r1',done)
local wrong={reviewId='other',review=wire.review}
sent[2].cb{status=200,body=Json.encode(wrong)}
eq(nil,result,'wrong thought cannot replace current detail')
client:discussionDetail('b','7','r1',done)
wire.review.chapterUid=8;sent[3].cb{status=200,body=Json.encode(wire)};wire.review.chapterUid=7
eq(nil,result,'wrong chapter is rejected at the network boundary')
client:discussionReplies('r1',done,{review_id='r1',max_idx=20})
eq('https://weread.qq.com/web/review/commentloadmore?reviewId=r1&commentId=&maxIdx=20&count=20&isExpandAll=0',sent[4].spec.url,'root pagination uses its loaded raw count')
sent[4].cb{status=200,body='{"comments":[],"commentsHasMore":0}'}
eq(false,result.has_more,'explicit exhaustion is retained')
client:discussionReplies('r1',done,{review_id='r1',comment_id='c1',max_idx=0})
eq('https://weread.qq.com/web/review/commentloadmore?reviewId=r1&commentId=c1&maxIdx=0&count=20&isExpandAll=0',sent[5].spec.url,'nested cursor pages use the verified regular child-detail operation')
sent[5].cb{status=200,body='{"comments":{"not":"array"}}'}
eq(nil,result,'malformed replies are not an empty success')
local before=#sent
client:discussionReplies('r1',done,{review_id='other',max_idx=0})
eq(before,#sent,'cursor from another thought creates no request')
client:discussionLikes('r1',20,done)
eq('https://weread.qq.com/web/review/single?reviewId=r1&likesCount=20&likesDirection=1&synckey=0&likesMaxIdx=20',sent[6].spec.url,'supporter page uses the actual loaded offset')
account='other';sent[6].cb{status=200,body=Json.encode(wire)}
eq(nil,result,'account switch invalidates detail collection')
account='a'
local h=client:discussionDetail('b','7','r1',done)
h:cancel();result='unchanged';sent[7].cb{status=200,body=Json.encode(wire)}
eq('unchanged',result,'cancel suppresses late completion')
eq(true,sent[7].cancelled,'cancel reaches transport')
local mapped=Mapper.discussionReplies({comments={
    {reviewId='wrong',commentId='bad',content='错想法'},
    {reviewId='r1',commentId='c2',content='回复',replyUser={name='对方'},author={name='甲',avatar='https://evil.test/a'},subCommentsCount=2},
    {reviewId='r1',commentId='c2',content='重复'},
}},'r1')
eq(1,#mapped,'different thought and duplicates are excluded')
eq('对方',mapped[1].reply_to,'reply target is preserved')
eq(nil,mapped[1].avatar_url,'untrusted avatar is omitted')
eq(nil,mapped[1].likes_count,'unknown reply likes stays nil')
eq(2,mapped[1].replies_count,'nested reply count is independent of review likes')
return n
