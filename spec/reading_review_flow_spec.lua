require('library_screen_stub')
local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local Storage=require('legado.lib.storage')
local fail=false
local storage=Storage.new{sqlite_loader=function() return nil end,
    fs={read=function() end,atomicWrite=function() if fail then return nil,{code='STORAGE_ERROR'} end; return true end}}
for i=1,8 do storage:putProgress{book_id='book'..i,book_snapshot={id='book'..i,name='书'..i},
    reading_seconds=i*60,reading_daily={['2026-09-01']=i*60},chapter_index=1,chapter_count=4,catalog_complete=true} end
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local app=App.new{storage=storage,license={isAuthorized=function() return true end}}
local presenter=Presenter.new{app=app,ui_manager={show=function() end,close=function() end}}
app.show=function(view) return presenter:show(view) end
local view=app:openReadingReview()
local screen=presenter.library_widget
eq('overview',screen.reading_model.kind,'global review opens cumulative dashboard')
eq(2160,screen.reading_model.total_seconds,'global view aggregates all books')
eq(3,#screen.categories,'review has three reference tabs')
screen.categories[2].callback()
screen=presenter.library_widget
eq('daily',screen.reading_model.kind,'daily tab opens calendar')
local year,month=screen.reading_model.year,screen.reading_model.month
screen.reading_model.on_period_change(-1)
screen=presenter.library_widget
eq(month==1 and 12 or month-1,screen.reading_model.month,'month arrow changes calendar')
screen.categories[3].callback()
screen=presenter.library_widget
eq(6,#screen.reading_model.records,'books tab displays at most three by two cards')
eq(2,screen.page_count,'eight books have two pages')
screen.on_next()
screen=presenter.library_widget
eq(2,#screen.reading_model.records,'last page contains remaining books')
local selected=screen.reading_model.records[1].book
screen.reading_model.on_book(selected)
screen=presenter.receipt_widget
eq('receipt',screen.reading_model.kind,'book card opens that book receipt')
eq(selected.id,screen.reading_model.book.id,'receipt never switches to another book')
screen.reading_model.on_rating(4)
screen=presenter.receipt_widget
eq(4,screen.reading_model.rating,'rating redraws same receipt after saving')
screen.reading_model.on_status('paused')
eq('paused',storage:getProgress(selected.id).reading_status_override,'status persists')
fail=true
presenter.receipt_widget.reading_model.on_status('finished')
eq('paused',presenter.receipt_widget.reading_model.status,'failed status write keeps old receipt')
fail=false
presenter.receipt_widget.on_back()
screen=presenter.library_widget
eq('books',screen.reading_model.kind,'receipt returns to originating tab')
eq(2,screen.page,'receipt returns to originating page')
screen.categories[2].callback()
eq(month==1 and 12 or month-1,presenter.library_widget.reading_model.month,'calendar month survives tab and receipt navigation')
local detail={kind='book_detail',book={id='book1',name='书1'},alive=true}
presenter:_readingReview(detail)
eq(60,presenter.library_widget.reading_model.total_seconds,'detail review only includes current book')
presenter.library_widget.on_back()
eq('detail',presenter.library_subpage,'detail review returns to full detail screen')
local native={document={getPageCount=function() return 100 end},getCurrentPage=function() return 40 end}
local adapter=require('legado.lib.koreader_reader_ui').new{ReaderUI={showReader=function(_,_,_,_,_,ready) ready(native) end}}
local proxy=adapter:openDocument('/books/book.epub')
local page,total=proxy:getPagePosition()
eq(40,page,'local history reads actual native page')
eq(100,total,'local history reads actual native total')
presenter:_readingResult(nil,{code='STORAGE_ERROR',details={stage='reader_open',reason='reader_ui_startup',location='reader_chrome.lua:12'}},detail)
eq(true,detail._reading_status:find('界面初始化失败',1,true)~=nil,'startup error is explained in plain language')
local more=presenter.library_widget.actions[2].callback()
for _,item in ipairs(more.items) do
    if item.text=='阅读诊断' then
        local diagnostic=item.callback()
        eq(true,diagnostic.text:find('reader_chrome.lua:12',1,true)~=nil,'diagnostic retains safe source location')
        eq(true,diagnostic.text:find('尚未确认文件损坏',1,true)~=nil,'startup errors are not misrepresented as bad format')
    end
end
return count
