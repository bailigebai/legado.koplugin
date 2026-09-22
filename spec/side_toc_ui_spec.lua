package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local graph_stub=package.loaded.depgraph
package.loaded.depgraph=nil
for key,value in pairs(require('depgraph')) do graph_stub[key]=value end
local Widget=require('ui/widget/widget')
package.loaded['ui/widget/iconwidget']=Widget:extend{getSize=function() return {w=24,h=24} end}
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local SideToc=require('legado.ui.side_toc')
local items={}
for i=1,45 do items[i]={uid='c'..i,title='第'..i..'章',index=i} end
local toc=SideToc.new{items=items,complete=false,current_index=1}
local widget,err=toc:show()
eq(true,widget~=nil,'side TOC creates a KOReader overlay')
eq(nil,err,'overlay construction has no error')
eq(true,toc:isOpen(),'overlay is open after show')
local dirty,region
local set_dirty=h.ui.setDirty
h.ui.setDirty=function(self,owner,kind,rect)dirty=owner;region=rect;return set_dirty(self,owner,kind,rect)end
toc:nextPage()
eq('第16章',toc.menu.item_table[1].title,'native Menu receives new current page content')
eq(15,#toc.menu.item_table,'native Menu receives exactly 15 visible entries')
eq(widget,dirty,'redraw targets the mounted overlay, not a detached menu')
eq(0,region.x,'left sidebar uses left screen region')
eq(276,region.w,'redraw remains bounded to sidebar width')
toc:previousPage();eq('第1章',toc.menu.item_table[1].title,'backward paging paints the previous chapter list')
toc.on_tab_items=function()local out={};for i=1,31 do out[i]={text='Font '..i}end;return out end
toc:switchTab('fonts');toc:nextPage()
eq('Font 16',toc.menu.item_table[1].text,'tab pagination is independent from TOC pagination')
toc:nextPage();eq('Font 31',toc.menu.item_table[1].text,'third font page stays reachable')
toc:switchTab('toc');eq('第1章',toc.menu.item_table[1].title,'switching back restores TOC position')
toc.on_select=function(_,done)done(false,{code='NETWORK_ERROR',message='测试：章节暂时无法加载'})end
toc:select(1)
eq('测试：章节暂时无法加载',h.shown.text,'failed chapter selection shows an actionable message')
eq('第1章',toc.menu.item_table[1].title,'chapter failure leaves the usable catalog visible')
h.ui.setDirty=set_dirty
local frees=0
local free=widget.free
widget.free=function(self,...)frees=frees+1;return free(self,...)end
widget:onGesture{ges='tap',pos={x=550,y=400,w=0,h=0}}
eq(false,toc:isOpen(),'closing removes the side overlay')
eq(1,frees,'closing releases the sidebar widget tree')
toc:close();eq(1,frees,'repeated close does not free twice')
eq(0,#h.tasks,'side TOC does not create background preparation jobs')
local App=require('legado.ui.app')
local state={book={id='b',source_id='s'},chapters={{uid='c1',title='One'}},index=1,catalog_complete=true}
local app=App.new{storage={getProgress=function()return {reading_bookmarks={{source_id='other',chapter_uid='c2',fraction=.3,chapter_index=2}}}end},
    reader_session={active=state,navigate=function()return nil,{code='INVALID_INPUT',message='Other source'}end}}
local side=app:openReadingSideToc(state,{getProgressFraction=function()return .1 end})
side:show();side:switchTab('bookmarks')
local notices=0;local show=h.ui.show
h.ui.show=function(self,widget)notices=notices+1;return show(self,widget)end
side:_selectItem(side:menuItems()[2])
eq(1,notices,'one failed bookmark tap must not stack duplicate error dialogs')
h.ui.show=show;side:close()
return n
