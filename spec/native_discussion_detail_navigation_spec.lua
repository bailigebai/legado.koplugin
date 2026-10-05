package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Discussions=require('legado.lib.weread_chapter_discussions')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local cb,cancelled,resumed,avatars=nil,0,0,{}
local client={discussionDetail=function(_,_,_,_,fn) cb=fn;return {cancel=function() cancelled=cancelled+1 end} end}
local d=Discussions.new{client=client,book_id='b',chapter_uid='7'}
d.loaded=true;d.rows={{id='r',content=string.rep('完整想法。',100),author='作者',avatar_url='https://wx.qlogo.cn/a/0'}}
local doc={reading_state={index=1,chapters={{title='第一章'}}},resumeReading=function() resumed=resumed+1 end}
local p=Presenter.new{ui_manager=h.ui,avatar_loader=function(_,fn)
    local r={cb=fn};avatars[#avatars+1]=r;return {cancel=function() r.cancelled=true end} end}
local list=p:showChapterDiscussions(d,doc)
list.cells[1].button:onTapSelect()
local pending=d.panel_widget
eq(true,avatars[1].cancelled,'entering detail cancels old list avatar')
eq('正在加载想法详情…',pending.options.subtitle,'native detail shows initial loading')
pending.options.actions[1].callback()
d.panel_widget:onClose();h:drain()
eq(0,cancelled,'reading full text and returning keeps its parent detail load alive')
pending=d.panel_widget
pending:onClose()
eq(1,cancelled,'native Back cancels detail before deferred navigation')
local before=h.shown
cb{reviewId='r',review={reviewId='r',content='late'}}
eq(before,h.shown,'late callback cannot reopen in native Back gap')
h:drain()
eq('本章热门想法',d.panel_widget.options.subtitle,'Back returns to original list')
d.panel_widget.cells[1].button:onTapSelect()
local wire={reviewId='r',review={reviewId='r',content='正文',author={name='作者'}},likesCount=0,commentsCount=6,comments={}}
for i=1,6 do wire.comments[i]={reviewId='r',commentId='c'..i,content=string.rep('回复正文',30),author={name='回复者'..i}} end
cb(wire)
local panel=d.panel_widget
eq(5,#panel.cells,'native detail has header and four visible reply cards')
eq(true,panel.content:getSize().h<=panel.content_height,'detail header and replies fit above footer')
panel.cells[2].button:onTapSelect()
local full=d.panel_widget
eq(wire.comments[1].content,full.options.text,'native full reply viewer preserves every character')
eq(full,full.reading_body.dialog,'scrolling targets the actual top-level window')
full:onClose();h:drain()
panel=d.panel_widget
eq(5,#panel.cells,'full reply Back restores detail cards')
panel:onClose();h:drain()
d.panel_widget:onClose();h:drain()
eq(1,resumed,'closing details and list returns to reading once')
return n
