require('library_screen_stub')
local A=require('assertions')
local count=0
local function eq(want,got,why) count=count+1;A.equal(want,got,why) end
local sources={{id='a',bookSourceName='A'},{id='b',bookSourceName='B'}}
local Models=require('legado.lib.models')
local BookDetail=require('legado.ui.book_detail')
local App=require('legado.ui.app')
local book=Models.book(sources[1],{url='https://a/book',name='同一本书',author='同一作者'})
local candidate=Models.book(sources[2],{url='https://b/book',name=book.name,author=book.author})
local reads=0
local service={search=function() return {cancel=function() end} end}
local app=require('legado.ui.app').new{storage={listSources=function() return sources end},book_service=service,
    reading_hook=function() reads=reads+1;return {} end}
local presenter=require('legado.ui.presenter').new{app=app,ui_manager={show=function() end,close=function() end}}
app.show=function(view) presenter:show(view) end
local detail=app:createBookDetail(book)
app:_present(detail)
local picker=app:openReaderSourceSites(nil,nil,detail)
picker._back()
detail=presenter.library_view
eq(true,detail.alive,'returning from site picker restores a live book detail')
picker=app:openReaderSourceSites(nil,nil,detail)
picker:close();picker:on_select(candidate)
detail=presenter.library_view
eq(true,detail.alive,'selecting a site creates a usable detail screen')
eq(candidate,detail.book,'site selection retains the exact selected novel')
detail:startReading()
eq(1,reads,'reading still starts after selecting from detail')
local passed_options,opened_index
local chapters={{title='第一章'},{title='第二章'}}
app.reader_session={recoverIndex=function(_,list,progress)
    eq(chapters,list,'switch reuses the already verified catalog')
    eq('第二章',progress.chapter_title,'switch carries the old chapter title')
    return 2
end,open=function(_,source,chosen,list,index,options)
    passed_options,opened_index=options,index
    return {}
end}
service.getChapters=function() error('must not download the same catalog again') end
local handle=app:switchReaderSource({book=book,chapters=chapters,index=2,statistics_book_id='original-book'},candidate,function() end,
    {chapters=chapters,catalog_complete=true})
eq(2,opened_index,'site switch restores matching chapter position')
eq(true,passed_options.catalog_complete,'verified complete catalog stays complete')
eq('original-book',passed_options.statistics_book_id,'repeated source switches preserve the first statistics identity')
eq(true,passed_options.is_current(),'site switch can activate before cancellation')
handle:cancel()
eq(false,passed_options.is_current(),'cancelled switch rejects a late reader-ready callback')

local function throwing_request()
    return {cancel=function() error('completed request must not be cancelled') end}
end
local failed_detail=BookDetail.new({
    book=book, alternatives={book,candidate}, source_lookup=function() return sources[1] end,
    service={
        getBookInfo=function(_,_,_,done) done(nil,{code='PARSE_ERROR'}); return throwing_request() end,
        getChapters=function(_,_,_,done) done(nil,{code='PARSE_ERROR'}); return throwing_request() end,
    },
})
failed_detail:loadInfo()
eq(nil,failed_detail.info_request,'synchronous failed info request is not retained')
local switched_ok=pcall(failed_detail.switchSource,failed_detail,2)
eq(true,switched_ok,'switching source after failed info load cannot crash')
failed_detail=BookDetail.new({
    book=book, alternatives={book,candidate}, source_lookup=function() return sources[1] end,
    service={getChapters=function(_,_,_,done) done(nil,{code='PARSE_ERROR'}); return throwing_request() end},
})
failed_detail:loadCatalog()
eq(nil,failed_detail.catalog_request,'synchronous failed catalog request is not retained')
local catalog_switch_ok=pcall(failed_detail.switchSource,failed_detail,2)
eq(true,catalog_switch_ok,'switching source after failed catalog load cannot crash')

local pending_detail=BookDetail.new({
    book=book, alternatives={book,candidate}, source_lookup=function() return sources[1] end,
    service={getBookInfo=function() return throwing_request() end},
})
pending_detail:loadInfo()
eq(true,pcall(pending_detail.switchSource,pending_detail,2),'switching source cancels a throwing info request safely')
pending_detail=BookDetail.new({
    book=book, source_lookup=function() return sources[1] end,
    service={getChapters=function() return throwing_request() end},
})
pending_detail:loadCatalog()
eq(true,pcall(pending_detail.close,pending_detail),'closing detail cancels a throwing catalog request safely')

local downstream_app=App.new({storage={listSources=function() return sources end},book_service={},reader_session={
    recoverIndex=function() return 1 end,
    open=function() return {cancel=function() error('downstream cancel panic') end} end,
}})
local downstream_handle, downstream_error=downstream_app:switchReaderSource({book=book,chapters={{title='第一章'}},index=1},candidate,nil,
    {chapters={{title='第一章'}},catalog_complete=true})
eq(true,downstream_handle ~= nil, 'reader source switch returns a cancellation handle')
eq(nil, downstream_error, 'reader source switch accepts the selected source')
eq(true,pcall(downstream_handle.cancel,downstream_handle),'cancelling a reader source switch cannot crash')
return count
