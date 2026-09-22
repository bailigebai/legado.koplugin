local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Session=require('legado.lib.reader_session')
local function run(close_first)
    local replies,delivered={},0
    local state={book={id='b',source_id='s'},source={id='s'},chapters={{uid='one',index=1}},index=1,catalog_complete=false}
    local session=Session.new{storage={},ui={},cache={writeCatalog=function()return true end},service={
        getChapters=function(_,_,_,cb)replies[#replies+1]=cb;return {cancel=function()end}end}}
    session.active=state
    session:loadCatalog(state,function()
        if close_first then session:close() else session:loadCatalog(state,function()end,nil,{max_chapters=30}) end
    end,nil,{max_chapters=4})
    session:loadCatalog(state,function()delivered=delivered+1 end,nil,{max_chapters=45})
    replies[1]({{uid='one',index=1},{uid='two',index=2}},nil,{catalog_complete=false})
    return delivered
end
eq(1,run(false),'starting the next catalog request must not strand subscribers of the completed one')
eq(0,run(true),'closing the session suppresses callbacks from the completed reading flow')
return n
