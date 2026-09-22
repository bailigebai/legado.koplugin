local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local H=require('legado.lib.reading_history')
local function stamp(y,m,d,h,minute,s) return os.time{year=y,month=m,day=d,hour=h or 12,min=minute or 0,sec=s or 0} end
local book={id='one',name='甲书',author='甲作者',source_id='source-a',cover_url='https://example.test/one.jpg'}
local start,finish=stamp(2026,8,31,23,59,30),stamp(2026,9,1,0,0,30)
local old={book_id='one',reading_seconds=3600,reading_rating=4,reading_status_override='paused'}
local p=H.record(old,book,start,finish)
eq(3660,p.reading_seconds,'midnight interval adds one minute to existing total')
eq(30,p.reading_daily['2026-08-31'],'before-midnight seconds stay in previous month')
eq(30,p.reading_daily['2026-09-01'],'after-midnight seconds belong to new month')
eq(nil,old.reading_daily,'record does not mutate persisted progress before saving')
eq(4,p.reading_rating,'new session preserves user rating')
eq('paused',p.reading_status_override,'new session preserves manual reading status')
eq('甲书',p.book_snapshot.name,'history retains book metadata independently of shelf membership')
local idle=H.record(p,book,nil,finish+3600)
eq(3660,idle.reading_seconds,'paused flush records no elapsed seconds')
local rollback=H.record(p,book,finish,finish-30)
eq(3660,rollback.reading_seconds,'backward clock never subtracts reading time')
local nextp=H.record(p,book,finish,finish+60)
eq(90,nextp.reading_daily['2026-09-01'],'later flush adds only its new interval')
eq(30,p.reading_daily['2026-09-01'],'per-day map is copied before mutation')

local Fs=require('legado.lib.fs')
local Storage=require('legado.lib.storage')
local data,fail=nil,false
local fs={read=function() return data end,atomicWrite=function(_,_,value)
    if fail then return nil,{code='STORAGE_ERROR'} end; data=value;return true end}
local storage=assert(Storage.new{fs=fs,sqlite_loader=function() return nil end})
p.chapter_index,p.chapter_count,p.catalog_complete,p.fraction=2,4,true,.5
storage:putProgress(p)
local other={book_id='two',book_snapshot={id='two',name='乙书',is_local=true},reading_seconds=120,
    reading_daily={['2026-09-01']=120},chapter_index=1,fraction=.4,page_index=40,page_count=100,updated_at=finish}
storage:putProgress(other)
local reopened=assert(Storage.new{fs=fs,sqlite_loader=function() return nil end})
eq(2,#reopened:listProgress(),'all book progress survives a real serialization round trip')
local report=assert(H.collect(reopened))
eq(3780,report.total_seconds,'overview sums all books including retained old total')
eq(2,report.reading_days,'reading days are unique dates, not sum of per-book days')
eq(1890,report.average_seconds,'lifetime average uses unique known reading days')
eq(150,report.daily['2026-09-01'],'daily total combines books')
eq(3600,report.unattributed_seconds,'legacy total is retained without fabricated daily history')
eq(2,#report.records,'books read without shelf entries remain in history')
local overview=H.overview(report,2026,stamp(2026,9,1))
eq(30,overview.months[8].seconds,'monthly chart includes August seconds')
eq(150,overview.months[9].seconds,'monthly chart includes September seconds')
eq(30,overview.week[1].seconds,'Monday starts the week across month boundary')
eq(150,overview.week[2].seconds,'Tuesday week bar contains both books')
eq(180/7,overview.week_average_seconds,'weekly average includes the seven calendar days shown in the chart')
local day=H.calendar(report,2026,9,'2026-09-01',stamp(2026,9,1))
eq(42,#day.calendar,'calendar has six complete rows for stable layout')
eq(nil,day.calendar[1].day,'September 2026 starts on Tuesday')
eq(1,day.calendar[2].day,'first day is in Tuesday column')
eq(true,day.calendar[2].is_today,'current date can be highlighted')
eq(150,day.day_total,'selected-day detail matches calendar sum')
eq('two',day.day_books[1].book.id,'day books sort by reading time')
eq(1,day.month_days,'month count uses days with nonzero reading')
eq(29,H.calendar(report,2028,2,'2028-02-29',stamp(2028,2,29)).calendar[30].day,'leap-year February retains day 29')
local receipt=H.book(book,p)
eq('约 37.5%',receipt.progress_text,'online percentage represents whole novel')
eq('章节位置',receipt.position_label,'online receipt does not claim whole-book page counts')
eq('2 / 4',receipt.position_text,'online receipt uses known chapter position')
eq(2,receipt.day_count,'receipt counts this book reading dates')
local local_receipt=H.book(other.book_snapshot,other)
eq('40 / 100',local_receipt.position_text,'local receipt uses actual native pages')
eq('40.0%',local_receipt.progress_text,'local progress uses native document fraction')
eq('paused',receipt.status,'manual status overrides automatic status only in the receipt')
eq(nil,H.book(book,{chapter_index=1,fraction=1,catalog_complete=false}).fraction,'partial catalog cannot imply complete novel')
local saved=assert(H.setReview(storage,book,'rating',5))
eq(.5,saved.fraction,'rating cannot overwrite actual reading position')
eq(5,storage:getProgress(book.id).reading_rating,'rating persists for this book')
eq(nil,storage:getProgress('two').reading_rating,'rating never leaks to another book')
local commented,comment_error=H.setReview(storage,book,'comment','读后感：值得重读。\n第二行')
eq(nil,comment_error,'valid multiline receipt comment saves without error')
eq('读后感：值得重读。\n第二行',commented and commented.reading_comment,'receipt comment persists beside rating')
eq(.5,commented and commented.fraction,'comment editing preserves actual reading position')
eq('读后感：值得重读。\n第二行',H.book(book,storage:getProgress(book.id)).comment,'receipt model exposes the stored comment')
local invalid_comment,comment_bad=H.setReview(storage,book,'comment',{})
eq(nil,invalid_comment,'non-text comments are rejected')
eq('INVALID_INPUT',comment_bad.code,'invalid comment yields a recoverable input error')
eq('2026-08-31',receipt.start_date,'receipt start date is earliest recorded reading day')
local no,bad=H.setReview(storage,book,'rating',6)
eq(nil,no,'out-of-range rating is rejected')
eq('INVALID_INPUT',bad.code,'invalid rating returns a recoverable error')
fail=true
local failed,err=H.setReview(storage,book,'status','finished')
eq(nil,failed,'failed save reports failure')
eq('STORAGE_ERROR',err.code,'failed save exposes storage error')
eq('paused',storage:getProgress(book.id).reading_status_override,'failed status write preserves old value')

local legacy_book={id='legacy',name='旧版书名',author='旧版作者'}
local legacy_storage={
    listProgress=function() return {{book_id='legacy',reading_seconds=60,reading_daily={['2026-09-01']=60}}} end,
    getBook=function(_,id) return id=='legacy' and legacy_book or nil end,
}
local legacy_report=assert(H.collect(legacy_storage))
eq('旧版书名',legacy_report.records[1].book.name,'legacy progress supplements missing snapshot from the shelf book')

local compat=Storage.new{backend={
    listBooks=function() return {{id='legacy',name='旧版书名'}} end,
    getProgress=function(_,id) return id=='legacy' and {book_id=id,reading_seconds=60} or nil end,
    getBook=function() return legacy_book end,
}}
eq(1,#compat:listProgress(),'injected legacy adapters without listProgress fall back to shelf progress')

local malformed=assert(H.collect({listProgress=function() return {{book_id='dirty',reading_seconds=-5,
    reading_daily={['2026-99-01']=30,['2026-09-31']=30,['2026-09-01']=-1,['2026-09-02']=math.huge}}} end}))
eq(0,malformed.total_seconds,'negative total seconds are discarded')
eq(nil,malformed.daily['2026-99-01'],'invalid calendar dates are discarded')
eq(0,H.overview(malformed,2026,finish).months[9].seconds,'malformed daily values cannot reach monthly charts')

local Session=require('legado.lib.reader_session')
local writes=0
local read_error_storage={getProgress=function() return nil,{code='STORAGE_ERROR'} end,
    putProgress=function() writes=writes+1;return true end}
local read_error_session=Session.new{storage=read_error_storage,cache={},ui={}}
local read_error_state={active=true,book={id='read-error'},chapters={{uid='c1',index=1}},index=1,started_at=os.time()}
local read_saved,read_err=read_error_session:_save(read_error_state,{getProgressFraction=function() return .2 end})
eq(nil,read_saved,'progress read failure aborts network save')
eq('STORAGE_ERROR',read_err.code,'network save returns the progress read error')
eq(0,writes,'network save never overwrites progress after a read failure')

local closed_previous={active=true,document={closed=true}}
local failed_candidate={previous=closed_previous,active=false}
read_error_session.active,read_error_session.pending=closed_previous,failed_candidate
read_error_session:_fail_candidate(failed_candidate,{code='STORAGE_ERROR'})
eq(nil,read_error_session.active,'failed startup never restores an already closed reader')
eq(false,closed_previous.active,'closed previous session remains inactive after startup failure')

local real_time=os.time
local now=100
os.time=function(value) return value and real_time(value) or now end
local persisted,fail_once=nil,true
local retry_storage={
    getProgress=function() return persisted end,
    putProgress=function(_,value)
        if fail_once then return nil,{code='STORAGE_ERROR'} end
        persisted=value
        return value
    end,
}
local retry_session=Session.new{storage=retry_storage,cache={},ui={}}
local retry_doc={getProgressFraction=function() return .2 end}
local retry_state={active=true,book={id='retry'},chapters={{uid='c1',index=1}},index=1,
    chapter_count=1,catalog_complete=true,started_at=90,document=retry_doc}
retry_session.active=retry_state
local retry_callbacks=retry_session:_callbacks(retry_state)
retry_callbacks.pause(retry_doc)
eq(true,retry_state.paused,'failed pause save still suspends the reading timer')
now=200;retry_callbacks.resume(retry_doc)
fail_once=false;now=210;retry_callbacks.flush(retry_doc)
eq(20,persisted.reading_seconds,'retry retains pre-pause reading without counting suspended time')

local local_writes,local_callbacks=0
local local_storage={createBook=function() return true end,getProgress=function() return nil,{code='STORAGE_ERROR'} end,
    putProgress=function() local_writes=local_writes+1;return true end}
local App=require('legado.ui.app')
local local_doc={getProgressFraction=function() return .3 end}
local local_app=App.new{storage=local_storage,fs={lfs={attributes=function() return {mode='file'} end}},
    reader_session={close=function() end,ui={openDocument=function(_,_,callbacks) local_callbacks=callbacks;callbacks.ready(local_doc);return local_doc end}}}
local_app:startReading({id='local-read-error',name='本地旧书',is_local=true,local_path='/book.epub'})
local local_saved,local_err=local_callbacks.flush(local_doc)
eq(nil,local_saved,'progress read failure aborts local save')
eq('STORAGE_ERROR',local_err.code,'local save returns the progress read error')
eq(0,local_writes,'local save never overwrites progress after a read failure')
os.time=real_time
return count
