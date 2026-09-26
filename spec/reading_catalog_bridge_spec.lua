local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1;A.equal(a,b,m) end
local App=require('legado.ui.app')
local Models=require('legado.lib.models')
local Session=require('legado.lib.reader_session')
local source={id='s'}
local book={id='b',source_id=Models.sourceId(source)}
local chapters={}
for i=1,36 do chapters[i]={uid='c'..i,index=i,title='Chapter '..i,url='https://s/'..i,source_id=book.source_id,book_id='b'} end
local full={chapters=chapters,complete=true}
local catalog=full
local progress={chapter_index=35,chapter_uid='c35',fraction=.4}
local storage={listSources=function() return {source} end,getProgress=function() return progress end,
    putProgress=function(_,value) progress=value;return true end,replaceChapters=function() return true end}
local cache={readCatalog=function() return catalog end,writeCatalog=function(_,_,_,value) catalog=value;return 'catalog.json' end,
    readBody=function() return '<p>Chapter body</p>' end,writeHtml=function() return 'chapter.html' end}
local current_callbacks,loads,finished= nil,0,0
local reader={openDocument=function(_,_,callbacks)
    current_callbacks=callbacks
    local document={getProgressFraction=function() return .4 end,setProgressFraction=function() return true end}
    callbacks.ready(document)
    return document
end,endOfBook=function() finished=finished+1 end}
reader.openChapter=function(self,_,callbacks) return self:openDocument(nil,callbacks) end
local complete_catalog
local service={getChapters=function(_,_,_,cb,options)
    loads=loads+1;complete_catalog=cb
    if options.on_progress then options.on_progress(1,30) end
    return {cancel=function() end}
end}
local session=Session.new{cache=cache,storage=storage,ui=reader,service=service,settings={get=function() return 0 end}}
local app=App.new{storage=storage,book_service=service,reader_session=session}
app:startReading(book)
eq(35,session.active.index,'cached full catalog resumes beyond the first page')
eq(0,loads,'repeat reading does not fetch catalog again')
eq(true,catalog.complete,'quick start preserves the full cached catalog')

local part={}
for i=1,30 do part[i]=chapters[i] end
session:open(source,book,part,30,{catalog_complete=false})
local state=session.active
current_callbacks.end_of_book(state.document)
eq(1,loads,'last item of partial catalog loads remaining web catalog')
eq(0,finished,'partial catalog never signals end of book')
complete_catalog(chapters)
eq(31,session.active.index,'page turn continues to chapter beyond the initial page')
eq(true,catalog.complete,'complete catalog is persisted after expansion')

session:open(source,book,part,4,{catalog_complete=false})
local view=app:openReadingCatalog(session.active,{reader={}})
eq(false,view.loading,'known next page opens without an unnecessary catalog request')
view:goPage(3)
eq(true,view.loading,'web TOC exposes its pending state')
complete_catalog(chapters)
eq(36,#view.items,'TOC includes every web chapter')
eq(false,view.loading,'TOC leaves loading state after completion')
view:select(5)
eq(35,session.active.index,'choosing web TOC item opens that chapter in KOReader')

-- A twelve chapter page exposes large jumps and a reversible display order.
local catalog_view=app:openReadingCatalog(session.active,{reader={}})
complete_catalog(chapters)
local Catalog=require('legado.ui.catalog')
local ordered=Catalog.new(chapters)
ordered:setOrder(true)
eq('Chapter 36',ordered.items[1].title,'catalog can switch to reverse order')
ordered:setOrder(false)
eq('Chapter 1',ordered.items[1].title,'catalog can switch back to forward order')

session:open(source,book,part,4,{catalog_complete=false})
view=app:openReadingCatalog(session.active,{reader={}})
view:goPage(3)
view:close();complete_catalog(chapters)
eq(0,#view.items,'closing TOC discards late network completion')

local intent_current=true
session:open(source,book,chapters,1,{is_current=function() return intent_current end})
intent_current=false
session:_end(session.active,session.active.document)
eq(2,session.active.index,'active reading outlives the detail page that launched it')

local delayed, background_loaded
local background_scheduler={scheduleIn=function(_,delay,callback) delayed={delay=delay,callback=callback}; return callback end,
    unschedule=function() end}
local background=Session.new{cache=cache,storage=storage,ui=reader,service=service,scheduler=background_scheduler}
local background_state={active=true,offline=false,catalog_complete=false,index=1,book={id='background',source_id='source'}}
background.active=background_state
background.loadCatalog=function(_,state) background_loaded=state end
background:_scheduleBackgroundCatalog(background_state)
eq(true,delayed.delay>0 and delayed.delay<1,'background catalog starts promptly after first paint without a six-second wait')
delayed.callback()
eq(background_state,background_loaded,'background catalog starts without opening or refreshing a UI')
-- Use the public reading TOC and its real Presenter cancel action. Rendering,
-- storage and transport are substitutes; Session owns all navigation decisions.
local Fakes=require('support.network_fakes')
local Presenter=require('legado.ui.presenter')
local function selection_fixture(backend)
    local f={requests={},bodies={c1='<p>Current</p>'},opened={},completed=0}
    local scheduler=Fakes.scheduler()
    local ui={}
    local function open(_,_,callbacks)
        local doc={backend=backend,getProgressFraction=function() return .5 end,
            close=function(self) self.closed=true end}
        f.opened[#f.opened+1]=doc;ui.current_document=doc;callbacks.ready(doc);return doc
    end
    ui.openDocument,ui.openChapter=open,open
    local session=Session.new{storage={getProgress=function() return {} end,putProgress=function() return true end},
        cache={readBody=function(_,_,_,chapter) return f.bodies[chapter.uid],{code='STORAGE_ERROR'} end,
            writeBody=function(_,_,_,chapter,body) f.bodies[chapter.uid]=body;return true end,
            writeHtml=function(_,_,_,chapter) return chapter.uid..'.html' end},
        ui=ui,scheduler=scheduler,settings={get=function(_,key) return key=='prefetch' and 1 or false end},
        service={getContent=function(_,_,_,chapter,callback)
            local request={chapter=chapter,callback=callback,cancelled=0}
            function request:cancel() self.cancelled=self.cancelled+1 end
            f.requests[#f.requests+1]=request;return request
        end}}
    f.session=session
    assert(session:open(source,book,chapters,1,{backend=backend}));scheduler:runNext()
    f.app=App.new{reader_session=session}
    f.view=f.app:openReadingCatalog(session.active,session.active.document)
    local presenter=Presenter.new{app=f.app,ui_manager={setDirty=function() end}}
    presenter._library=function(self,view,options) self.library_view=view;f.screen=options end
    presenter._hideLibrary=function() end
    presenter._readingResult=function(_,value,err) return value,err end
    f.select=function()
        return presenter:_startReading(function(done)
            return f.view:select(2,function(value,err) f.completed=f.completed+1;return done(value,err) end)
        end)
    end
    f.cancel=function() f.screen.actions[1].callback() end
    return f
end
for _,backend in ipairs({'native','immersive'}) do
    local f=selection_fixture(backend)
    f.select()
    eq(0,f.requests[1].cancelled,backend..' TOC joins in-flight prefetch without cancellation')
    eq(1,#f.requests,backend..' TOC does not duplicate the same chapter request')
    f.requests[1].callback({content='<p>Next</p>'})
    eq(2,f.session.active.index,backend..' TOC commits its subscribed chapter')
    eq(1,f.completed,backend..' TOC completion is delivered exactly once')
    f.session:close()

    f=selection_fixture(backend);local old=f.session.active
    f.select();f.cancel()
    eq(0,f.requests[1].cancelled,backend..' UI cancellation only retracts its foreground subscription')
    eq(old,f.session.active,backend..' cancelled TOC selection retains the current page')
    f.requests[1].callback({content='<p>Late complete chapter</p>'})
    eq(old,f.session.active,backend..' cancelled selection cannot open on late completion')
    eq(0,f.completed,backend..' cancelled selection receives no late UI notification')
    eq('<p>Late complete chapter</p>',f.bodies.c2,backend..' background completion remains useful after UI cancel')
    f.view=f.app:openReadingCatalog(f.session.active,f.session.active.document);f.select()
    eq(2,f.session.active.index,backend..' selecting again uses the completed chapter')
     local c2_requests=0
     for _,request in ipairs(f.requests) do if request.chapter.uid=='c2' then c2_requests=c2_requests+1 end end
     eq(1,c2_requests,backend..' retry after UI cancellation reuses the same download')
    eq(1,f.completed,backend..' retried TOC selection completes once')
    f.session:close()

    f=selection_fixture(backend);f.select();f.cancel();f.select()
    eq(1,#f.requests,backend..' immediate reselection rejoins the original in-flight chapter')
    f.requests[1].callback({content='<p>Reselected</p>'})
    eq(2,f.session.active.index,backend..' reselected in-flight chapter opens after completion')
    eq(1,f.completed,backend..' only the current selection receives completion')
    f.session:close()

    f=selection_fixture(backend);old=f.session.active;f.select();f.view:close()
    f.requests[1].callback({content='<p>Finished after TOC close</p>'})
    eq(old,f.session.active,backend..' closing TOC retracts the pending selection')
    eq(0,f.requests[1].cancelled,backend..' closing TOC leaves the background request owned by Session')
    eq(0,f.completed,backend..' closed TOC receives no completion')
    f.session:close()

    f=selection_fixture(backend);old=f.session.active;f.select()
    f.requests[1].callback(nil,{code='NETWORK_ERROR',message='offline'})
    eq(old,f.session.active,backend..' failed subscribed chapter retains the current page')
    eq(1,f.completed,backend..' failed subscribed chapter reports completion once')
    f.select();f.requests[2].callback({content='<p>Retry</p>'})
    eq(2,f.session.active.index,backend..' TOC retries after a failed chapter')
    eq(2,f.completed,backend..' the retried chapter sends its own completion')
    f.session:close()

    for _,change in ipairs({'book','source'}) do
        f=selection_fixture(backend);f.select()
        local other_source=change=='source' and {id='other-source'} or source
        local other_book={id=change=='book' and 'other-book' or book.id,source_id=Models.sourceId(other_source)}
        assert(f.session:open(other_source,other_book,chapters,1,{backend=backend}))
        local replacement=f.session.active
        f.requests[1].callback({content='<p>Stale content</p>'})
        eq(replacement,f.session.active,backend..' '..change..' switch rejects a late TOC selection')
        eq(nil,f.bodies.c2,backend..' '..change..' switch rejects stale cache publication')
        eq(1,f.requests[1].cancelled,backend..' '..change..' switch cancels the old request once')
        eq(0,f.completed,backend..' '..change..' switch sends no stale TOC completion')
        local reopened,stale_error=f.view:select(2)
        eq(nil,reopened,backend..' stale TOC cannot reopen the previous '..change)
        eq('CANCELLED',stale_error and stale_error.code,backend..' stale TOC reports cancellation')
        f.session:close()
    end
end
return count
