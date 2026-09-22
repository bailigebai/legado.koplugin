local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Side=require('legado.ui.side_toc')
local function chapters(count)
    local t={};for i=1,count do t[i]={uid='c'..i,index=i,title='Chapter '..i}end;return t
end
local done,updates
updates=0
local side=Side.new{items=chapters(15),on_update=function()updates=updates+1 end,
    on_load_page=function(_,cb)done=cb;return {cancel=function()end}end}
eq(15,side.page_size,'default sidebar page has 15 readable rows')
side:prefetchNextPage()
eq(1,side.page,'warming next page must not move current page')
side:nextPage()
eq(2,side.page,'foreground takes over the warm page')
eq(true,side:menuItems()[1].loading,'missing page immediately replaces stale chapter rows')
side:previousPage();done(chapters(30),false)
eq(1,side.page,'late warm callback cannot change the page selected by user')
eq('Chapter 1',side:menuItems()[1].title,'visible chapter agrees with current page')
side:nextPage()
eq(15,#side:menuItems(),'only visible rows are built')
eq('Chapter 16',side:menuItems()[1].title,'next page shows its own chapters')
local snapshot=updates
side:setCurrent(side.current_index)
eq(snapshot,updates,'unchanged current chapter does not repaint sidebar')
side.on_tab_items=function(tab)return {{text=tab..' action'}}end
side:switchTab('bookmarks')
eq('bookmarks action',side:menuItems()[1].text,'bookmark tab uses its own page provider')
side:switchTab('toc')
eq('Chapter 16',side:menuItems()[1].title,'return from tabs preserves TOC page')
side:close()
-- The session may already be extending a three-chapter prefetch catalog.
-- A sidebar page request must not settle for that smaller shared result.
local App=require('legado.ui.app')
local state={book={id='b'},chapters=chapters(3),index=1,catalog_complete=false}
local calls,callbacks=0,{}
local session={active=state,loadCatalog=function(_,_,cb,_,options)
    calls=calls+1;callbacks[calls]=cb
    return {cancel=function()end}
end}
local drawer=App.new{reader_session=session}:openReadingSideToc(state,{})
drawer:goPage(2)
callbacks[1](chapters(4),nil,{catalog_complete=false})
eq(2,calls,'short shared response continues to requested sidebar page')
callbacks[2](chapters(30),nil,{catalog_complete=false})
eq('Chapter 16',drawer:menuItems()[1].title,'continued response supplies the requested visible page')
drawer:close()
-- A failed fetch belongs to that page, not every cached page in the drawer.
local replies={}
side=Side.new{items=chapters(15),on_load_page=function(page,cb)replies[page]=cb;return {cancel=function()end}end}
side:nextPage();replies[2](nil,false,{code='NETWORK_ERROR'})
side:previousPage()
eq('Chapter 1',side:menuItems()[1].title,'back from failed next page restores cached rows')
side:goPage(3);side:goPage(4)
replies[3](chapters(45),false)
eq(true,side.loading,'one completed page must not hide another pending request')
replies[4](nil,false,{code='NETWORK_ERROR'})
side:goPage(2)
eq('Chapter 16',side:menuItems()[1].title,'cached direct jump ignores another page failure')
side:close()
-- Missing providers must never leave an unfinishable loading state.
side=Side.new{items=chapters(3)}
side:requestPage(1)
eq(false,side:menuItems()[1].loading==true,'no transport does not leave a permanent spinner')
side:close()
local tab_count=31
side=Side.new{items=chapters(1),complete=true,on_tab_items=function()
    local items={};for i=1,tab_count do items[i]={text='Font '..i}end;return items
end}
side:switchTab('fonts');side:goPage(3);side:switchTab('fonts')
eq('Font 31',side:menuItems()[1].text,'applying a font preserves its selection page')
tab_count=30;side:switchTab('fonts')
eq('Font 16',side:menuItems()[1].text,'removing last item clamps tab to a populated page')
side:close()
return n
