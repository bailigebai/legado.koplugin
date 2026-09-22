require('library_screen_stub')
local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local function has(value,part,m) eq(true,value:find(part,1,true)~=nil,m) end
local Storage=require('legado.lib.storage')
local storage=Storage.new{sqlite_loader=function() return nil end,
    fs={read=function() return nil end,atomicWrite=function() return true end}}
local book={id='review-book',name='测试小说',author='测试作者',source_id='s',cover_url='https://example.test/cover.jpg'}
local chapters={}; for i=1,4 do chapters[i]={uid='c'..i,index=i,title='第'..i..'章'} end
storage:replaceChapters(book.id,chapters)
local Presenter=require('legado.ui.presenter')
local settings=require('legado.lib.settings').new({})
local presenter=Presenter.new{app={storage=storage,settings=settings,isLicensed=function() return true end},ui_manager={show=function() end,close=function() end}}
local view={kind='book_detail',book=book,info={author='完整作者'},alive=true}
local receipt=presenter:_readingReceipt(view)
eq(book.cover_url,receipt.reading_model.book.cover_url,'receipt requests the actual book cover')
eq('完整作者',receipt.reading_model.book.author,'receipt reuses fetched book details')
eq(0,receipt.reading_model.seconds,'unread book has an empty state')
storage:putProgress{book_id=book.id,book_snapshot=book,chapter_index=2,chapter_title='第二章',fraction=.5,reading_seconds=3661,updated_at=1700000000,catalog_complete=true,chapter_count=4}
receipt=presenter:_readingReceipt(view)
eq('第二章',receipt.reading_model.chapter_title,'receipt shows the saved chapter')
eq(3661,receipt.reading_model.seconds,'receipt shows cumulative reading time')
has(receipt.reading_model.progress_text,'37.5%','receipt computes whole-book progress instead of chapter-only fraction')
eq(nil,receipt.actions,'receipt has no persistent footer navigation')
local style_ids={'classic','simple','calendar','bookshop','boarding','library','cinema','postcard','newspaper',
    'exhibition','passport','contact','archive','timeline','bookmark'}
local style_names={'阅读票据','封面进度卡','日历胶片','书店结账单','阅读登机牌','图书馆借阅卡','影院票根','阅读明信片','阅读日报',
    '展览入场券','阅读护照','胶片联系表','阅读档案','阅读时间轴','极简书签'}
for i,id in ipairs(style_ids) do
    local old=presenter.receipt_widget
    local picker=old.on_edit('style')
    eq(15,#picker.item_table,'all fifteen styles are reachable in the picker')
    eq(style_names[i],picker.item_table[i].text,'picker gives each style its own name')
    picker.item_table[i].callback()
    eq(id,settings:get('receipt_style'),'menu choice saves its own id')
    eq(id,presenter.receipt_widget.style,'menu rebuilds receipt in selected style')
    eq(book.id,presenter.receipt_widget.reading_model.book.id,'style switch keeps selected book')
    eq(true,old.closed,'style replacement closes the old receipt')
end
local review=presenter:_readingReview(view)
eq('阅读回顾',review.title,'receipt switches to review for same book')
review.on_back()
eq('detail',presenter.library_subpage,'review back returns directly to book details')

local Session=require('legado.lib.reader_session')
local now=100
os.time=function() return now end
local session=Session.new{storage=storage,cache={},ui={}}
local state={active=true,book={id='first-read',source_id='s'},chapters=chapters,index=1,started_at=90,catalog_complete=true}
eq(true,session:_save(state,{getProgressFraction=function() return .25 end}),'first save works when no previous progress exists')
eq(10,storage:getProgress('first-read').reading_seconds,'first session accumulates elapsed time')
now=105
session:_save(state,{getProgressFraction=function() return .5 end})
eq(15,storage:getProgress('first-read').reading_seconds,'repeated flush adds only new elapsed time')
eq(4,storage:getProgress('first-read').chapter_count,'saved progress retains known catalog size')
eq(true,storage:getProgress('first-read').catalog_complete,'saved progress distinguishes complete and partial catalogs')
local doc={getProgressFraction=function() return .5 end}
state.document=doc
session.active=state
local callbacks=session:_callbacks(state)
eq('function',type(callbacks.pause),'reading timer supports suspend')
now=110; callbacks.pause(doc)
now=200; callbacks.flush(doc)
eq(20,storage:getProgress('first-read').reading_seconds,'sleep time is excluded from cumulative reading')
callbacks.resume(doc)
now=210; callbacks.close(doc)
eq(30,storage:getProgress('first-read').reading_seconds,'reading timer resumes after wake')

-- Native close destroys the document before its final FlushSettings event.
local local_reader={document={info={progress=.4}},handleEvent=function() end}
local_reader.rolling={getLastPercent=function() return local_reader.document.info.progress end}
local closes=0
local_reader.onClose=function(self)
    closes=closes+1
    self.document=nil
    self:onFlushSettings()
end
local Adapter=require('legado.lib.koreader_reader_ui')
local adapter=Adapter.new{ReaderUI={showReader=function(_,_,_,_,_,ready) ready(local_reader) end}}
local App=require('legado.ui.app')
local app=App.new{storage=storage,reader_session={ui=adapter,close=function() end},
    fs={lfs={attributes=function() return {mode='file'} end}}}
now=220
local local_doc=app:startReading({id='local-record',name='本地书',source_id='local',is_local=true,local_path='/books/test.epub'})
now=230;local_reader:handleEvent{handler='onSuspend'}
now=500;local_reader:handleEvent{handler='onResume'}
now=510
local closed=pcall(local_reader.onClose,local_reader)
eq(true,closed,'local close survives the native post-close FlushSettings event')
eq(20,storage:getProgress('local-record').reading_seconds,'local timing excludes sleep and survives close')
eq(.4,storage:getProgress('local-record').fraction,'local close saves progress before the document disappears')
local_reader:onClose()
eq(1,closes,'repeated close cannot destroy the native document twice')
return count
