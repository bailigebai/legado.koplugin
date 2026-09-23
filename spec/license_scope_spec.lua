require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Storage=require('legado.lib.storage')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local License=require('legado.lib.license')
local authorized=false
local license={isAuthorized=function() return authorized end,normalizeKey=License.normalizeKey,
    activate=function() authorized=true;return true end}
function license:activateAsync(key,callback)
    callback(self:activate(key))
    return {cancel=function()end}
end
local store=assert(Storage.new{license=license,sqlite_loader=function() end,
    fs={read=function() end,atomicWrite=function() return true end}})
local app=App.new{storage=store,license=license}
local shown={}
local ctor={new=function(_,opts) opts.getInputText=function() return 'abcd-efgh-jkmn' end;return opts end}
local p=Presenter.new{app=app,menu=ctor,info_message=ctor,input_dialog=ctor,
    ui_manager={show=function(_,w) shown[#shown+1]=w end,close=function() end}}
app.show=function(view) return p:show(view) end
local book={id='b1',source_id='s',name='测试小说'}
assert(store:putProgress{book_id=book.id,book_snapshot=book,reading_seconds=60})
local reads=0
local original=store.getProgress
store.getProgress=function(self,...) reads=reads+1;return original(self,...) end

-- Every display path must stop before collecting private review/receipt data.
for _,entry in ipairs{
    function() app:openReadingReview() end,
    function() app:openReadingReview(nil,{book=book}) end,
    function() p:_readingReview({kind='book_detail',book=book}) end,
    function() app:openCurrentReceipt({book=book}) end,
    function() p:_readingReceipt({kind='book_detail',book=book}) end,
} do
    local before=reads
    entry()
    local dialog=shown[#shown]
    eq('密钥激活',dialog.title,'all locked entry points prompt for the same short key')
    eq(before,reads,'locked display does not read progress data')
    eq(nil,p.receipt_widget,'locked entry does not render a receipt')
    eq(nil,p.library_widget,'locked entry does not render review data')
    dialog.buttons[1][1].callback()
end

local activate=license.activate
license.activate=function() return nil,'invalid_signature' end
p:_readingReview({kind='reading_review'})
shown[#shown].buttons[1][2].callback()
eq('授权失败',shown[#shown].title,'failed activation is reported')
eq(nil,p.library_widget,'failed activation never opens review data')
eq(false,authorized,'failed activation leaves both features locked')
license.activate=activate

-- A successful activation continues the action that originally prompted it.
p:_readingReview({kind='reading_review'})
shown[#shown].buttons[1][2].callback()
eq('overview',p.library_widget.reading_model.kind,'activation continues to review data')
eq(60,p.library_widget.reading_model.total_seconds,'existing reading history remains intact')
p:_readingReceipt({kind='reading_receipt',book=book})
eq('receipt',p.receipt_widget.reading_model.kind,'the same activation unlocks the receipt')
p:_closeReceipt();p:_hideLibrary()
app.license=nil
p:_readingReview({kind='reading_review'})
eq('授权服务尚未初始化。',shown[#shown].text,'missing license service does not unlock review')
p:_readingReceipt({kind='reading_receipt',book=book})
eq('授权服务尚未初始化。',shown[#shown].text,'missing license service does not unlock receipt')

-- Admission is checked before writing, across shelf, details and both readers.
authorized=false;app.license=license
local shelf=app:openBookshelf()
for i=1,5 do assert(shelf:add{id='b'..i,source_id='s',name='书'..i}) end
local sixth={id='b6',source_id='s',name='书6'}
local added,err=shelf:add(sixth)
eq(nil,added,'sixth book is not written without a key')
eq('LICENSE_REQUIRED',err.code,'shelf reports the key requirement')
local detail=app:createBookDetail(sixth)
added,err=detail:addToShelf()
eq(nil,added,'details cannot bypass the five-book limit')
eq('LICENSE_REQUIRED',err.code,'details use the same admission rule')
assert(shelf:add(book))
eq(5,#store:listShelf(),'re-adding an existing book does not consume a slot')
local original_list=store.listShelf
store.listShelf=function() return nil,{code='STORAGE_ERROR'} end
added,err=shelf:add(sixth)
eq(nil,added,'failed count never grants admission')
eq('STORAGE_ERROR',err.code,'count error remains distinct from licensing')
store.listShelf=original_list

local function add_from_details()
    p:_detail(detail)
    for _,action in ipairs(p.library_widget.item_table) do
        if action.text=='更多' then action.callback();break end
    end
    for _,action in ipairs(shown[#shown].item_table) do
        if action.text=='加入书架' then return action.callback() end
    end
    error('missing add-to-shelf action')
end
add_from_details()
local dialog=shown[#shown]
eq('密钥激活',dialog.title,'detail button opens activation instead of a storage failure')
eq(true,dialog.description:find('5 本',1,true)~=nil,'dialog explains the free allowance')
dialog.buttons[1][1].callback()
eq(5,#store:listShelf(),'cancelling activation never adds the book')
app:addReaderToShelf({book=sixth})
eq('密钥激活',shown[#shown].title,'reader add opens the same activation dialog')
license.activate=function() return nil,'save_failed' end
shown[#shown].buttons[1][2].callback()
eq(5,#store:listShelf(),'failed receipt save never adds the book')
license.activate=activate
app:addReaderToShelf({book=sixth})
dialog=shown[#shown]
dialog.buttons[1][2].callback()
dialog.buttons[1][2].callback()
eq(6,#store:listShelf(),'successful activation resumes adding exactly once')
eq('书6',store:getBook('b6').name,'activation resumes the intended book')

-- Existing oversized shelves stay readable after loss of authorization.
authorized=false
eq(6,#app:openBookshelf():page(1).items,'existing books remain visible')
assert(shelf:add(sixth))
added,err=shelf:add{id='b7',name='书7'}
eq(nil,added,'an oversized existing shelf cannot grow without a key')
assert(shelf:remove('b5'));assert(shelf:remove('b6'))
assert(detail:addToShelf())
eq(5,#store:listShelf(),'removing books releases slots')
add_from_details()
eq('已加入书架',detail._notice,'re-adding from details needs no key')
detail=app:createBookDetail({id='b7',name='书7'})
add_from_details()
shown[#shown].buttons[1][2].callback()
eq(6,#store:listShelf(),'detail activation resumes its add action')

-- The adapter path (SQLite on Kindle) enforces the same limit before putBook.
authorized=false
local writes=0
local backend={getBook=function(_,id) return store:getBook(id) end,
    listBooks=function() return store:listShelf() end,
    putBook=function() writes=writes+1;return true end}
local sql_store=Storage.new{backend=backend,license=license}
added,err=sql_store:createBook{id='b8',name='书8'}
eq('LICENSE_REQUIRED',err.code,'SQLite adapter also rejects a new book over the limit')
eq(0,writes,'rejected additions never reach SQLite')
assert(sql_store:createBook(book))
eq(1,writes,'existing SQLite records can still be updated')
authorized=true
local restarted=Storage.new{backend=backend,license=license}
assert(restarted:createBook{id='b8',name='书8'})
eq(2,writes,'a fresh storage instance accepts an already authorized device')
authorized=false
backend.getBook=function() return nil,{code='STORAGE_ERROR'} end
added,err=sql_store:createBook{id='b8',name='书8'}
eq('STORAGE_ERROR',err.code,'failed identity lookup never falls through to insertion')
eq(2,writes,'read errors preserve the database')

-- Reading, downloads and native statistics stay free, even with a full shelf.
app.license={isAuthorized=function() error('free feature queried licensing') end}
local called=0
app.reading_hook=function() called=called+1;return true end
app.download_hook=function() called=called+1;return true end
app:startReading(book);app:startDownload(book)
app.native_statistics={onShowTimeRange=function() called=called+1;return true end}
app:openNativeStatistics()
eq(3,called,'reading, downloads and KOReader statistics remain free')
app:openSettings()
eq(60,store:getProgress(book.id).reading_seconds,'free use preserves history before activation')
return n
