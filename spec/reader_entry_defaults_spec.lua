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

local image_progress, reject_image_flag, image_opened=nil,false,{}
local image_book={id='weread-book',source_id='weread',name='图文书'}
local image_chapters={{uid='text',title='文字章',index=1},{uid='image',title='图片章',index=2}}
local image_storage={getProgress=function() return image_progress end,
    putProgress=function(_,value)
        if reject_image_flag and value.contains_images then
            return nil,{code='STORAGE_ERROR',message='cannot save image flag'}
        end
        image_progress=value;return value
    end}
local function image_document(mode,callbacks)
    image_opened[#image_opened+1]=mode
    local document={backend=mode,getProgressFraction=function() return 0 end,
        setProgressFraction=function() return true end,close=function() return true end}
    callbacks.ready(document)
    return document
end
local image_session=Session.new{storage=image_storage,cache={
    readBody=function(_,_,_,chapter)
        return chapter.uid=='image' and '<p>插图<img src="../images/image_1.png"></p>' or '<p>纯文字</p>'
    end,chapterImages=function() return {['../images/image_1.png']={path='/cache/image_1.png',width=1,height=1}} end,
        verifyChapterImages=function() return true end,writeHtml=function() return 'image.html' end},
    ui={openChapter=function(_,payload,callbacks)
        if payload.body:find('<img',1,true) then eq('/cache/image_1.png',payload.images['../images/image_1.png'].path,'session passes verified image descriptors') end
        return image_document('immersive',callbacks) end,
        openDocument=function(_,_,callbacks) return image_document('native',callbacks) end},
    settings={get=function(_,key) return key=='immersive_reader' and true or 0 end}}
assert(image_session:open({id='weread'},image_book,image_chapters,1,{backend='immersive'}))
eq('immersive',image_session.active.backend,'pure text starts in immersive mode')
reject_image_flag=true
local failed,flag_error=image_session:navigate(2,{})
eq(nil,failed,'image chapter is not committed when its per-book flag cannot be saved')
eq('STORAGE_ERROR',flag_error and flag_error.code,'image flag save failure is visible')
eq(1,image_session.active.index,'failed image transition retains the previous chapter')
reject_image_flag=false
assert(image_session:navigate(2,{}))
eq('immersive',image_session.active.backend,'later image chapter retains immersive reading')
eq(true,image_progress.contains_images,'image mode is saved per book')
image_session:close()
image_progress.chapter_uid='text'
image_progress.chapter_index=1
assert(image_session:resume({id='weread'},image_book,image_chapters,function() end))
eq('immersive',image_session.active.backend,'known image book reopens in the preferred immersive mode')
eq('text',image_session.active.chapters[image_session.active.index].uid,
    'known image book can reopen its saved text chapter without losing position')
local settings_writes=0
local image_app=App.new{reader_session=image_session,settings={set=function()
    settings_writes=settings_writes+1;return true
end}}
assert(image_app:toggleImmersiveReader(image_session.active.document))
eq('native',image_session.active.backend,'image book can switch to native mode')
assert(image_app:toggleImmersiveReader(image_session.active.document))
eq('immersive',image_session.active.backend,'image book can switch back to immersive mode')
eq(2,settings_writes,'both explicit mode switches save the preference')

return n
