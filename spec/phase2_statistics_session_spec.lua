local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local now=100
local rows={}
local bridge=require('legado.lib.koreader_statistics').new{clock=function() return now end,
    store={getOrCreate=function() return 1 end,write=function(_,_,periods)
        for _,p in ipairs(periods) do rows[#rows+1]=p end;return true
    end}}
local current,progress
local session=require('legado.lib.reader_session').new{
    cache={readBody=function() return '<p>Text</p>' end,writeHtml=function() return '/chapter.html' end},
    settings={get=function() return 0 end},statistics=bridge,
    storage={putProgress=function(_,p) progress=p;return true end,getProgress=function() return progress end},
    ui={openDocument=function(_,_,cb)
        local doc={fraction=0,getProgressFraction=function(self) return self.fraction end}
        current={doc=doc,cb=cb};cb.ready(doc);return doc
    end}}
local chapters={{uid='a',index=1,title='A'},{uid='b',index=2,title='B'}}
session:open({id='s'},{id='book',source_id='s',name='Book'},chapters,1)
eq(true,current.cb.native_statistics,'session requests one whole-book statistics record')
now=110;current.doc.fraction=.5;current.cb.page_update(current.doc,5,10)
eq(1,#bridge.periods,'page advance completes one reading period')
now=120;current.cb.pause(current.doc)
eq(2,#rows,'pause flushes active reading periods')
now=300;current.cb.resume(current.doc)
now=310;current.cb.flush(current.doc)
local duration=0;for _,row in ipairs(rows) do duration=duration+row.duration end
eq(30,duration,'suspend interval is excluded from native statistics')
eq('book',progress.statistics_book_id,'whole-book statistics identity persists with progress')
current.cb.close(current.doc)
eq(false,bridge.active,'closing chapter ends its statistics timer')
now=400;session:open({id='s'},{id='book',source_id='s',name='Book'},chapters,2)
eq('book',bridge.book_id,'another chapter uses the same statistics book')
eq(5001,bridge.current_page,'chapter position maps to virtual whole-book units')
session:close()
local starts,forwarded=0,0
progress=nil
session.statistics={start=function(_,book)
    starts=starts+1
    if starts==1 then return nil,{code='DATABASE_BUSY'} end
    return true
end,onPageChanged=function() forwarded=forwarded+1;return true end,checkpoint=function() return true end,close=function() return true end}
session:open({id='s'},{id='other',source_id='s',name='Other'},chapters,1)
eq(nil,session.statistics_owner,'failed statistics start never claims the new book')
current.cb.page_update(current.doc,1,2)
eq(2,starts,'next safe page event retries failed statistics initialization')
eq('other',session.statistics_owner,'successful retry binds statistics to current book')
eq(1,forwarded,'page is forwarded only after current book is bound')
session:close()
local failures=true
starts=0
session.statistics={start=function() starts=starts+1;if failures then return nil,{code='DATABASE_BUSY'} end;return true end,
    checkpoint=function() return true end,flush=function() return true end,pause=function() return true end,
    resume=function() return true end,close=function() return true end}
session:open({id='s'},{id='other',source_id='s',name='Other'},chapters,1)
current.cb.pause(current.doc)
local before=starts;failures=false
current.cb.flush(current.doc)
eq(before,starts,'background save while suspended cannot restart a failed statistics timer')
current.cb.resume(current.doc)
eq(before+1,starts,'explicit resume retries initialization after database recovers')
session:close()
return n
