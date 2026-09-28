require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local View=require('legado.ui.weread')
local count=0
local function eq(expected,actual,why) count=count+1;A.equal(expected,actual,why) end

local account='account-a'
local auth={session=function() return {vid=account} end,hasSession=function() return true end}
local progress_rows={{book_id='account-a-book-2',source_id='weread',
    updated_at=1700000010,chapter_index=6,chapter_count=10,fraction=0.5}}
local progress_error
local storage={listProgress=function() return progress_rows,progress_error end}
local view=View.new{auth=auth,storage=storage}
view.books={}
for index=1,18 do
    view.books[index]={id='account-a-book-'..index,remote_id='book-'..index,
        source_id='weread',name='书'..index,progress_percent=10,
        read_at=index==1 and 1700000000000 or index==2 and 1690000000000 or 0}
end
local first=view:page(1)
eq('book-2',first.items[1].remote_id,'recent plugin reading leads the WeRead hero')
eq(55,first.items[1].progress_percent,'local chapter position updates the displayed percentage')
eq('book-1',first.items[2].remote_id,'remote millisecond timestamp is normalized before sorting')
eq('book-1',view.books[1].remote_id,'display ordering does not rewrite the remote snapshot')
eq(5,#first.items,'hero page keeps one large card and four covers')
eq(12,#view:page(2).items,'second page keeps twelve covers')

progress_rows={}
eq('book-1',view:page(1).items[1].remote_id,'without local progress the remote shelf order remains')
view.books[1].read_at=0
eq('book-1',view:page(1).items[1].remote_id,
    'remote recent-list order survives missing timestamps on its first book')
progress_rows={{book_id='account-a-book-2',source_id='weread',updated_at=1600000000}}
eq('book-1',view:page(1).items[1].remote_id,
    'older local history cannot displace the remote recent-list order')
progress_rows=nil
progress_error={code='STORAGE_ERROR'}
local unavailable=view:page(1)
eq('book-1',unavailable.items[1].remote_id,'local history failure leaves remote covers available')
eq('STORAGE_ERROR',unavailable.progress_error.code,'history failure is explicit to the presenter')

account='account-b'
local other=View.new{auth=auth,storage=storage}
other.books={{id='account-b-book-2',remote_id='book-2',source_id='weread',name='其他账号',read_at=0}}
other.books[1].progress_percent=20
progress_rows={{book_id='account-a-book-2',source_id='weread',updated_at=1800000000,
    chapter_index=6,chapter_count=10,fraction=0.5}}
progress_error=nil
eq(20,other:page(1).items[1].progress_percent,'another account cannot inherit local reading history')

local app=App.new{storage=storage,weread_auth=auth}
eq(storage,app:openWeRead().storage,'app supplies local reading history to the WeRead shelf')

account='account-a'
progress_rows={{book_id='account-a-book-2',source_id='weread',updated_at=1700000010,
    chapter_index=6,chapter_count=10,fraction=0.5}}
local shown,opened={},nil
local presenter=Presenter.new{app={startWeReadReading=function(_,book,callback)
    opened=book.remote_id;callback({backend='native'})
end},ui_manager={show=function(_,widget) shown[#shown+1]=widget end}}
view.synced=true
presenter:show(view)
eq('book-2',shown[#shown].items[1].book.remote_id,'local recent read becomes the visible hero')
shown[#shown].hero_action.callback()
eq('book-2',opened,'hero continue action reads the local most recent book')

return count
