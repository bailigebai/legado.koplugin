package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Adapter=require('legado.lib.koreader_reader_ui')
local App=require('legado.ui.app')
local count=0
local function eq(expected,actual,why) count=count+1;A.equal(expected,actual,why) end
-- Execute the official host registration contract: it owns widget.ui and view.
local source=assert(io.open((os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader')..'/frontend/apps/reader/modules/readerview.lua','rb'))
local code=source:read('*a');source:close()
local first=assert(code:find('function ReaderView:registerViewModule(',1,true))
local last=assert(code:find('function ReaderView:resetLayout(',first,true))
local native_view={};local register=assert(loadstring(code:sub(first,last-1)))
setfenv(register,{ReaderView=native_view,print=print});register()
local pending,opened,zone,lookups,visible=nil,nil,nil,0,true
local reader={document={file='chapter.html',getPageMargins=function() return {right=18} end,
    findAllText=function(_,quote,case,context,hits,regex)
        lookups=lookups+1
        eq(false,case,'native comment lookup preserves exact case')
        eq(2,hits,'native lookup stops after ambiguity is detected')
        eq(false,regex,'native quote lookup never treats external text as a regex')
        return {{start='xp-start',['end']='xp-end',matched_text=quote}}
    end,
    getScreenBoxesFromPositions=function() return visible and {{x=100,y=100,w=100,h=24}} or {} end},
    view={view_modules={},registerViewModule=native_view.registerViewModule},
    registerTouchZones=function(_,zones) zone=zones[1] end,
    unRegisterTouchZones=function() zone=nil end,
    onClose=function() end}
reader.view.ui=reader
reader.highlight={selected_text={text='庄周梦蝶'},onClose=function() end,
    addToHighlightDialog=function(self,key,fn) self[key]=fn end,
    removeFromHighlightDialog=function(self,key) self[key]=nil end}
local adapter=Adapter.new{ReaderUI={showReader=function(_,_,_,_,_,ready) ready(reader) end},
    on_chapter_comments=function(_,range) opened=range;return true end}
local doc=assert(adapter:openDocument('chapter.html',{weread=true}))
local state={book={id='b',source_id='weread',remote_id='remote'},index=1,
    chapters={{uid='c',remote_uid='7',title='章'}},document=doc}
doc.reading_state=state
local app=App.new{reader_session={active=state,cache={readBody=function()
    return require('legado.lib.weread_text_coordinates').body('<p>庄周梦蝶。</p>') end}},
    weread_client={chapterComments=function(_,_,_,cb) pending=cb end}}
app:prepareChapterComments(doc)
pending({reviews={{id='one',range='3-7',abstract='庄周梦蝶',content='评论'},
    {id='unlocated',range='999-1000',abstract='庄周梦蝶',content='错误范围'}}})
eq('function',type(doc.setChapterComments),'native reader accepts verified paragraph comments')
while #h.tasks>0 do local task=table.remove(h.tasks,1);if task.delay==.01 then task.fn() end end
local module=reader.view.view_modules and reader.view.view_modules.legado_comments
eq(true,module~=nil,'native reader registers its host view module')
local targets=module:getTargets()
eq(1,#targets,'only a verified unique visible native quote receives a marker')
eq(true,targets[1].w>=36,'native comment marker has a usable touch target')
zone.handler{pos={x=targets[1].x+1,y=targets[1].y+1}}
eq('3-7',opened,'native paragraph marker opens the matching comment range')
eq(1,lookups,'unverified row never performs a native position search')
visible=false
eq(0,#module:getTargets(),'native page change never keeps off-page comment targets')
reader.highlight['12_legado_comments'](reader.highlight).callback()
eq('3-7',opened,'native selected text offers its corresponding paragraph comments')
local old_button=reader.highlight['12_legado_comments'](reader.highlight)
module:setRows({{range='later',position={paragraph=1,char=1,last_char=4},abstract='庄周梦蝶'}})
local delayed_lookup=module.job
reader:onClose()
eq(nil,reader.highlight['12_legado_comments'],'native comment selection action is removed on close')
opened=nil;old_button.callback()
eq(nil,opened,'old chapter selection action cannot reopen comments after close')
eq(nil,zone,'native comment tap zone is removed on close')
eq(0,#h.tasks,'closing the native chapter cancels its queued comment lookup')
local before_dirty=h.dirty
delayed_lookup()
eq(1,lookups,'a late comment lookup never searches the closed native document')
eq(before_dirty,h.dirty,'a late comment lookup never repaints the closed native chapter')
reader:onClose()
eq(0,#h.tasks,'repeated native close does not reschedule comment work')
return count
