local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local App=require('legado.ui.app')
local Session=require('legado.lib.reader_session')
local function chapters(count)
    local result={};for i=1,count do result[i]={uid='c'..i,url='https://example.org/'..i,title='Chapter '..i,index=i}end
    return result
end
local function fixture()
    local f={requests={},progress={reading_bookmarks={{source_id='s',chapter_uid='c40',chapter_url='https://example.org/40',
        chapter_index=40,title='Chapter 40',fraction=.4}}}}
    local ui={openDocument=function(_,_,callbacks)
        local doc={backend='native',getProgressFraction=function()return .1 end,
            setProgressFraction=function(self,value)self.fraction=value;return true end,close=function()return true end}
        callbacks.ready(doc);return doc
    end}
    local storage={getProgress=function()return f.progress end,putProgress=function(_,p)f.progress=p;return true end}
    f.session=Session.new{storage=storage,cache={readBody=function()return '<p>text</p>'end,
        writeHtml=function(_,_,_,c)return c.uid..'.html'end,writeCatalog=function()return true end},ui=ui,
        settings={get=function(_,k)if k=='prefetch' then return 0 end;return false end},
        service={getChapters=function(_,_,_,cb,options)
            local request={done=cb,target=options.max_chapters};f.requests[#f.requests+1]=request
            return {cancel=function()request.cancelled=true end}
        end}}
    assert(f.session:open({id='s'},{id='b',source_id='s'},chapters(3),1,{catalog_complete=false}))
    f.old=f.session.active
    local app=App.new{reader_session=f.session,storage=storage}
    f.side=app:openReadingSideToc(f.old,f.old.document)
    f.side:switchTab('bookmarks')
    f.choose=function()return f.side:_selectItem(f.side:menuItems()[2])end
    return f
end
local f=fixture();f.choose()
eq(1,f.session.active.index,'unloaded bookmark must not jump to last known chapter')
eq(1,#f.requests,'bookmark requests missing catalog on demand')
eq(true,f.requests[1].target==nil or f.requests[1].target>=40,'catalog scan can reach the saved chapter')
f.requests[1].done(chapters(45),nil,{catalog_complete=false})
eq(40,f.session.active.index,'bookmark resolves exact chapter after lazy catalog load')
eq(.4,f.session.active.document.fraction,'bookmark restores its saved within-chapter position')
eq(true,f.side.closed,'successful bookmark closes the drawer')
f.session:close()
f=fixture();f.choose();f.side:close()
f.requests[1].done(chapters(45),nil,{catalog_complete=false})
eq(f.old,f.session.active,'closed drawer ignores late bookmark result');f.session:close()
f=fixture();f.choose()
local wrong=chapters(45);wrong[40].uid='other';wrong[40].url='https://example.org/other'
f.requests[1].done(wrong,nil,{catalog_complete=true})
eq(f.old,f.session.active,'same numeric position with another identity cannot replace bookmark')
eq(false,f.side.closed,'unresolved bookmark keeps current reader and drawer');f.side:close();f.session:close()
f=fixture();f.progress.reading_bookmarks[1].source_id='other-source';f.choose()
eq(0,#f.requests,'foreign-source bookmark cannot fetch from current source')
eq(f.old,f.session.active,'foreign-source bookmark cannot jump to a different novel');f.side:close();f.session:close()
-- A bookmark may join a smaller speculative catalog request.
f=fixture();f.session:loadCatalog(f.old,function()end,nil,{max_chapters=4});f.choose()
eq(1,#f.requests,'bookmark joins in-flight catalog without a duplicate fetch')
f.requests[1].done(chapters(4),nil,{catalog_complete=false})
eq(2,#f.requests,'short speculative result is extended to bookmark demand')
f.requests[2].done(chapters(45),nil,{catalog_complete=false})
eq(40,f.session.active.index,'shared catalog still reaches bookmark identity');f.session:close()
-- Two selections can share the same not-yet-loaded catalog; the latest
-- explicit tap must win even if the earlier subscriber was added first.
f=fixture()
f.progress.reading_bookmarks[2]={source_id='s',chapter_uid='c42',chapter_url='https://example.org/42',chapter_index=42,title='Chapter 42',fraction=.7}
f.side:switchTab('bookmarks')
f.side:_selectItem(f.side:menuItems()[2]);f.side:_selectItem(f.side:menuItems()[3])
eq(1,#f.requests,'rapid bookmark taps share one directory request')
f.requests[1].done(chapters(45),nil,{catalog_complete=true})
eq(42,f.session.active.index,'latest bookmark selection wins over an older pending selection')
eq(.7,f.session.active.document.fraction,'latest bookmark keeps its own chapter position')
f.session:close()
return n
