local A=require('assertions')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local function truth(value,m) n=n+1;A.truthy(value,m) end

local SideToc=require('legado.ui.side_toc')
local function chapters(count,offset)
    local values={}
    for i=1,count do
        local index=(offset or 0)+i
        values[i]={uid='c'..index,title='第'..index..'章',index=index}
    end
    return values
end

local requested={}
local callbacks={}
local toc=SideToc.new{items=chapters(24),current_index=5,complete=false,page_size=24,
    on_load_page=function(page,done)
        requested[#requested+1]=page;callbacks[page]=done
        return {cancel=function() end}
    end}
eq(1,toc:pageCount(),'one known page')
eq(24,#toc:pageItems(1),'page is limited to 24 items')
eq(true,toc:pageItems(1)[5].current,'current chapter is highlighted')
eq(nil,toc:requestPage(1),'a complete known page does not request again')
eq(0,#requested,'known page does not touch the network')
truth(toc:requestPage(2),'missing page starts a request')
eq(1,#requested,'missing page requests once')
truth(toc:requestPage(2),'duplicate missing-page request is coalesced')
eq(1,#requested,'duplicate page does not start a second request')
callbacks[2](chapters(24,24),false)
eq(2,toc:pageCount(),'loaded page is available')
eq('第25章',toc:pageItems(2)[1].title,'loaded page starts at the next chapter')
eq(nil,toc:requestPage(2),'loaded page does not request again')
eq(true,toc:pageItems(2)[1].current==false,'current marker remains tied to the active chapter')
local menu_items=toc:menuItems()
eq(24,#menu_items,'menu builds only requested page rows')
eq('第25章',menu_items[1].title,'loaded page follows the known catalog')

local closed_callback
local closed=SideToc.new{items=chapters(24),complete=false,on_load_page=function(_,done)
    closed_callback=done;return {cancel=function() end}
end}
truth(closed:requestPage(2),'second model request starts')
closed:close()
closed_callback(chapters(24,24),true)
eq(1,closed:pageCount(),'late callback cannot repopulate a closed sidebar')

local selected
local select_toc=SideToc.new{items=chapters(2),complete=true,on_select=function(item,done)
    selected=item;done(true)
end}
eq(true,select_toc:select(2),'chapter selection is forwarded')
eq('c2',selected.uid,'selection receives the chapter item')
eq(nil,select_toc:select(3),'out-of-range selection is rejected')

local App=require('legado.ui.app')
local online_state={book={id='book',source_id='source'},chapters=chapters(3),index=1,catalog_complete=false,active=true}
local catalog_request
local navigated
local online_session={active=online_state,
    loadCatalog=function(_,state,callback,_,options)
        catalog_request={state=state,max_chapters=options.max_chapters}
        local values=chapters(48)
        state.chapters=values;state.catalog_complete=false
        callback(values,nil,{catalog_complete=false})
        return {cancel=function() end}
    end,
    navigate=function(_,index,options)
        navigated=index;options.on_complete({backend='immersive'},nil)
        return {backend='immersive'}
    end}
local online=App.new{reader_session=online_session,settings={get=function(_,key)
    return key=='side_toc_position' and 'left' or nil
end}}
local side=online:openReadingSideToc(online_state,{})
eq(3,side:knownCount(),'online side TOC starts with the partial catalog')
side:nextPage()
eq(30,catalog_request.max_chapters,'missing side page asks only for its 15-row target')
eq(2,side.page,'loaded side page becomes current')
side:select(1)
eq(16,navigated,'selecting a side entry navigates the matching chapter')

return n
