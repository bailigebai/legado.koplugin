require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local Text=require('legado.lib.leko_text')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local requests,shown,markers={},{},{}
local account='account-a'
local auth={session=function() return {vid=account} end}
local client={chapterComments=function(_,book,chapter,callback,cursor)
    local row={book=book,chapter=chapter,callback=callback,cursor=cursor};requests[#requests+1]=row
    return {cancel=function() row.cancelled=true end}
end}
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,
    close=function() end},info_message={new=function(_,options) return options end}}
local state={book={id='local-book',remote_id='remote-book',source_id='weread',name='测试书'},
    index=1,chapters={{uid='local-chapter',remote_uid='7',title='第一章'}},active=true}
local document={reading_state=state,backend='immersive',closed=false,
    pauseReading=function() return true end,widget={model=assert(Text.parse('<p>庄周梦蝶。</p>','第一章')),
    setChapterComments=function(_,rows) markers=rows end}}
state.document=document
local session={active=state}
local app=App.new{weread_auth=auth,weread_client=client,reader_session=session,presenter=presenter}
presenter.app=app
local comments=app:prepareChapterComments(document)
eq(1,#requests,'committed WeRead chapter begins a bounded asynchronous comments request')
eq('remote-book',requests[1].book,'comments use the same remote book identity as reading')
eq('7',requests[1].chapter,'comments use the current remote chapter identity')
app:openChapterComments(document)
eq('随文评论 · 第一章',shown[#shown].title,'reading menu opens the current chapter panel')
eq('正在加载公开随文评论…',shown[#shown].empty_text,'loading state is explicit')
requests[1].callback({reviews={{id='r1',range='0-4',abstract='庄周梦蝶',content='对应原文的评论',author={name='读者'}}},has_more=false})
eq(1,#markers,'verified comments update the body markers')
eq(true,shown[#shown].items[1].text:find('庄周梦蝶',1,true)~=nil,'comment list includes the source quote')
eq(true,shown[#shown].items[1].text:find('对应原文的评论',1,true)~=nil,'comment list includes the associated thought')
local list=shown[#shown]
list.items[1].callback()
eq(true,shown[#shown].title:find('读者',1,true)~=nil,'opening a comment shows its author and full text')
shown[#shown].on_back()
shown[#shown].on_back()
local visible=#shown
list.items[1].callback()
eq(visible,#shown,'old panel comment buttons cannot reopen a closed panel')
local other={book=state.book,index=2,chapters=state.chapters,active=true,document={closed=false}}
session.active=other
eq(false,comments:current(),'moving to another reading chapter invalidates the first controller')
session.active=state
comments.next_cursor={ranges={}}
comments:load()
account='account-b'
requests[2].callback({reviews={{id='old-account',range='0-4',abstract='庄周梦蝶',content='旧账号'}}})
eq(1,#comments.rows,'old-account comment reply cannot change the chapter model')
eq(false,app:openChapterComments(document),'old reading document cannot query comments under the switched account')
eq(2,#requests,'account switch does not start a fresh request from the old book page')
document.closed=true
eq(false,app:openChapterComments(document),'closed document cannot reopen chapter comments')
account='account-a';document.closed=false
app:openChapterComments(document)
shown[#shown].on_back()
local before_reopen=#requests
app:openChapterComments(document)
eq(before_reopen+1,#requests,'reopening a panel cancelled before its first page restarts loading')
local Adapter=require('legado.lib.koreader_reader_ui')
local native_opened
local adapter=Adapter.new{on_chapter_comments=function(doc) native_opened=doc;return true end}
local native={menu={tab_item_table={},setUpdateItemTable=function() end}}
local proxy={backend='native'}
adapter:_attachMenu(native,proxy,{weread=true})
local action
for _,item in ipairs(native.menu.tab_item_table[1]) do if item.text=='本章评论' then action=item end end
eq(true,action~=nil,'native WeRead reader also exposes current chapter comments')
action.callback()
eq(proxy,native_opened,'native menu keeps the current document identity')
local source_reader={menu={tab_item_table={},setUpdateItemTable=function() end}}
adapter:_attachMenu(source_reader,proxy,{weread=false})
local source_comment_action=false
for _,item in ipairs(source_reader.menu.tab_item_table[1]) do
    if item.text=='本章评论' then source_comment_action=true end
end
eq(false,source_comment_action,'source books never expose WeRead comments')

local ReaderSession=require('legado.lib.reader_session')
local committed
local committed_state={active=true,document=proxy,offline=true}
ReaderSession._committed({active=committed_state,_notify=function() end,
    ui={on_reading_committed=function(doc) committed=doc end}},committed_state,proxy)
eq(proxy,committed,'comments initialization begins only after the reader has committed')
return count
