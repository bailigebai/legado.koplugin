package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
require('library_screen_stub')
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local opened,ended=0,0
local reader=assert(Reader.new{source_id='weread',book={id='b',name='微信书'},
    chapter={uid='c',title='章'},index=1,count=2,body='<p>本章的最后一段。</p>',
    style={page_transition='off'},callbacks={chapter_discussions=function() opened=opened+1;return true end,
        chapter_end=function() ended=ended+1 end}})
h.ui:show(reader)
local target=reader:getChapterDiscussionTarget()
eq(true,target~=nil,'last page exposes a discussion card')
eq('章节讨论',target.title,'chapter footer contains only its entry name')
eq(nil,target.text,'footer does not expose an extra metadata or status line')
eq(true,target.y>=reader.page.geometry.body_top+reader.page.geometry.header_height+reader.page.geometry.content_height,
    'card occupies reserved space below the body')
eq(true,target.y+target.h<=reader.dimen.h-reader.page.geometry.footer_height,'card stays above footer')
local position=reader:getPosition()
local original_page,original_widgets=reader.page,reader.widgets
reader:onTap(nil,{pos={x=target.x+target.w/2,y=target.y+target.h/2}})
eq(1,opened,'tapping card opens current chapter discussions')
eq(position.char,reader:getPosition().char,'card tap does not turn page')
eq(original_page,reader.page,'opening discussions retains current pagination description')
eq(original_widgets,reader.widgets,'opening discussions does not rebuild text widgets')
reader:close()
eq(nil,reader:getChapterDiscussionTarget(),'closed reader has no active target')

local source=assert(Reader.new{source_id='source',book={id='s',name='书源'},chapter={uid='s1',title='章'},
    index=1,count=1,body='<p>最后一段。</p>',style={page_transition='off'}})
eq(nil,source:getChapterDiscussionTarget(),'ordinary source reading exposes no WeRead discussions')
eq(nil,source.page.geometry.discussion_height,'source pagination does not reserve discussion space')
source:close()
for _,dimensions in ipairs{{w=600,h=800,size=27},{w=800,h=600,size=60}} do
    h.dimensions.w,h.dimensions.h=dimensions.w,dimensions.h
    local body={}
    for i=1,30 do body[i]='<p>'..string.rep('横屏长段落。',20)..'</p>' end
    local long=assert(Reader.new{source_id='weread',book={id='long',name='长书'},chapter={uid='long-c',title='章'},
        index=1,count=2,body=table.concat(body),style={page_transition='off',body_font_size=dimensions.size},
        callbacks={chapter_discussions=function() return true end}})
    eq(nil,long:getChapterDiscussionTarget(),'non-final page does not show chapter-end card')
    h:drain()
    assert(long:setProgressFraction(1))
    local final=long:getChapterDiscussionTarget()
    eq(true,final~=nil,'long chapter final page exposes card')
    eq(true,final.y+final.h<=long.dimen.h-long.page.geometry.footer_height,'landscape and large font leave room for footer')
    for _,item in ipairs(long.widgets) do
        eq(true,item.y+item.element.height<=final.y,'large-font body does not overlap discussion target')
    end
    long:close()
end
h.dimensions.w,h.dimensions.h=600,800

local sent,shown={},{}
local account='account-a'
local auth={session=function() return {vid=account} end}
local client={chapterDiscussions=function(_,book,chapter,callback)
    local row={book=book,chapter=chapter,callback=callback};sent[#sent+1]=row
    return {cancel=function() row.cancelled=true end}
end}
client.discussionDetail=function(_,book,chapter,id,callback)
    callback{reviewId=id,review={reviewId=id,bookId=book,chapterUid=chapter,content='想法'..id,author={name='读者'}},
        likesCount=tonumber(id),comments={},likes={}}
    return {cancel=function() end}
end
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,close=function() end},
    info_message={new=function(_,options) return options end}}
local state={book={id='local',remote_id='remote',source_id='weread',name='书'},index=1,
    chapters={{uid='local-c',remote_uid='7',title='第一章'}},active=true}
local paused,resumed,footer_updates=0,0,0
local doc={reading_state=state,backend='immersive',closed=false,
    widget={page={at_end=false},setChapterDiscussions=function() footer_updates=footer_updates+1 end},
    pauseReading=function() paused=paused+1;return true end,
    resumeReading=function() resumed=resumed+1;return true end}
state.document=doc
local session={active=state}
local app=App.new{weread_auth=auth,weread_client=client,reader_session=session,presenter=presenter}
presenter.app=app
local discussions=app:prepareChapterDiscussions(doc)
eq(0,footer_updates,'preparing a controller does not repaint a fixed chapter footer')
eq(0,#sent,'committed ordinary page prepares controller without network work')
eq(true,discussions~=false,'immersive chapter owns a discussions controller')
app:openChapterDiscussions(doc)
eq(1,#sent,'opening chapter panel starts current chapter request')
eq('remote',sent[1].book,'uses remote book ID')
eq('7',sent[1].chapter,'uses remote chapter UID')
eq('章节讨论 · 第一章',shown[#shown].title,'panel stays within current immersive chapter')
eq('正在加载本章热门想法…',shown[#shown].empty_text,'loading is explicit')
local response={reviews={}}
for i=1,8 do response.reviews[i]={review={reviewId=tostring(i),content='想法'..i,author={name='读者'}},likesCount=i} end
sent[1].callback(response)
eq(0,footer_updates,'background discussion data only updates the open panel, not the fixed footer')
local list=shown[#shown]
eq(4,#list.items,'reader cards have enough room for avatar and comment body')
eq(true,list.items[1].text:find('赞 1',1,true)~=nil,'each row shows original likes count')
list.items[1].callback()
eq(1,shown[#shown].review.likes_count,'expanded comment retains likes count')
shown[#shown].on_back();list=shown[#shown]
list.on_next()
eq(4,#shown[#shown].items,'second local page includes remaining returned reviews')
eq(1,#sent,'local page turn does not invent a network cursor')
local last=shown[#shown]
last.on_back()
eq(1,resumed,'closing discussion panel resumes original reading')
local shown_count=#shown
last.items[1].callback()
eq(shown_count,#shown,'closed panel buttons cannot reopen old content')
account='account-b'
eq(false,app:openChapterDiscussions(doc),'old-account reader cannot start new discussion requests')
eq(1,#sent,'account switch starts no request from old book')
account='account-a';doc.closed=true
eq(false,app:openChapterDiscussions(doc),'closed document cannot reopen panel')
doc.closed=false;state.offline=true
doc.chapter_discussions=nil;app.chapter_discussions=nil
local offline=app:prepareChapterDiscussions(doc)
eq(true,offline.error:find('离线',1,true)~=nil,'offline chapter does not claim no discussion')
eq(1,#sent,'offline reader does not issue request')
state.offline=false
app:openChapterDiscussions(doc)
local retry
for _,action in ipairs(shown[#shown].actions) do if action.text=='重试' then retry=action end end
eq(true,retry~=nil,'failed or offline panel exposes retry')
retry.callback()
eq(2,#sent,'explicit retry can load after connection returns')
local cancelled_panel=shown[#shown]
cancelled_panel.on_back()
eq(true,sent[2].cancelled,'closing panel cancels its pending load')
app:openChapterDiscussions(doc)
eq(3,#sent,'reopening cancelled panel restarts missing initial result')
local new_panel=shown[#shown]
cancelled_panel.on_back()
eq(new_panel,offline.panel_widget,'old back action cannot close a newer chapter panel')
eq(nil,sent[3].cancelled,'old back action cannot cancel a newer request')
session.active={}
sent[3].callback({reviews={{review={id='old',content='旧章'},likesCount=99}}})
eq(0,#offline.rows,'previous chapter response cannot update current reading')
return count
