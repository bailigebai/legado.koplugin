package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local App=require('legado.ui.app')
local Owner=require('legado.lib.koreader_reader_ui')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local sent={}
local auth={session=function() return {vid='account-a'} end}
local session={}
local app=App.new{weread_auth=auth,reader_session=session,weread_client={chapterDiscussions=function(_,book,chapter,callback)
    local row={book=book,chapter=chapter,callback=callback};sent[#sent+1]=row
    return {cancel=function() row.cancelled=true end}
end}}
local opened,next_chapter,cancel_before_text=0,0,nil
local owner=Owner.new{ui_manager=h.ui,on_chapter_end=function(doc) return app:loadChapterDiscussions(doc) end,
    on_chapter_discussions=function(doc) opened=opened+1;return true end}
local book={id='local',remote_id='remote',source_id='weread'}
local chapters={{uid='one',remote_uid='7',title='第一章'},{uid='two',remote_uid='8',title='第二章'}}
local first_state={book=book,chapters=chapters,index=1,active=true,catalog_complete=true}
local function events(state)
    return {ready=function(doc) state.document=doc;session.active=state;return true end,
        chapter=function(index)
            next_chapter=index
            cancel_before_text=sent[1].cancelled
            return {cancel=function() end}
        end,
        close=function(doc) if doc.chapter_discussions then doc.chapter_discussions:close() end end}
end
local first=assert(owner:openChapter({state=first_state,body='<p>很短的末页。</p>',
    progress={immersive_style={page_transition='off'}}},events(first_state)))
eq(1,#sent,'real immersive adapter triggers exactly one lazy chapter-end request')
local first_controller=first.chapter_discussions
eq(true,first_controller.loading,'current immersive document owns pending request')
local target=first.widget:getChapterDiscussionTarget()
first.widget:onTap(nil,{pos={x=target.x+target.w/2,y=target.y+target.h/2}})
eq(1,opened,'real adapter passes card action to immersive owner')
first:resumeReading()
first.widget:nextPage()
eq(true,cancel_before_text,'chapter switch cancels optional review request before requesting next text')
eq(true,sent[1].cancelled,'chapter switch propagates cancellation to network handle')
eq(2,next_chapter,'pending popular review request does not prevent next chapter command')
local second_state={book=book,chapters=chapters,index=2,active=true,catalog_complete=true}
local second=assert(owner:openChapter({state=second_state,body='<p>第二章的末页。</p>',
    progress={immersive_style={page_transition='off'}}},events(second_state)))
eq(first.widget,second.widget,'chapter handoff reuses the immersive window')
eq(2,#sent,'new chapter receives its own request')
eq('8',sent[2].chapter,'new request belongs to the second remote chapter')
eq(false,first_controller:current(),'old document controller is invalid after handoff')
sent[1].callback({reviews={{review={id='old',content='旧章想法'},likesCount=999}}})
eq(0,#second.chapter_discussions.rows,'late old review response cannot appear on reused immersive window')
sent[2].callback({reviews={{review={id='new',content='新章想法'},likesCount=12}}})
eq(12,second.chapter_discussions.rows[1].likes_count,'new chapter accepts its own popular review')
local third=assert(owner:openChapter({state={book=book,chapters=chapters,index=1,active=true},
    body='<p>再回第一章。</p>',progress={immersive_style={page_transition='off'}}},{ready=function(doc)
        doc.reading_state.document=doc;session.active=doc.reading_state;return true end}))
eq(false,second.chapter_discussions:current(),'replacing reader invalidates completed controller')
third:close()
eq(nil,package.loaded['apps/reader/readerui'],'chapter discussions keep the independent reader backend')
return count
