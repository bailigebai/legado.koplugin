local now=100
package.loaded.socket={gettime=function()return now end}
local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Session=require('legado.lib.reader_session')
local function fixture()
    local requests,content={},{}
    local doc={getProgressFraction=function()return .5 end}
    local session=Session.new{storage={putProgress=function()return true end},cache={writeCatalog=function()return true end,readBody=function()end},
        ui={},settings={get=function()return 3 end},service={
            getChapters=function(_,_,_,done)requests[#requests+1]=done;return {cancel=function()end}end,
            getContent=function(_,_,_,chapter)content[#content+1]=chapter;return {cancel=function()end}end,
        }}
    session.active={active=true,source={id='s'},book={id='b',source_id='s'},document=doc,
        index=1,chapters={{uid='c1',index=1}},catalog_complete=false,backend='immersive'}
    return session,requests,content,doc
end
local session,requests,content,doc=fixture()
session:onPageUpdate(session.active,doc,9,12)
eq(1,#requests,'near-end event requests missing directory')
requests[1](nil,{code='NETWORK_ERROR'})
session:onPageUpdate(session.active,doc,9,12)
eq(1,#requests,'repeated screen event during cooldown does not hammer source')
now=107
session:onPageUpdate(session.active,doc,10,12)
eq(2,#requests,'next page after cooldown retries a temporary catalog failure')
local chapters={};for i=1,4 do chapters[i]={uid='c'..i,index=i}end
requests[2](chapters,nil,{catalog_complete=true})
eq(2,#content,'recovered catalog resumes bounded chapter prefetch')
eq(3,session.active.prefetch_status.total,'recovered prefetch window includes all next three chapters')
session:close()
now=200
session,requests,content,doc=fixture()
session:onPageUpdate(session.active,doc,9,12)
requests[1](nil,{code='STORAGE_ERROR'})
now=207;session:onPageUpdate(session.active,doc,10,12)
eq(1,#requests,'storage failure is not blindly retried as a network failure')
session:close()
return n
