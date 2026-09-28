local A = require('assertions')
local Session = require('legado.lib.reader_session')
local metrics, writes, requests = {}, 0, {}
local chapters = {
    {uid='one', index=1, url='https://example.invalid/one'},
    {uid='two', index=2, url='https://example.invalid/two'},
}
local session = Session.new({
    cache={writeCatalog=function() return 'catalog.json' end},
    storage={replaceChapters=function() writes=writes+1; return true end},
    ui={},
    service={getChapters=function(_, _, _, callback)
        requests[#requests+1]=callback
        return {cancel=function() end}
    end},
    timing=function(metric) metrics[#metrics+1]=metric end,
})
local state={source={id='source'},book={id='book',source_id='source'},
    chapters={chapters[1]},index=1,backend='native',active=true,catalog_complete=false}
session.active=state

local delivered=false
assert(session:navigate(2,{on_complete=function() delivered=true end}))
A.equal(1,#requests,'navigation waits for the missing catalog chapter')
requests[1](nil,{code='NETWORK_ERROR',message='test outage'})
A.equal(true,delivered,'catalog failure reaches the waiting navigation')
local wait_metric=metrics[#metrics]
A.equal('catalog_wait',wait_metric.stage,'catalog wait has a distinct timing stage')
A.equal('native',wait_metric.backend,'wait timing identifies reader backend')
A.equal(1,wait_metric.chapters,'wait timing reports known chapter count')
A.equal(nil,wait_metric.url,'wait timing never retains a source URL')

assert(session:_updateCatalog(state,chapters,false,true))
A.equal(1,writes,'persisted catalog still updates chapter storage')
local save_metric=metrics[#metrics]
A.equal('catalog_persist',save_metric.stage,'catalog persistence has a distinct timing stage')
A.equal(2,save_metric.chapters,'persistence timing reports written chapter count')
A.equal(nil,save_metric.url,'persistence timing never retains a source URL')

session.cache.writeCatalog=function() return nil,{code='STORAGE_ERROR'} end
local saved,err=session:_updateCatalog(state,chapters,true,true)
A.equal(nil,saved,'failed catalog persistence is reported to caller')
A.equal('STORAGE_ERROR',err.code,'catalog persistence retains the storage error')
A.equal('catalog_persist',metrics[#metrics].stage,'failed persistence is also timed')
A.equal(1,writes,'failed file write never reaches chapter database')

return 14
