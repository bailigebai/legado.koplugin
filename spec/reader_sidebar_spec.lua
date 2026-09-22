local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Sidebar=require('legado.ui.reader_sidebar')
local progress={reading_seconds=99};local fail=false
local app={storage={getProgress=function()return progress end,putProgress=function(_,p)
    if fail then return nil,{code='STORAGE_ERROR'} end;progress=p;return p end},
    reader_session={recoverIndex=function(_,chapters,bm)return bm.chapter_index end}}
local state={book={id='b',source_id='s'},chapters={{uid='one',title='第一章'}},index=1}
local doc={flushProgress=function()return true end,getProgressFraction=function()return .4 end}
local side={closed=false,switchTab=function(self,tab)self.tab=tab end,close=function(self)self.closed=true end}
local items=Sidebar.items(app,state,doc,side,'bookmarks')
eq('添加当前位置书签',items[1].text,'bookmark page offers add action')
assert(items[1].callback())
eq(1,#progress.reading_bookmarks,'one bookmark is stored')
eq(99,progress.reading_seconds,'bookmark action preserves reading statistics')
items=Sidebar.items(app,state,doc,side,'bookmarks')
eq(.4,items[2].fraction,'bookmark navigation retains saved position')
fail=true
local result=items[1].callback()
eq(nil,result,'failed bookmark removal is reported')
eq(1,#progress.reading_bookmarks,'failed removal preserves stored bookmarks')
fail=false;items[1].callback()
eq(0,#progress.reading_bookmarks,'toggle removes bookmark at current position')
items=Sidebar.items(app,state,doc,side,'bookmarks');items[1].callback()
items=Sidebar.items(app,state,doc,side,'bookmarks')
fail=true;eq(nil,items[2].delete_callback(),'failed long-press deletion preserves bookmark')
eq(1,#progress.reading_bookmarks,'failed deletion never mutates source table')
fail=false;assert(items[2].delete_callback());eq(0,#progress.reading_bookmarks,'confirmed deletion removes the selected mark')
-- Native local files use xpointer/page entries; online native chapters use
-- stable whole-book chapter bookmarks, never the generated HTML's sidecar.
doc.reader={bookmark={onToggleBookmark=function()error('online book touched local annotations')end},
    annotation={annotations={{text='local mark',page='xpointer'}}}}
items=Sidebar.items(app,state,doc,side,'bookmarks')
items[1].callback();items=Sidebar.items(app,state,doc,side,'bookmarks')
eq(1,items[2].index,'online native bookmark has a numeric chapter index')
items=Sidebar.items(app,nil,doc,side,'bookmarks')
eq('xpointer',items[2].xpointer,'local native bookmark retains its xpointer')
eq(nil,items[2].index,'local bookmark does not impersonate an online chapter')
progress.reading_bookmarks={{source_id='s',chapter_uid='one',chapter_index=1,title='Incomplete'}}
local safe,broken_items=pcall(Sidebar.items,app,state,doc,side,'bookmarks')
eq(true,safe,'incomplete saved bookmark does not crash bookmark tab')
eq(false,broken_items[2].enabled,'invalid saved position cannot trigger a jump')
local App=require('legado.ui.app')
table.pack=table.pack or function(...)return {n=select('#',...),...}end
package.loaded['ui/event']=dofile((os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader')..'/frontend/ui/event.lua')
local received
doc.reader.handleEvent=function(_,event)received=event end
local local_side=App.new{}:openReadingSideToc(nil,doc)
eq('function',type(local_side.switchTab),'local document without TOC still has a functional sidebar')
local_side:switchTab('bookmarks');local_side:_selectItem(local_side:menuItems()[2])
eq('onGotoXPointer',received.handler,'TOC-free native document navigates its bookmark')
eq('xpointer',received.args[1],'TOC-free bookmark preserves native position')
local_side:close()
return n
