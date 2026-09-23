local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local App=require('legado.ui.app')
local Session=require('legado.lib.reader_session')
local Settings=require('legado.lib.settings')
local Models=require('legado.lib.models')
local source={id='s'};local book={id='b',source_id=Models.sourceId(source)}
local chapters={{uid='c1',title='One'},{uid='c2',title='Two'}}
eq(true,Settings.DEFAULTS.immersive_reader,'new installs default to immersive reading')
for _,route in ipairs{'explicit','resume','cached','network','offline','failure'} do
    local progress={chapter_uid='c1',fraction=.25}
    local storage={listSources=function() return {source} end,getProgress=function() return progress end,
        putProgress=function(_,value) progress=value;return true end,replaceChapters=function() return true end}
    local backend,opened_state
    local function document(mode,callbacks,state)
        backend,opened_state=mode,state
        local doc={backend=mode,getProgressFraction=function() return .25 end,setProgressFraction=function() return true end,
            close=function(self) self.closed=true;return true end}
        callbacks.ready(doc);return doc
    end
    local ui={openDocument=function(_,_,callbacks) return document('native',callbacks) end,
        openChapter=function(_,payload,callbacks) return document('immersive',callbacks,payload.state) end}
    local cache={readCatalog=function()
        if route=='network' then return nil end
        return {chapters=chapters,complete=true}
    end,readBody=function() return '<p>Body</p>' end,writeHtml=function() return 'body.html' end,
        writeCatalog=function() return true end}
    local service=route~='offline' and {getChapters=function(_,_,_,callback)
        if route=='failure' then return callback(nil,{code='NETWORK_ERROR'}) end
        return callback(chapters,nil,{catalog_complete=true})
    end} or nil
    if route=='failure' then
        local calls=0;cache.readCatalog=function() calls=calls+1;if calls>1 then return {chapters=chapters,complete=true} end end
    end
    local session=Session.new{cache=cache,storage=storage,ui=ui,settings={get=function(_,key)
        if key=='immersive_reader' then return false end;return 0
    end}}
    session.preferred_backend='native' -- A previous temporary/native choice must not affect a new entry.
    local app=App.new{storage=storage,reader_session=session,book_service=service}
    app:startReading(book,(route=='explicit' or route=='resume') and chapters or nil,route=='explicit' and 1 or nil)
    eq('immersive',backend,route..' starts in immersive even with a saved native preference')
    eq(nil,opened_state.restore_fraction,route..' retains exact immersive cursor restoration')
    -- The in-reading switch and subsequent chapter still honor explicit native mode.
    assert(session:open(source,book,chapters,1,{backend='native'}))
    assert(session:_open_cached(session.active,2))
    eq('native',backend,'current-session native choice survives chapter transition')
    session:close()
    app:startReading(book,chapters,1)
    eq('immersive',backend,'reentering from the shelf defaults to immersive again')
    session:close()
end
return n
