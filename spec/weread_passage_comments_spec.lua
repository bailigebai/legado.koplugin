local A=require('assertions')
local Client=require('legado.lib.weread_client')
local Json=require('legado.lib.json_codec')
local Mapper=require('legado.lib.weread_mapper')
local Text=require('legado.lib.leko_text')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local sent,result={}
local client=Client.new{auth={session=function() return {vid='a',access_token='token'} end},
    requests={execute=function(_,spec,cb) sent[#sent+1]={spec=spec,cb=cb};return {cancel=function() end} end}}
client:chapterComments('b','7',function(data) result=data end)
eq('background',sent[1].spec.priority,'optional passage IO cannot claim foreground reading priority')
sent[1].cb{status=200,body=Json.encode{underlines={{range='1-5'}}}}
eq('background',sent[2].spec.priority,'readReviews also remains optional background IO')
sent[2].cb{status=200,body=Json.encode{reviews={{range='1-5',hasMore=0,pageReviews={
    {reviewId='r1',likesCount=8,commentsCount=2,review={bookId='b',chapterUid=7,abstract='庄周梦蝶',
        content='想法',author={name='作者',avatar='https://wx.qlogo.cn/a/0',userVid=42}}},
    {reviewId='r2',likesCount='9',commentsCount=-1,review={abstract='庄周梦蝶',content='无数量'}},
    {review={abstract='庄周梦蝶',content='缺少想法标识'}},
}}}}}
local model=assert(Text.parse('<p>庄周梦蝶。</p>','章',true))
local rows=Mapper.inlineComments(result,'b','7',model)
eq(3,#rows,'all returned passage thoughts reach the list')
eq('作者',rows[1].author,'author name survives per-range normalization')
eq('https://wx.qlogo.cn/a/0',rows[1].avatar_url,'passage cards retain the validated avatar')
eq('42',rows[1].author_id,'avatar cache gets a stable author identity')
eq(8,rows[1].likes_count,'actual outer likes count reaches passage cards')
eq(2,rows[1].comments_count,'actual outer reply count reaches passage cards')
eq(nil,rows[2].likes_count,'unknown or malformed likes stay absent')
eq(nil,rows[2].comments_count,'invalid reply counts stay absent')
eq(false,rows[3].detail_available,'synthetic list identity cannot be queried as a real reviewId')
local across=assert(Text.parse(require('legado.lib.weread_text_coordinates').body('<p>甲乙丙。</p><p>丁戊己。</p>'),'章',true))
local position=Text.locateQuote(across,'乙丙。\n丁戊','4-16')
eq(true,position~=nil,'a verified quote may span paragraph boundaries')
eq(1,position.paragraph,'cross-paragraph range starts in the original paragraph')
eq(2,position.char,'cross-paragraph range starts at the original character')
eq(2,position.last_paragraph,'cross-paragraph range retains its final paragraph')
eq(2,position.last_char,'cross-paragraph range retains its final character')
eq(nil,Text.locateQuote(across,'乙丙。丁戊','4-15'),'changed range never underlines the wrong ending')
eq(nil,Text.locateQuote(across,'乙丙。改版丁戊','4-16'),'edited quote never underlines another passage')
local image=assert(Text.parse('<p>甲乙丙。</p><img src="p"/><p>丁戊己。</p>','章',true,
    {p={path='p',width=1,height=1}}))
eq(nil,Text.locateQuote(image,'乙丙。丁戊','2-9'),'unknown image coordinates block a joined text marker')
return n
