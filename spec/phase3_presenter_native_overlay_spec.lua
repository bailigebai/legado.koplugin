local h=require('phase3/leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local function noop() end
-- The shared KOReader harness intentionally leaves IconWidget empty for
-- native widget tests; the side TOC uses Menu's icon page controls.
local Widget=require('ui/widget/widget')
package.loaded['ui/widget/iconwidget']=Widget:extend{getSize=function() return {w=24,h=24} end}
package.loaded.device._UIManagerReady=noop
package.loaded['ui/time'].now=function() return 0 end
package.loaded.dbg.v=noop
G_reader_settings.isFalse=function(_,key) return key=='flash_ui' end
h.screen.beforePaint,h.screen.afterPaint=noop,noop
h.screen.getDPI=function() return 300 end
package.loaded['ui/uimanager']=nil
local ui=require('ui/uimanager')
ui.scheduleIn=h.ui.scheduleIn;ui.unschedule=h.ui.unschedule
local paused,resumed=0,0
local reader=assert(require('legado.ui.leko_reader').new{book={id='b',name='Book'},chapter={uid='c',title='Chapter'},
    body='<p>'..string.rep('正文内容。',200)..'</p>',ui_manager=ui,
    callbacks={pause=function() paused=paused+1;return true end,resume=function() resumed=resumed+1;return true end,
        flush=function() return true end}})
local doc={backend='immersive',widget=reader,reading_state={book={id='b',name='Book'}},
    pauseReading=function() return reader:pauseReading() end,resumeReading=function() return reader:resumeReading() end,
    flushProgress=function() return reader:flushProgress() end,
    getReadingContext=function() return {chapter_title='Live chapter',chapter_page=3,chapter_pages=nil,chapter_fraction=.42,
        chapter_remaining=27,book_remaining=81} end}
local storage={getProgress=function() return {chapter_title='Stale',chapter_pages=999,fraction=.1} end}
local Presenter=require('legado.ui.presenter')
local p=Presenter.new{ui_manager=ui,app={reader_session={active={document=doc}},storage=storage,isLicensed=function() return true end}}
ui:show(reader)
local Container=require('ui/widget/container/inputcontainer')
local first=p:_show(Container:new{})
local second=p:_show(Container:new{})
eq(1,paused,'real independent reader pauses only once for nested overlays')
ui:close(second);eq(0,resumed,'real CloseWidget event does not resume before removal')
h:drain();eq(0,resumed,'remaining real overlay keeps reading paused')
ui:close(first);h:drain();eq(1,resumed,'actual window stack restoration resumes independent reader')
local Receipt=require('legado.ui.receipt_screen')
local new_receipt,receipt_options=Receipt.new,nil
Receipt.new=function(options) receipt_options=options;return new_receipt(options) end
local receipt=p:_readingReceipt({kind='reading_receipt',book={id='b',name='Book'},document=doc})
eq('Live chapter',receipt_options.reading_model.chapter_title,'receipt uses independent live chapter context')
eq(3,receipt_options.reading_model.chapter_page,'receipt uses independent current page')
eq(nil,receipt_options.reading_model.chapter_pages,'unknown page total remains unknown')
eq(.42,receipt_options.reading_model.chapter_fraction,'receipt uses live character progress')
eq(27,receipt_options.reading_model.chapter_remaining,'receipt keeps measured remaining-time context')
eq(false,receipt_options.with_background,'current-book receipt remains transparent over independent reader')
eq(2,paused,'opening a receipt pauses reading')
local child=p:_show(Container:new{})
ui:close(child);h:drain();eq(1,resumed,'receipt beneath child prevents early resume')
receipt:onClose();h:drain();eq(2,resumed,'closing actual receipt returns to the novel')
eq(reader,ui:getTopmostVisibleWidget(),'receipt close exposes actual independent reader')
eq(nil,p.backdrop,'reader overlays never create a shelf backdrop above the novel')
local state=doc.reading_state
state.source,state.chapters,state.index,state.catalog_complete={id='s'},{{uid='c',title='Chapter'}},1,true
local session=p.app.reader_session
session.loadCatalog=function(_,_,callback) callback(state.chapters,nil,{catalog_complete=true});return {cancel=noop} end
local home=0
local app=require('legado.ui.app').new{reader_session=session,storage=storage,scheduler=ui,license={isAuthorized=function() return true end},show=function(view) return p:show(view) end}
app.openHome=function() home=home+1 end;p.app=app
local catalog=app:openReadingCatalog(state,doc)
eq(doc,catalog.document,'catalog remembers the independent reader underneath')
local catalog_widget=p.library_widget
catalog_widget:onClose();h:drain()
eq(reader,ui:getTopmostVisibleWidget(),'real catalog back returns directly to the novel')
eq(0,home,'catalog back does not navigate to the shelf')
eq(3,resumed,'catalog back resumes independent reading')
local other=p:_readingReceipt({kind='reading_review',document=doc},{id='other',name='Other book'})
eq('Stale',receipt_options.reading_model.chapter_title,'another book receipt never borrows the current novel chapter')
other:onClose();h:drain()
reader:close();h:drain()
return n
