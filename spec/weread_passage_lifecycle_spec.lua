package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local App=require('legado.ui.app')
local Owner=require('legado.lib.koreader_reader_ui')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local sent,session={},{ }
local auth={session=function() return {vid='a'} end}
local app=App.new{weread_auth=auth,reader_session=session,weread_client={chapterComments=function(_,b,c,cb)
    local row={chapter=c,cb=cb};sent[#sent+1]=row;return {cancel=function() row.cancelled=true end} end}}
local owner=Owner.new{ui_manager=h.ui,on_chapter_comments=function() return true end}
local chapters={{uid='c1',remote_uid='7',title='章一'},{uid='c2',remote_uid='8',title='章二'}}
local book={id='b',remote_id='remote',source_id='weread'}
local state={book=book,chapters=chapters,index=1,active=true,catalog_complete=true}
local cancelled_before_text
local coordinates=require('legado.lib.weread_text_coordinates')
local doc=assert(owner:openChapter({state=state,body=coordinates.body('<p>甲乙丙。</p>'),progress={immersive_style={page_transition='off'}}},
    {ready=function(d) state.document=d;session.active=state;return true end,
        chapter=function() cancelled_before_text=sent[1].cancelled;return {cancel=function() end} end,
        close=function(d) if d.chapter_comments then d.chapter_comments:close() end end}))
local first=app:prepareChapterComments(doc)
doc.widget:nextPage()
eq(true,cancelled_before_text,'passage lookup releases optional IO before the next chapter request')
eq(true,sent[1].cancelled,'chapter transition cancels underlines or readReviews handle')
local next_state={book=book,chapters=chapters,index=2,active=true,catalog_complete=true}
local next_doc=assert(owner:openChapter({state=next_state,body=coordinates.body('<p>丁戊己。</p>'),progress={immersive_style={page_transition='off'}}},
    {ready=function(d) next_state.document=d;session.active=next_state;return true end}))
local second=app:prepareChapterComments(next_doc)
sent[1].cb{reviews={{id='old',range='3-6',abstract='甲乙丙',content='旧章想法'}}}
eq(0,#second.rows,'late old passage response cannot populate reused reader')
sent[2].cb{reviews={{id='new',range='3-6',abstract='丁戊己',content='新章想法'}}}
eq('new',second.rows[1].id,'new chapter receives its own passage thought')
eq(1,#next_doc.widget:getCommentUnderlines(),'new chapter gets its verified underline')
eq(false,first:current(),'previous document comment owner is invalid after handoff')
next_doc:close()
eq(false,second:current(),'closing reader invalidates passage comment owner')
return n
