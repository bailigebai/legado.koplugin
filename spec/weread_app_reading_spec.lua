local A=require('assertions')
local App=require('legado.ui.app')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local book={id='book-local',remote_id='remote-1',source_id='weread',name='测试书'}
local chapter={uid='chapter-local',remote_uid='remote-chapter',index=1,source_id='weread',book_id='book-local',title='第一章'}
local values={}
local storage={getProgress=function() return nil end,putProgress=function(_,progress)
    values.saved=progress;return progress
end}
local session={cache={writeCatalog=function(_,source,id,catalog)
    values.catalog={source,id,catalog};return true
end},resume=function(_,source,target,chapters,callback)
    values.resume={source,target,chapters};callback({backend='native'});return {cancel=function() end}
end,close=function() return true end}
local service={getChapters=function(_,source,target,callback)
    eq('weread',source.id,'WeRead opens with its own virtual source')
    callback({chapter});return {cancel=function() end}
end}
local client={getProgress=function(_,remote_id,callback)
    eq('remote-1',remote_id,'historical progress is requested for the selected remote book')
    callback({book={chapterUid='remote-chapter',chapterOffset=4500}})
    return {cancel=function() end}
end}
local app=App.new{storage=storage,reader_session=session,weread_service=service,weread_client=client}
local opened
app:startWeReadReading(book,function(document) opened=document end)
eq('chapter-local',values.saved.chapter_uid,'cloud chapter maps to stable local chapter identity')
eq(0.45,values.saved.fraction,'cloud position is restored locally')
eq(true,values.catalog[3].complete,'WeRead catalog is stored as complete')
eq('native',opened.backend,'WeRead reader returns the native document')
return count
