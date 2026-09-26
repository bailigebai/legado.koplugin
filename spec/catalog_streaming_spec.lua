local A=require('assertions');local n=0
local function eq(want,got,why)n=n+1;A.equal(want,got,why)end
local Json=require('legado.lib.json_codec')
local Rules=require('legado.lib.rule_engine')
local Safe=require('legado.lib.safe_functions')
local Models=require('legado.lib.models')
local Service=require('legado.lib.book_service')
local Session=require('legado.lib.reader_session')
local App=require('legado.ui.app')
local Fakes=require('support.network_fakes')
local source={bookSourceUrl='https://catalog.test/',ruleToc={chapterList='$.chapters[*]',
    chapterName='$.title',chapterUrl='$.url',nextTocUrl='$.next'}}
local book=Models.book(source,{name='Catalog',url='/book'},source.bookSourceUrl)
local function rows(first,last)
    local out={};for i=first,last do out[#out+1]={title='Chapter '..i,url='/chapter/'..i} end;return out
end
local function fixture()
    local f={scheduler=Fakes.scheduler(),requests={},writes=0,diagnostics={}}
    local rules=Rules.new{json_decoder=Json,safe_functions=Safe.functions,url_resolver=Safe.resolve_url}
    f.rules=rules
    local request={execute=function(_,value,callback)
        local item={request=value,reply=callback,cancelled=false}
        f.requests[#f.requests+1]=item
        return {cancel=function()item.cancelled=true end}
    end}
    f.service=Service.new{storage={},rule_engine=rules,request_engine=request,scheduler=f.scheduler,
        url_template=require('legado.lib.url_template').new{rule_engine=rules}}
    local initial={};for i,row in ipairs(rows(1,15)) do
        initial[i]=Models.chapter(book,source,{index=i,title=row.title,url=row.url},source.bookSourceUrl)
    end
    f.state={book=book,source=source,chapters=initial,index=1,catalog_complete=false,active=true}
    f.session=Session.new{storage={replaceChapters=function()return true end,putProgress=function()return true end},ui={},service=f.service,
        scheduler=f.scheduler,diagnostics=function(_,err)f.diagnostics[#f.diagnostics+1]=err end,
        cache={writeCatalog=function(_,_,_,value)f.writes=f.writes+1;f.saved=value;return 'catalog.json' end}}
    f.session.active=f.state
    f.app=App.new{reader_session=f.session}
    function f:reply(index,first,last,next_url)
        local item=assert(self.requests[index])
        item.reply({status=200,charset='utf-8',final_url=item.request.url,
            body=Json.encode{chapters=rows(first,last),next=next_url}})
    end
    return f
end

-- A slow later HTTP page must not hold already parsed chapters behind the
-- full-catalog callback; use all production layers above the network boundary.
local f=fixture();local complete=false
f.session:loadCatalog(f.state,function(_,err)assert(not err);complete=true end)
local side=f.app:openReadingSideToc(f.state,{})
side:goPage(2)
f:reply(1,1,45,'/page2');f.scheduler:runAll()
eq('Chapter 16',side:menuItems()[1].title,'next sidebar page uses parsed chapters before a slow later page arrives')
eq(false,side.loading,'visible page is no longer blocked by the background full scan')
eq(false,complete,'full-catalog subscriber still awaits the rest')
eq(false,f.state.catalog_complete,'partial delivery does not claim the catalog is complete')
eq(2,#f.requests,'one scan proceeds directly to the next website page')
f:reply(2,46,90);f.scheduler:runAll()
eq(true,complete,'background subscriber eventually receives the whole catalog')
eq(90,#f.state.chapters,'full catalog remains available in the reader')
eq(true,f.saved.complete,'full catalog is saved for reopening')
eq(true,side.complete,'open sidebar learns when background catalog finishes')
eq(6,side:pageCount(),'background completion exposes the final page count')
side:goPage(6)
eq('Chapter 76',side:menuItems()[1].title,'later cached pages display without restarting the source request')
eq(2,#f.requests,'sidebar pagination does not re-download earlier website pages')
side:close();f.session:close()

-- Closing the drawer only drops its interest; the reading session owns the
-- complete scan even when the drawer started it before the background timer.
f=fixture();side=f.app:openReadingSideToc(f.state,{})
side:goPage(2);f:reply(1,1,90);side:close()
eq(false,f.requests[1].cancelled,'closing a pending drawer keeps the reader catalog scan alive')
f.scheduler:runAll()
eq(90,#f.state.chapters,'background scan finishes after closing its only drawer subscriber')
eq(true,f.state.catalog_complete,'completed background scan remains available on reopening')
side=f.app:openReadingSideToc(f.state,{})
side:goPage(6)
eq('Chapter 76',side:menuItems()[1].title,'reopened drawer uses the completed background result')
eq(1,#f.requests,'reopening a completed catalog does not download it again')
side:close();f.session:close()

f=fixture();side=f.app:openReadingSideToc(f.state,{})
side:goPage(2);f:reply(1,1,1000)
local old_count=#f.state.chapters
f.session:close();f.scheduler:runAll()
eq(true,f.requests[1].cancelled,'closing the reading session cancels its catalog scan')
eq(old_count,#f.state.chapters,'queued parsing cannot update a closed reading session')
side:close()

-- A large single-page source yields between row batches instead of evaluating
-- a thousand chapter rules in the network completion callback.
f=fixture();local reads=0;local parse=f.rules.parse
f.rules.parse=function(self,input,rule,...)
    if rule=='$.title' then reads=reads+1 end
    return parse(self,input,rule,...)
end
local result
local request=f.service:getChapters(source,book,function(value)result=value end)
f:reply(1,1,1000)
eq(true,reads<1000,'large catalog returns control before evaluating every chapter')
eq(nil,result,'full catalog completes only after queued parsing')
local stopped=reads;request:cancel();f.scheduler:runAll()
eq(stopped,reads,'cancelling stops queued chapter parsing')
eq(nil,result,'cancelled parse cannot complete later')

-- An exception in one subscriber must not strand another sidebar subscriber.
f=fixture()
f.session:loadCatalog(f.state,function()error('consumer failed')end,nil,{max_chapters=30})
side=f.app:openReadingSideToc(f.state,{})
side:goPage(2);f:reply(1,1,45,'/page2');f.scheduler:runAll()
eq('Chapter 16',side:menuItems()[1].title,'another subscriber throwing does not lose the visible page')
eq(1,#f.diagnostics,'subscriber failure is recorded without aborting catalog distribution')
side:close();f.session:close()

-- Save failures must settle the loading screen and cancel ongoing parsing.
f=fixture();f.session.cache.writeCatalog=function()error('injected disk failure')end
side=f.app:openReadingSideToc(f.state,{})
side:goPage(2);f:reply(1,1,1000);f.scheduler:runAll()
eq(false,side.loading,'storage exception leaves loading state')
eq('function',type(side:menuItems()[1].callback),'storage failure offers a retry')
eq(true,f.requests[1].cancelled,'failed partial persistence cancels the remaining full scan')
side:close();f.session:close()

-- A failed later page keeps known rows usable and settles the missing page.
f=fixture();side=f.app:openReadingSideToc(f.state,{})
side:goPage(3);f:reply(1,1,30,'/page2');f.scheduler:runAll()
f.requests[2].reply(nil,{code='TIMEOUT',message='source timed out'})
eq(false,side.loading,'later network failure exits the page loading state')
eq('function',type(side:menuItems()[1].callback),'missing page exposes retry after timeout')
side:goPage(2)
eq('Chapter 16',side:menuItems()[1].title,'timeout does not hide previously loaded chapters')
side:goPage(3);f:reply(3,1,60);f.scheduler:runAll()
eq('Chapter 31',side:menuItems()[1].title,'explicit retry can recover the missing page')
side:close();f.session:close()

for _,fault in ipairs{'parse','schedule'} do
    f=fixture();side=f.app:openReadingSideToc(f.state,{})
    side:goPage(2)
    if fault=='parse' then f.rules.parseElements=function()error('parser panic')end
    else f.scheduler.scheduleIn=function()error('scheduler unavailable')end end
    f:reply(1,1,1000);f.scheduler:runAll()
    eq(false,side.loading,fault..' exception cannot leave permanent loading')
    eq('function',type(side:menuItems()[1].callback),fault..' failure offers retry')
    side:close();f.session:close()
end

-- A reversed source must not expose newest-first rows as a stable prefix.
f=fixture();local reversed={bookSourceUrl=source.bookSourceUrl,ruleToc={}}
for k,v in pairs(source.ruleToc)do reversed.ruleToc[k]=v end
reversed.ruleToc.chapterList='-'..reversed.ruleToc.chapterList
local early,final=0,nil
f.service:getChapters(reversed,book,function(value,err)assert(not err);final=value end,
    {max_chapters=3,on_progress=function(_,_,prefix)if prefix then early=early+1 end end})
f:reply(1,1,45);f.scheduler:runAll()
eq(0,early,'reversed source does not publish incorrectly ordered partial pages')
eq(45,#final,'reversed source is collected fully despite startup cap')
eq('Chapter 45',final[1].title,'reversal is applied after all batches finish')

-- KOReader drains newly scheduled due tasks before repaint/input. A zero-delay
-- batch chain would still monopolize that real task sweep despite mock yields.
local h=require('native_library_harness').install()
local now=0
require('device')._UIManagerReady=function()end
package.loaded['ffi/util']={}
require('ui/time').now=function()return now end
require('dbg').v=function()end
G_reader_settings.isFalse=function()return false end
h.screen.getDPI=function()return 300 end
package.loaded['ui/uimanager']=nil
local host=require('ui/uimanager')
f=fixture();f.service.scheduler=host;local ready
f.service:getChapters(source,book,function(value)ready=value end)
host:scheduleIn(0,function()f:reply(1,1,1000)end)
local next_time=host:_checkTasks()
eq(nil,ready,'one real host task sweep leaves time to repaint/respond before the entire catalog finishes')
eq(true,next_time~=nil and next_time>now,'next parsing batch is scheduled beyond the current host sweep')
local sweeps=1
while next_time do
    now=next_time;sweeps=sweeps+1;assert(sweeps<100)
    next_time=host:_checkTasks()
end
eq(1000,#ready,'yielded catalog still completes all chapters')
return n
