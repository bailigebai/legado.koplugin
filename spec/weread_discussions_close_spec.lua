package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local resumed,callback,cancelled=0,nil,false
local state={book={id='test-local',remote_id='test-remote',source_id='weread'},index=1,
    chapters={{uid='test-chapter',remote_uid='7',title='fixture'}},active=true}
local doc={reading_state=state,backend='immersive',closed=false,
    widget={page={at_end=false},setChapterDiscussions=function() end},pauseReading=function() return true end,
    resumeReading=function() resumed=resumed+1;return true end}
state.document=doc
local app=App.new{weread_auth={session=function() return {vid='test-account'} end},
    weread_client={chapterDiscussions=function(_,_,_,fn)
        callback=fn;return {cancel=function() cancelled=true end}
    end},reader_session={active=state}}
app.presenter=Presenter.new{ui_manager=h.ui,app=app}
local screen=app:openChapterDiscussions(doc)
local discussions=doc.chapter_discussions
screen:onClose()
eq(false,screen.alive,'actual LibraryScreen closes before its deferred Back callback')
eq(true,cancelled,'screen close immediately cancels pending review request')
callback{reviews={{review={id='r',content='fixture'},likesCount=12}}}
h:drain()
eq(nil,discussions.panel_widget,'late callback cannot resurrect a closed screen')
eq(0,#discussions.rows,'closed load rejects reply during deferred Back gap')
eq(1,resumed,'deferred Back resumes the original reader once')
local second=app:openChapterDiscussions(doc)
eq(true,second.alive,'cancelled panel can be reopened normally')
local active_handle=callback
screen:onClose()
eq(second,discussions.panel_widget,'old screen close cannot remove a newer screen')
active_handle{reviews={{review={id='new',content='new fixture'},likesCount=1}}}
local changed=discussions.panel_widget
eq(true,changed.alive,'current reply can refresh the live panel')
changed:onClose();h:drain()
eq(2,resumed,'a refreshed live panel resumes reading on close')
eq(nil,discussions.panel_widget,'refreshed live panel disposes current controller link')
return count
