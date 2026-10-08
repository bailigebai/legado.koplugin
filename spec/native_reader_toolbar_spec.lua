local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local state=require('native_library_harness').install()
package.loaded.pluginloader={genPluginManagerSubItem=function() return {} end}
package.loaded.datastorage={getSettingsDir=function() return '/settings' end}
package.loaded['libs/libkoreader-lfs']={attributes=function() return nil end}
package.loaded['ffi/util']={template=function(s) return s end,orderedPairs=pairs}
setmetatable(package.loaded.device,{__index=function() return function() return false end end})
-- External settings providers are outside this test; ReaderMenu + MenuSorter stay native.
local native_dofile=dofile
dofile=function(path)
    if path:find('^frontend/ui/elements/') then return {} end
    return native_dofile(path)
end
local ReaderMenu=require('apps/reader/modules/readermenu')
local reader={document={file='chapter.html'},onClose=function() end,handleEvent=function() end}
reader.highlight={selected_text={text='庄周梦蝶'},onClose=function() end,
    addToHighlightDialog=function(self,key,button) self[key]=button end,
    removeFromHighlightDialog=function(self,key) self[key]=nil end}
reader.menu=ReaderMenu:new{ui=reader}
local Adapter=require('legado.lib.koreader_reader_ui')
local toc_calls,toggle_calls,ai_text=0,0,nil
local site_calls, chrome_calls, receipt_calls,statistics_calls = 0, 0, 0,0
local adapter=Adapter.new{ReaderUI={showReader=function(_,_,_,_,_,ready) ready(reader) end},on_toc=function() toc_calls=toc_calls+1 end,
    on_receipt=function() receipt_calls=receipt_calls+1 end,on_source_sites=function() site_calls=site_calls+1 end,
    on_chrome_settings=function() chrome_calls=chrome_calls+1 end,on_statistics=function() statistics_calls=statistics_calls+1 end,
    on_toggle_reader=function() toggle_calls=toggle_calls+1;return true end,
    on_ai=function(text) ai_text=text;return true end}
adapter:openDocument('chapter.html',{end_of_book=function() end})
eq('function',type(reader.highlight['11_legado_ai']),'native highlight dialog offers AI explanation')
reader.highlight['11_legado_ai'](reader.highlight).callback()
eq('庄周梦蝶',ai_text,'native selection is delivered to AI')
reader.menu:setUpdateItemTable()
eq(true,reader.menu.tab_item_table[1].legado_reader,'unmodified native menu sorter exposes toolbar first')
for _, entry in ipairs(reader.menu.tab_item_table[1]) do
    eq(false, entry.text == '阅读回顾', 'native reading toolbar does not repeat the shelf review entry')
end
eq(8,#reader.menu.tab_item_table[1],'native tab includes reader mode and task-specific tools')
eq('无感阅读：启用',reader.menu.tab_item_table[1][8].text,'mode toggle is present in the native top tab')
reader.menu.tab_item_table[1][8].callback()
eq(1,toggle_calls,'native top tab invokes the real mode-switch callback')
reader.menu.tab_item_table[1][7].callback()
eq(1,statistics_calls,'native toolbar statistics button invokes its real callback')
reader.menu.tab_item_table[1][1].callback()
eq(1,toc_calls,'native tab opens web chapter catalog')
reader.menu.tab_item_table[1][6].callback()
eq(1,receipt_calls,'native tab opens current book receipt')
reader.menu.tab_item_table[1][4].callback()
eq(1,site_calls,'native tab opens site source picker')
reader.menu.tab_item_table[1][5].callback()
eq(1,chrome_calls,'native tab opens header/footer settings directly')
local tabs=#reader.menu.tab_item_table
ReaderMenu.init(reader.menu) -- native sorting consumes menu_items; rebuild from initialized providers
reader.menu:setUpdateItemTable()
eq(tabs,#reader.menu.tab_item_table,'menu rebuild never duplicates toolbar')
eq(1,reader.menu:_getTabIndexFromLocation({pos={x=599}}),'native right-hand activation selects toolbar')
local LibraryScreen=require('legado.ui.library_screen')
local books={};for i=1,12 do books[i]={title='Book '..i,book={id=tostring(i),is_local=true}} end
local covers=0
local shelf=LibraryScreen.new{title='本地书架',items=books,mode='grid',compact=true,
    header_action={text='书源书架',callback=function() end},
    cover_loader=function(_,cb) covers=covers+1;cb(nil);return {cancel=function() end} end}
eq(12,covers,'cover extraction runs even without a remote URL')
eq('书源书架',shelf.layout[1][2].text,'local shelf switch stays in header')
eq(true,shelf.content:getSize().h<=shelf.content_height,'local twelve-cover shelf fits native 600x800 layout')
local progress=LibraryScreen.new{title='正在准备章节',compact=true,progress=.25,items={},navigation={}}
eq(true,progress.content:getSize().h<=progress.content_height,'native progress widget fits loading screen')
local old_ai=reader.highlight['11_legado_ai'](reader.highlight)
reader:onClose()
eq(nil,reader.highlight['11_legado_ai'],'AI action is removed when plugin reader closes')
ai_text=nil;old_ai.callback()
eq(nil,ai_text,'old native selection cannot send AI after the document closes')
return count
