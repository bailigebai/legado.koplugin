local A=require('assertions');local n=0
local function eq(want,got,why)n=n+1;A.equal(want,got,why)end
local Json=require('legado.lib.json_codec')
local Rules=require('legado.lib.rule_engine')
local Safe=require('legado.lib.safe_functions')
local Models=require('legado.lib.models')
local Service=require('legado.lib.book_service')
local Session=require('legado.lib.reader_session')
local function rows(first,last)
    local out={};for i=first,last do out[#out+1]={title='Chapter '..i,url='/chapter/'..i} end;return out
end
local function fixture(backend)
    local f={requests={},opened={},diagnostics={},scheduler=require('support.network_fakes').scheduler()}
    f.source={bookSourceUrl='https://long-catalog.test/',ruleToc={chapterList='$.chapters[*]',
        chapterName='$.title',chapterUrl='$.url',nextTocUrl='$.next'}}
    f.book=Models.book(f.source,{name='Long book',url='/book'},f.source.bookSourceUrl)
    f.rules=Rules.new{json_decoder=Json,html_parser=require('legado.vendor.htmlparser'),
        safe_functions=Safe.functions,url_resolver=Safe.resolve_url}
    f.service=Service.new{storage={},rule_engine=f.rules,scheduler=f.scheduler,
        url_template=require('legado.lib.url_template').new{rule_engine=f.rules},
        request_engine={execute=function(_,request,done)
            local r={request=request,done=done,cancelled=false};f.requests[#f.requests+1]=r
            return {cancel=function()r.cancelled=true end}
        end}}
    local chapters={};for i,v in ipairs(rows(1,15))do
        chapters[i]=Models.chapter(f.book,f.source,{index=i,title=v.title,url=v.url},f.source.bookSourceUrl)
    end
    local function open(_,_,callbacks)
        local doc={backend=backend or 'immersive',getProgressFraction=function()return 0 end,close=function()end}
        local old=f.opened[#f.opened]
        f.opened[#f.opened+1]={doc=doc,callbacks=callbacks}
        if backend=='native' and old then old.callbacks.close(old.doc) end
        if not f.delay_ready then callbacks.ready(doc) end
        return doc
    end
    f.session=Session.new{service=f.service,scheduler=f.scheduler,
        storage={putProgress=function()return true end,getProgress=function()return {}end,replaceChapters=function()return true end},
        cache={readBody=function()return '<p>Cached text</p>'end,writeHtml=function()return 'chapter.html'end,
            writeCatalog=function(_,_,_,value)f.saved=value;return 'catalog.json'end},
        ui={openChapter=open,openDocument=open,prepareChapter=function()return true end},
        diagnostics=function(_,err)f.diagnostics[#f.diagnostics+1]=err end}
    assert(f.session:open(f.source,f.book,chapters,1,{backend=backend or 'immersive',catalog_complete=false}))
    function f:reply(i,first,last,next_url)
        self.requests[i].done({status=200,body=Json.encode{chapters=rows(first,last),next=next_url}})
    end
    f.scheduler:runAll() -- Reader commit must start the full scan without a TOC action.
    return f
end

-- Long novels exceed the ordinary search-rule limit; the background path must
-- still publish their last chapter without any sidebar/menu/page event.
for _,format in ipairs{'json','html','css','xpath'}do
    local f=fixture()
    if format~='json' then
        -- Restart only to select an HTML source for the same public reading path.
        f.session:close();f.source.ruleToc={chapterList=({html='tag.dd',css='@css:dd',xpath='//dd'})[format],chapterName='tag.a@text',chapterUrl='tag.a@href'}
        local list={};for _,row in ipairs(rows(1,1407))do list[#list+1]='<dd><a href="'..row.url..'">'..row.title..'</a></dd>'end
        local initial={Models.chapter(f.book,f.source,{index=1,title='Chapter 1',url='/chapter/1'},f.source.bookSourceUrl)}
        assert(f.session:open(f.source,f.book,initial,1,{backend='immersive',catalog_complete=false}))
        f.scheduler:runAll();f.requests[#f.requests].done({status=200,body='<dl>'..table.concat(list)..'</dl>'})
    else f:reply(1,1,1407) end
    f.scheduler:runAll(2000)
    eq(true,f.session.active.catalog_complete,format..' long catalog completes automatically in the reader')
    eq(1407,#f.session.active.chapters,format..' all chapters beyond the old thousand-item ceiling remain accessible')
    eq('Chapter 1407',f.session.active.chapters[1407].title,format..' final chapter is preserved')
    eq(true,f.saved.complete,format..' whole catalog is saved complete')
    local normal,err=f.rules:parseElements({chapters=rows(1,1407)},'$.chapters[*]')
    eq(nil,normal,'catalog allowance does not relax ordinary search parsing')
    eq('PARSE_ERROR',err and err.code,'normal rule limits still reject oversized results')
    f.session:close()
end

local f=fixture();f:reply(1,1,45,'/page2');f.scheduler:runAll()
f.requests[2].done(nil,{code='TIMEOUT'});f.scheduler:runAll()
eq(3,#f.requests,'temporary later-page failure retries without a reader action')
eq(f.requests[2].request.url,f.requests[3].request.url,'retry continues the failed URL instead of downloading the prefix')
f:reply(3,46,90);f.scheduler:runAll()
eq(true,f.session.active.catalog_complete,'recovered scan completes in the background')
eq(90,#f.session.active.chapters,'retry does not duplicate the prefix')
f.session:close()

for _,backend in ipairs{'immersive','native'}do
    f=fixture(backend);f:reply(1,1,45,'/page2');f.scheduler:runAll()
    f.session:navigate(2)
    eq(false,f.requests[2].cancelled,backend..' same-book chapter replacement retains the catalog scan')
    f:reply(2,46,90);f.scheduler:runAll()
    eq(true,f.session.active.catalog_complete,backend..' completed catalog belongs to the new chapter')
    eq(90,#f.session.active.chapters,backend..' new chapter receives all background entries')
    eq(2,#f.requests,backend..' chapter change does not restart catalog downloads')
    f.session:close()
end

f=fixture();f.delay_ready=true;f.session:navigate(2)
f:reply(1,1,90);f.scheduler:runAll()
local pending=f.opened[#f.opened];pending.callbacks.ready(pending.doc)
eq(true,f.session.active.catalog_complete,'late chapter readiness cannot replace a completed catalog with an old snapshot')
eq(90,#f.session.active.chapters,'pending chapter inherits the newest catalog at commit')
f.session:close()

f=fixture()
for page=1,80 do
    f:reply(page,(page-1)*20+1,page*20,page<80 and '/page'..(page+1) or nil)
    f.scheduler:runAll()
    if page<80 then eq(page+1,#f.requests,'long paged novel continues beyond the old page ceiling')end
end
eq(true,f.session.active.catalog_complete,'multi-page long catalog reaches the last website page')
eq(1600,#f.session.active.chapters,'all website pages contribute unique chapters')
f.session:close()

for _,err in ipairs{{code='PARSE_ERROR'},{code='STORAGE_ERROR'},
    {code='NETWORK_ERROR',details={status=404}},{code='SITE_REJECTED',details={status=429}}}do
    f=fixture();f.requests[1].done(nil,err);f.scheduler:runAll()
    eq(1,#f.requests,'non-transient catalog failure does not retry or hammer a rejected site')
    local opened=f.opened[#f.opened]
    eq(err.code,opened.callbacks.context(opened.doc,{chapter_fraction=0}).catalog_error,'background failure is visible to reading context instead of permanent loading')
    f.session:close()
end
f=fixture()
for i=1,3 do f.requests[i].done(nil,{code='TIMEOUT'});f.scheduler:runAll() end
eq(3,#f.requests,'persistent network failure stops after bounded automatic retries')
f.session:close()
f=fixture();f.requests[1].done(nil,{code='TIMEOUT'});f.session:close();f.scheduler:runAll()
eq(1,#f.requests,'leaving the reader cancels a scheduled retry')
f=fixture();f.requests[1].done(nil,{code='TIMEOUT'})
local current=f.opened[#f.opened];current.callbacks.pause(current.doc,true);f.scheduler:runAll()
eq(1,#f.requests,'suspending cancels scheduled catalog retry')
f.session:close()

f=fixture()
eq(true,f.scheduler.now_value<1,'full catalog starts promptly after reader commit without waiting for a menu or six-second refresh throttle')
local oversize,limit_error=f.rules:parseCatalogElements({chapters=rows(1,10001)},'$.chapters[*]')
eq(nil,oversize,'catalog-only output allowance is still bounded')
eq('PARSE_ERROR',limit_error and limit_error.code,'oversized catalog fails safely')
f.session:close()
return n
