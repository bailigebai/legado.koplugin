local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local App=require('legado.ui.app')
local values={immersive_reader=false};local write_failed=false
local settings={get=function(_,k) return values[k] end,all=function() return values end,
    set=function(_,k,v) if write_failed then return nil,{code='STORAGE_ERROR'} end;values[k]=v;return v end}
local book={id='b',source_id='s',name='Book'}
local state={book=book,source={id='s'},chapters={{uid='a',title='A'},{uid='b',title='B'}},index=2,
    catalog_complete=false,statistics_book_id='stable',active=true}
local closed,refreshed,layout,saved_count=0,0,0,0
local doc={backend='native',reading_state=state,getProgressFraction=function() return .375 end,
    flushProgress=function() return true end,close=function(self) closed=closed+1;self.closed=true;return true end}
state.document=doc
local next_options,complete
local session={active=state,ui={},open=function(_,source,b,chapters,index,options)
    eq(state.source,source,'switch reuses source');eq(book,b,'switch reuses book')
    eq(state.chapters,chapters,'switch reuses chapter list');eq(2,index,'switch keeps current chapter')
    next_options,complete=options,options.on_complete
    return {cancel=function() end}
end,close=function() closed=closed+1;return true end}
local storage={getBook=function() end,createBook=function(_,b) saved_count=saved_count+1;return b end,listShelf=function() return {} end}
local shown={}
local app=App.new{settings=settings,storage=storage,reader_session=session,show=function(v) shown[#shown+1]=v end}
eq('function',type(app.toggleImmersiveReader),'App exposes the mode-switch action')
app:toggleImmersiveReader(doc)
eq('immersive',next_options.backend,'native reader switches to independent backend')
eq(.375,next_options.restore_fraction,'switch preserves live fraction')
eq(false,next_options.catalog_complete,'switch preserves incomplete catalog')
eq('stable',next_options.statistics_book_id,'switch preserves whole-book identity')
eq(false,values.immersive_reader,'construction does not change persisted mode')
eq(0,closed,'construction keeps current reader open')
write_failed=true
local committed,err=next_options.before_commit()
eq(nil,committed,'preference failure prevents commit');eq('STORAGE_ERROR',err.code,'preference failure is explicit')
complete(nil,err);eq(false,values.immersive_reader,'failed switch retains mode')
eq(0,closed,'failed switch retains current reader')
write_failed=false
app:toggleImmersiveReader(doc);eq(true,next_options.before_commit(),'successful preference commits new mode')
complete({backend='immersive'})
doc.backend='immersive';doc.widget={showLayoutMenu=function() layout=layout+1;return true end}
doc.refreshAppearance=function() refreshed=refreshed+1;return true end
app:toggleImmersiveReader(doc)
eq('native',next_options.backend,'independent reader switches back to native')
eq(true,next_options.before_commit(),'saving false is a successful mode preference commit')
eq(false,values.immersive_reader,'reverse switch persists disabled mode');complete({backend='native'})
app.reader_mode_request={document={}}
local previous_options=next_options
app:toggleImmersiveReader(doc)
eq(false,next_options==previous_options,'a cancelled switch from an old document cannot block the current document')
complete({backend='native'})
session.ui.applyMarginPreset=function() error('independent reader touched native margins') end
session.ui.applyProgressBar=function() error('independent reader touched native footer') end
local view=app:openSettings(doc)
eq('function',type(view.on_toggle_reader),'reading settings switch modes through the App transaction')
eq(nil,view.on_margins,'independent reader has no native margin callback')
eq('function',type(view.on_layout),'independent settings expose the native-independent layout menu')
view.on_layout();eq(1,layout,'independent layout menu is called')
view.on_background_change();view.on_chrome_change();view.on_progress_change()
eq(3,refreshed,'independent appearance changes use the neutral proxy API')
local detail=app:openReaderBookInfo(doc)
eq(doc,detail.document,'book details retain their reader origin')
eq('function',type(detail._back),'book details can return to the novel')
eq(book,app:addReaderToShelf(doc),'trial reading can add the current book')
eq(1,saved_count,'add-to-shelf persists current book once')
storage.getBook=function() return book end
app:addReaderToShelf(doc);eq(1,saved_count,'adding an existing shelf book is idempotent')
doc.close=function() return nil,{code='STORAGE_ERROR'} end
local exited=app:exitReader(doc)
eq(nil,exited,'failed final progress save prevents explicit exit')
eq(0,closed,'failed exit never closes session')
doc.close=function(self) self.closed=true;closed=closed+1;return true end
app.reader_mode_request={document=doc}
app:exitReader(doc);eq(2,closed,'explicit shelf return closes proxy then session')
eq(nil,app.reader_mode_request,'explicit exit clears a cancelled mode switch')
local before=#shown
session.close=function() return nil,{code='STORAGE_ERROR'} end
eq(nil,app:exitReader(doc),'session save failure prevents a shelf transition')
eq(before,#shown,'failed session close leaves the current surface in place')
doc.closed=false
app:toggleImmersiveReader(doc)
local old_complete=complete
local new_doc={backend='native',reading_state=state,getProgressFraction=doc.getProgressFraction}
app:toggleImmersiveReader(new_doc)
local current_request=app.reader_mode_request
before=#shown
old_complete(nil,{code='STORAGE_ERROR',message='Late old failure'})
eq(before,#shown,'cancelled old switch completion cannot open a stale error overlay')
eq(current_request,app.reader_mode_request,'cancelled old completion cannot clear the new switch guard')
complete({backend='immersive'})
eq(nil,app.reader_mode_request,'current switch completion clears its own guard')
settings.set=function() return nil,{code='RECOVERY_REQUIRED'} end
app:toggleImmersiveReader(new_doc)
eq(true,next_options.before_commit(),'corrupt preferences do not block this session reader switch')
eq('immersive',session.preferred_backend,'session remembers temporary mode without overwriting settings')
complete({backend='immersive'})
return n
