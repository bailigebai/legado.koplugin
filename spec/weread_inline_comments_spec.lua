local A=require('assertions')
local Json=require('legado.lib.json_codec')
local Client=require('legado.lib.weread_client')
local Text=require('legado.lib.leko_text')
local Mapper=require('legado.lib.weread_mapper')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local function yes(value,message) count=count+1;A.truthy(value,message) end
local sent,account={},'account-a'
local client=Client.new{auth={session=function() return {vid=account,access_token='token'} end},
    requests={execute=function(_,spec,callback)
        local request={spec=spec,callback=callback};sent[#sent+1]=request
        return {cancel=function() request.cancelled=true end}
    end}}
local result,failure
local handle=client:chapterComments('book-one','7',function(value,err) result,failure=value,err end)
eq('https://weread.qq.com/web/book/underlines?bookId=book-one&chapterUid=7',sent[1].spec.url,
    'chapter comments first request only the current chapter ranges')
sent[1].callback({status=200,body=Json.encode{bookId='book-one',chapterUid=7,
    underlines={{range='0-4'},{range='5-9'},{range='invalid'}}}})
eq('POST',sent[2].spec.method,'range comments use the observed read-only Web POST')
eq('https://weread.qq.com/web/book/readReviews',sent[2].spec.url,'comments retain the Web endpoint casing')
eq(2,#sent[2].spec.body.reviews,'only valid current-chapter ranges are requested')
sent[2].callback({status=200,body=Json.encode{bookId='book-one',chapterUid=7,reviews={
    {range='0-4',hasMore=1,maxIdx=20,synckey=77,pageReviews={
        {reviewId='r1',review={bookId='book-one',chapterUid=7,abstract='庄周梦蝶',content='同段想法'}},
        {reviewId='other',review={bookId='other-book',chapterUid=7,content='别书内容'}}}},
    {range='5-9',hasMore=0,pageReviews={
        {reviewId='r2',review={chapterUid=8,content='别章内容'}}}},
    {range='100-104',pageReviews={{reviewId='not-requested',review={content='未请求范围'}}}},
}}})
eq(nil,failure,'current chapter comments finish without an error')
eq(1,#result.reviews,'mismatched book, chapter and range comments are excluded')
eq('0-4',result.reviews[1].range,'the requested range is carried into each comment')
eq(true,result.has_more,'range pagination is available without fetching automatically')
local cursor=result.next_cursor
client:chapterComments('book-one','7',function(value) result=value end,cursor)
eq(3,#sent,'next comment page skips the already loaded underline request')
eq(20,sent[3].spec.body.reviews[1].maxIdx,'next page uses the returned per-range cursor')
sent[3].callback({status=200,body=Json.encode{reviews={{range='0-4',hasMore=0,pageReviews={
    {reviewId='r3',review={abstract='庄周梦蝶',content='后续想法'}}}}}}})
eq(false,result.has_more,'last range page has no further cursor')
local delivered=0
handle=client:chapterComments('book-one','7',function() delivered=delivered+1 end)
handle:cancel()
eq(true,sent[4].cancelled,'leaving the chapter cancels underline loading')
sent[4].callback({status=200,body=Json.encode{underlines={{range='0-4'}}}})
eq(0,delivered,'a cancelled range response is ignored')
eq(4,#sent,'cancelled response does not start a comment request')
client:chapterComments('book-one','7',function(_,err) failure=err end)
account='account-b'
sent[5].callback({status=200,body=Json.encode{underlines={{range='0-4'}}}})
eq('微信读书账号已切换',failure,'a successful old-account response cannot load new-account comments')
eq(5,#sent,'account switch prevents the second request')

local model=assert(Text.parse('<p>庄周<b>梦蝶</b>。</p><p>白日&nbsp;依山尽， 黄河入海流。</p>','第一章',true))
eq(2,model.source_positions and model.source_positions[1].first,
    'display paragraphs retain positions before trimming and reflow')
eq(9,model.source_positions and model.source_positions[2].first,
    'HTML block boundaries and Chinese characters are represented in the source map')
local rows=Mapper.inlineComments({reviews={
    {id='r1',range='1-5',abstract='庄周梦蝶',content='第一条'},
    {id='r2',range='8-21',abstract='白日 依山尽，黄河入海流',content='第二条'},
    {id='r3',range='20-24',abstract='不同版本',content='保留列表'},
}},'book-one','7',model)
eq(3,#rows,'all current-chapter comments remain in the list')
eq(1,rows[1].position.paragraph,'HTML tags do not shift the verified quote to a wrong paragraph')
eq(1,rows[1].position.char,'multi-byte Chinese is mapped to character positions')
eq(4,rows[1].position.last_char,'Chinese quote ends at the right character')
eq(2,rows[1].position.original_first,'verified comment carries its mapped original text position')
eq(2,rows[2].position.paragraph,'whitespace and HTML entities preserve the matched paragraph')
eq(nil,rows[3].position,'version mismatch never creates a body marker')
local duplicate=assert(Text.parse('<p>重复句子</p><p>重复句子</p>','章'))
eq(nil,Text.locateQuote(duplicate,'重复句子','0-4'),'ambiguous quotes are kept out of body markers')
eq(nil,Text.locateQuote(model,'庄周梦蝶','bad-range'),'unverified ranges never become inline markers')
eq(nil,Text.locateQuote(model,'庄周梦蝶','999999-1000000'),'out of bounds range never locates a unique quote')
local revised=assert(Text.parse('<p>前段已经改写。</p><p>庄周梦蝶。</p>','章',true))
eq(nil,Text.locateQuote(revised,'庄周梦蝶','0-4'),'old early range cannot mark the same quote in a later paragraph')
local Comments=require('legado.lib.weread_comments')
local pending,updates,cancels={},0,0
local active=true
local comments=Comments.new{book_id='book-one',chapter_uid='7',model=model,
    is_current=function() return active end,on_change=function() updates=updates+1 end,
    client={chapterComments=function(_,book,chapter,callback,page)
        pending[#pending+1]={callback=callback,cursor=page,book=book,chapter=chapter}
        return {cancel=function() cancels=cancels+1 end}
    end}}
eq(true,comments:load(),'first chapter comment page starts asynchronously')
eq(true,comments.loading,'comment loading status is visible')
eq(0,#comments.rows,'loading does not supply fake comments')
pending[1].callback({reviews={{id='r1',range='1-5',abstract='庄周梦蝶',content='可读'}},
    has_more=true,next_cursor=cursor})
eq(1,#comments.rows,'verified comments reach the reading model')
eq(1,comments.rows[1].position.paragraph,'controller carries the verified marker position')
comments:load()
eq(cursor,pending[2].cursor,'controller requests only the next range page')
pending[2].callback(nil,'离线，无法加载本章评论')
eq(1,#comments.rows,'failed next page preserves already loaded comments')
eq('离线，无法加载本章评论',comments.error,'offline error is visible without failing the reader')
comments:load()
comments:cancelLoad()
eq(1,cancels,'leaving the comment panel cancels its pending page')
pending[3].callback({reviews={{id='late',content='迟到评论'}}})
eq(1,#comments.rows,'cancelled response never replaces the visible chapter comments')
comments:load()
active=false
local updates_before=updates
pending[4].callback({reviews={{id='other-chapter',content='错章'}}})
eq(updates_before,updates,'chapter change discards the old comment callback')
eq(1,#comments.rows,'old chapter response never mixes with current chapter content')
return count
