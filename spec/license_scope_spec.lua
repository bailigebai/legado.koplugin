require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Storage=require('legado.lib.storage')
local store=assert(Storage.new{sqlite_loader=function() end,
    fs={read=function() end,atomicWrite=function() return true end}})
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
    eq('解锁阅读小票与阅读回顾',dialog.title,'all locked entry points prompt for the same short key')
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

-- Free actions must never even consult the licensing service.
app.license={isAuthorized=function() error('free feature queried licensing') end}
local shelf=app:openBookshelf()
for i=1,7 do assert(shelf:add{id='b'..i,source_id='s',name='书'..i}) end
eq(7,#store:listShelf(),'unlicensed shelf accepts more than five books')
local detail=app:createBookDetail({id='b8',source_id='s',name='书8'})
assert(detail:addToShelf())
assert(app:addReaderToShelf({book={id='b9',source_id='s',name='书9'}}))
eq(9,#store:listShelf(),'detail and reader add-to-shelf are also unrestricted')
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
