local h=require('native_library_harness').install()
local A=require('assertions')
local count=0
local function eq(want,got,why) count=count+1;A.equal(want,got,why) end
local manager={file_chooser={path='/books'}}
local stack={manager}
local exposed,watch=0,false
local function top() return stack[#stack] end
h.ui.show=function(_,w) stack[#stack+1]=w end
h.ui.close=function(_,w)
    for i=#stack,1,-1 do if stack[i]==w then table.remove(stack,i) end end
    if w.onCloseWidget then w:onCloseWidget() end
    if watch and top()==manager then exposed=exposed+1 end
end
local queue={}
h.ui.scheduleIn=function(_,delay,fn) if delay==0 then queue[#queue+1]=fn end end
h.ui.unschedule=function() end
local function tick() local todo=queue;queue={};for _,fn in ipairs(todo) do fn() end end
local simple={new=function(_,v) return v end}
local restored
package.loaded['ui/widget/confirmbox']=simple
package.loaded['apps/filemanager/filemanager']={instance=manager}
manager.file_chooser.changeToPath=function(_,path) restored=path end
package.loaded['libs/libkoreader-lfs']={attributes=function() return 'file' end}
local Settings=require('legado.lib.settings')
local settings_data,setting_fail={},false
local settings=Settings.new{read=function() return settings_data end,write=function(data)
    if setting_fail then return nil,{code='STORAGE_ERROR'} end
    settings_data=data;return true
end}
local storage_fail=false
local storage=require('legado.lib.storage').new{sqlite_loader=function() end,
    fs={read=function() end,atomicWrite=function() if storage_fail then return nil,{code='STORAGE_ERROR'} end;return true end}}
local book={id='book',name='测试小说',author='作者'}
storage:putProgress{book_id=book.id,book_snapshot=book,chapter_index=1,chapter_count=3,reading_seconds=120}
local app=require('legado.ui.app').new{storage=storage,settings=settings,scheduler=h.ui,license={isAuthorized=function() return true end}}
local presenter=require('legado.ui.presenter').new{app=app,ui_manager=h.ui,menu=simple,input_dialog=simple,info_message=simple}
app.show=function(view) return presenter:show(view) end
local reader,closes,flushes=nil,0,0
local host={showFileManager=function() error('must not enter cache directory') end}
host.doShowReader=function(_,path,ready)
    reader={document={file=path,getPageCount=function() return 12 end},getCurrentPage=function() return 3 end,
        menu={tab_item_table={},setUpdateItemTable=function() end},
        onClose=function(self) closes=closes+1;h.ui:close(self);self.document=nil end}
    ready(reader);h.ui:show(reader)
end
host.showReader=function(self,path,_,_,_,ready) h.ui:scheduleIn(0,function() self:doShowReader(path,ready) end) end
local adapter=require('legado.lib.koreader_reader_ui').new{ReaderUI=host,
    on_exit=function() app:openBookshelf() end,
    on_review=function(doc) return app:openReadingReview(nil,doc) end,
    on_receipt=function(doc) return app:openCurrentReceipt(doc) end}
app.reader_session={ui=adapter,close=function() return true end}
app:openBookshelf();watch=true
presenter:_startReading(function(done)
    return adapter:openDocument('/cache/chapter.html',{ready=function(doc) doc.book=book;done(doc) end,
        flush=function() flushes=flushes+1 end})
end)
eq('reading_progress',presenter.library_view.kind,'plugin preparation surface exists before native launch')
tick()
eq(reader,top(),'ready hides preparation only after the reader is shown')
reader.menu.tab_item_table[1][4].callback()
eq('reading_review',presenter.library_view.kind,'toolbar opens review over the same reader')
presenter.library_widget:onClose();tick()
eq(reader,top(),'review Back restores the same reader')
reader.menu.tab_item_table[1][7].callback()
local ticket=presenter.receipt_widget
eq(ticket,top(),'current receipt floats above the reader')
eq(false,ticket.covers_fullscreen,'receipt leaves surrounding book visible')
eq(450,ticket.paper.dimen.w,'default receipt uses three quarters of the screen')
eq(1,flushes,'receipt flushes current reading progress')
ticket.options.on_edit('size')
top().item_table[1].sub_item_table[6].callback() -- width 80%
eq(480,presenter.receipt_widget.paper.dimen.w,'size menu rebuilds receipt at selected width')
presenter.receipt_widget.options.on_edit('style')
top().item_table[3].callback()
eq('calendar',presenter.receipt_widget.style,'style menu switches to calendar film')
ticket=presenter.receipt_widget
setting_fail=true;ticket.options.on_edit('style');top().item_table[2].callback()
eq(ticket,presenter.receipt_widget,'failed setting save preserves current receipt')
h.ui:close(top());h.ui:close(top());setting_fail=false
ticket.options.on_comment('');top().buttons[1][2].callback('喜欢这段故事')
eq('喜欢这段故事',storage:getProgress(book.id).reading_comment,'comment editor persists text')
ticket=presenter.receipt_widget
storage_fail=true;ticket.options.on_comment('');top().buttons[1][2].callback('无法保存')
eq(ticket,presenter.receipt_widget,'failed comment save keeps receipt open')
eq('喜欢这段故事',storage:getProgress(book.id).reading_comment,'failed comment save retains previous text')
h.ui:close(top());h.ui:close(top());storage_fail=false
ticket:onClose()
eq(reader,top(),'closing receipt restores the same reader without reopening')
-- Exercise the unchanged native close-then-file-manager flow against our instance hook.
local source=assert(io.open((os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader')..'/frontend/apps/reader/readerui.lua','rb'))
local code=source:read('*a');source:close()
local start=assert(code:find('function ReaderUI:onHome()',1,true))
local stop=assert(code:find('function ReaderUI:onReload()',start,true))
local native={};local chunk=assert(loadstring(code:sub(start,stop-1)));setfenv(chunk,{ReaderUI=native});chunk()
native.onHome(reader);tick()
eq(1,closes,'native return closes the document only once')
eq('bookshelf',presenter.library_view.kind,'native file-manager return reaches Legado shelf')
eq(0,exposed,'reading, review, receipt and return never expose cache FileManager')
eq(nil,adapter.current_document,'return releases the current document')
presenter.library_widget:onClose();tick()
watch=false;top().ok_callback()
eq('/books',restored,'confirmed exit restores the directory captured before reading')
return count
