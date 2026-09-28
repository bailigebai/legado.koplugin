local A=require('assertions')
local App=require('legado.ui.app')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local book={id='book-local',remote_id='remote-1',source_id='weread',name='测试书'}
local chapter={uid='chapter-local',remote_uid='remote-chapter',index=1,source_id='weread',book_id='book-local',title='第一章'}
local values={}
local stored_progress, progress_read_error
local storage={getProgress=function() return stored_progress,progress_read_error end,putProgress=function(_,progress)
    values.saved=progress;return progress
end}
local session={cache={writeCatalog=function(_,source,id,catalog)
    values.catalog={source,id,catalog};return true
end},resume=function(_,source,target,chapters,callback)
    values.resume={source,target,chapters};callback({backend='native'});return {cancel=function() end}
end,close=function() return true end}
session.openOffline=function(_,source,target,index,callback,options)
    values.offline={source=source,target=target,index=index,options=options}
    callback({backend='native',offline=true})
    return {cancel=function() end}
end
local catalog_error
local service={getChapters=function(_,source,target,callback)
    eq('weread',source.id,'WeRead opens with its own virtual source')
    if catalog_error then callback(nil,catalog_error) else callback({chapter}) end
    return {cancel=function() end}
end}
local cloud_progress={book={chapterUid='remote-chapter',chapterOffset=4500}}
local cloud_error, progress_queries = nil, 0
local client={getProgress=function(_,remote_id,callback)
    progress_queries=progress_queries+1
    eq('remote-1',remote_id,'historical progress is requested for the selected remote book')
    callback(cloud_progress,cloud_error)
    return {cancel=function() end}
end}
local app=App.new{storage=storage,reader_session=session,weread_service=service,weread_client=client}
local opened
app:startWeReadReading(book,function(document) opened=document end)
eq('chapter-local',values.saved.chapter_uid,'cloud chapter maps to stable local chapter identity')
eq(0.45,values.saved.fraction,'cloud position is restored locally')
eq(true,values.catalog[3].complete,'WeRead catalog is stored as complete')
eq('native',opened.backend,'WeRead reader returns the native document')
cloud_progress={book={}}
values.saved=nil
app:startWeReadReading(book,function(document) opened=document end)
eq(nil,values.saved,'empty cloud progress is not stored as a fabricated reading record')
eq('native',opened.backend,'a book without cloud history still opens from the beginning')

cloud_progress,cloud_error=nil,'网络暂时不可用'
values.resume,values.saved=nil,nil
local progress_failure
app:startWeReadReading(book,function(_,err) progress_failure=err end)
eq(nil,values.resume,'failed cloud progress lookup cannot open at a false first-chapter position')
eq(nil,values.saved,'failed cloud progress lookup does not save a replacement position')
eq('NETWORK_ERROR',progress_failure and progress_failure.code,
    'failed cloud progress lookup reports a retryable reading error')

stored_progress={book_id='book-local',source_id='weread',chapter_index=1,fraction=0.25}
local queries_before_local=progress_queries
values.resume=nil
app:startWeReadReading(book,function(document) opened=document end)
eq(queries_before_local,progress_queries,'existing local position does not depend on cloud progress availability')
eq('native',opened.backend,'a book with local progress still opens while the cloud is unavailable')

catalog_error={code='NETWORK_ERROR',message='目录暂时不可用'}
values.offline,values.resume=nil,nil
app:startWeReadReading(book,function(document) opened=document end)
eq('weread',values.offline and values.offline.source.id,'local history opens cached WeRead chapters after catalog failure')
eq(nil,values.offline.index,'offline fallback resumes the saved chapter rather than forcing chapter one')
eq(true,values.offline.options.exact_progress,'WeRead fallback requires the exact saved chapter')
eq(true,opened.offline,'offline fallback returns the cached reader document')
eq(nil,values.resume,'remote catalog failure does not start a normal online session')

stored_progress,values.offline=nil,nil
local catalog_failure
app:startWeReadReading(book,function(_,err) catalog_failure=err end)
eq(nil,values.offline,'without local history a failed catalog cannot open from chapter one')
eq('NETWORK_ERROR',catalog_failure and catalog_failure.code,'catalog failure remains visible without local history')

progress_read_error={code='STORAGE_ERROR'}
app:startWeReadReading(book,function(_,err) catalog_failure=err end)
eq(nil,values.offline,'progress storage failure does not start offline reading')
eq('STORAGE_ERROR',catalog_failure and catalog_failure.code,'progress storage error is reported')
progress_read_error=nil
catalog_error=nil
stored_progress=nil

values.resume=nil
local delayed_chapters
local pending=App.new{storage=storage,reader_session=session,weread_client=client,
    weread_service={getChapters=function(_,_,_,callback)
        delayed_chapters=callback
        return {cancel=function() end}
    end}}
local cancelled=pending:startWeReadReading(book,function() end)
eq(true,cancelled:cancel(),'a pending WeRead reading request can be cancelled')
delayed_chapters({chapter})
eq(nil,values.resume,'cancelled chapter loading cannot open the reader later')
local cancelled_failure=pending:startWeReadReading(book,function() end)
stored_progress={book_id='book-local',source_id='weread',chapter_index=1}
values.offline=nil
eq(true,cancelled_failure:cancel(),'pending catalog request can be cancelled before failure')
delayed_chapters(nil,{code='NETWORK_ERROR'})
eq(nil,values.offline,'cancelled catalog failure cannot open offline reader later')
return count
