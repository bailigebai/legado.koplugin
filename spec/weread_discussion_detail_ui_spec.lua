require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Discussions=require('legado.lib.weread_chapter_discussions')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local shown,pending={},{}
local client={discussionDetail=function(_,b,c,id,cb)
    local r={id=id,cb=cb};pending[#pending+1]=r;return {cancel=function() r.cancelled=true end} end}
local d=Discussions.new{book_id='b',chapter_uid='7',client=client}
d.loaded=true;d.rows={}
for i=1,8 do d.rows[i]={id='r'..i,content='全文'..i,author='读者'..i,avatar_url='https://wx.qlogo.cn/'..i..'/0'} end
local resumed=0
local doc={reading_state={chapters={{title='章节'}},index=1},resumeReading=function() resumed=resumed+1 end}
local p=Presenter.new{ui_manager={show=function(_,w) shown[#shown+1]=w end,close=function() end}}
p:showChapterDiscussions(d,doc)
local list=shown[#shown]
eq('function',type(list.custom_body),'discussion list uses native avatar cards')
eq(false,list.items[1].text:find('未提供',1,true)~=nil,'unknown numbers have no placeholder')
eq('https://wx.qlogo.cn/1/0',list.items[1].row.avatar_url,'avatar DTO reaches card rendering')
eq(0,#pending,'list starts no detail prefetch')
list.on_next();list=shown[#shown]
list.items[1].callback()
eq('r5',pending[1].id,'clicking a card loads its actual thought')
local loading=shown[#shown]
eq('全文5',loading.review.content,'loading retains complete original thought')
pending[1].cb{reviewId='r5',review={reviewId='r5',content='完整详情',author={name='作者'}},likesCount=2,commentsCount=1,
    comments={{reviewId='r5',commentId='c1',content='完整回复',author={name='回复者'}}},likes={{userVid=3,name='赞者'}}}
local detail=shown[#shown]
eq('回复者',detail.items[1].row.author,'detail shows reply author independently')
eq('回复',detail.categories[1].text:sub(1,6),'reply tab is offered')
detail.categories[2].callback()
eq('赞者',shown[#shown].items[1].row.author,'supporter tab shows actual returned people')
shown[#shown].categories[1].callback()
shown[#shown].items[1].callback()
eq('完整回复',shown[#shown].text,'reply expands its complete content')
shown[#shown].on_back()
detail=shown[#shown]
detail.on_back()
eq(2,shown[#shown].page,'returning from detail preserves list page')
eq(true,d.detail==nil,'return disposes detail controller')
shown[#shown].items[1].callback()
local stale=pending[2].cb
shown[#shown].on_back()
eq(true,pending[2].cancelled,'return cancels current detail network request')
local before=#shown
stale{reviewId='r5',review={reviewId='r5',content='late'}}
eq(before,#shown,'late detail never reopens closed screen')
shown[#shown].on_back()
eq(1,resumed,'closing root list resumes original reader exactly once')
return n
