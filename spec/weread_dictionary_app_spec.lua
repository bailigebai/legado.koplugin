require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local account,opened,guard,paused,cancelled='a',0,nil,0,0
local auth={session=function() return {vid=account} end}
local state={book={id='b',source_id='weread',weread_account_id='a'}}
local doc={backend='immersive',reading_state=state,pauseReading=function() paused=paused+1;return true end}
state.document=doc
local session={active=state}
local presenter={showDictionary=function(_,client,word,document,is_current)
    opened=opened+1;guard=is_current
    return {cancel=function() cancelled=cancelled+1 end}
end}
local app=App.new{weread_auth=auth,weread_client={auth=auth},reader_session=session,presenter=presenter}
local owner=app:openDictionary('《纽约时报》',doc)
eq(1,opened,'current immersive document can open a dictionary lookup')
eq(1,paused,'dictionary pauses reading time before opening')
eq(owner,doc.dictionary_lookup,'document owns cancellation at detach/close')
eq(true,guard(),'current document and account accept response')
state.document={};eq(false,guard(),'a replacement document rejects late reply')
state.document=doc;account='b';eq(false,guard(),'account switch rejects late reply')
local result,err=app:openDictionary('词',doc)
eq(nil,result,'book from another account cannot query as the new account')
eq('AUTH_ERROR',err.code,'account mismatch is actionable')
account='a';app:openDictionary('另一个词',doc)
eq(1,cancelled,'new word closes previous lookup owner')
doc.backend='native';eq(false,app:openDictionary('词',doc),'native reader retains existing behavior')
doc.backend='immersive';state.book.source_id='source'
eq(false,app:openDictionary('词',doc),'ordinary sources never call WeRead dictionary')
return count
