require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Settings=require('legado.lib.settings');local s=Settings.new({})
local Storage=require('legado.lib.storage')
local fail=false
local storage=Storage.new{sqlite_loader=function() end,fs={read=function() end,atomicWrite=function() if fail then return nil,{code='STORAGE_ERROR'} end;return true end}}
storage:createBook{id='a',name='A',custom_categories={'科幻','想读'}}
storage:createBook{id='b',name='B',custom_categories={'科幻'}}
local Category=require('legado.lib.shelf_categories')
local c=Category.new(storage,s)
eq(2,#c:list(),'existing book categories remain editable')
eq('旅行,散文',c:add('  旅行,散文  '),'one name is stored whole, never comma-split')
eq(nil,c:add('旅行,散文'),'duplicate category reports validation failure')
eq(nil,c:add('  '),'empty category rejected')
fail=true;eq(nil,c:remove('科幻'),'failed write is not reported as deleted')
eq('科幻',storage:getBook('a').custom_categories[1],'failed batch preserves all books')
fail=false;eq(true,c:remove('科幻'),'category can be deleted')
eq('想读',storage:getBook('a').custom_categories[1],'other category retained')
eq(0,#storage:getBook('b').custom_categories,'deleted category removed from every book')
eq(2,#storage:listShelf(),'deleting category never deletes books')
local p=require('legado.ui.presenter').new{app={storage=storage,settings=s},ui_manager={show=function() end,close=function() end}}
local m=p:_editCategories(function() return true end)
eq('编辑分类',m.title,'list editor is available')
eq('添加分类',m.item_table[1].text,'one-at-a-time add action is visible')
storage:updateBook('a',{custom_categories={'旧分类'}})
local original_set=s.set
local writes=0
s.set=function(self,key,value) writes=writes+1;if writes==2 then return nil,{code='STORAGE_ERROR'} end;return original_set(self,key,value) end
eq(nil,c:remove('旧分类'),'final registry failure reports incomplete removal')
local found=false;for _,name in ipairs(c:list()) do if name=='旧分类' then found=true end end
eq(true,found,'legacy category remains visible for retry after second-store failure')
s.set=original_set
eq(true,c:remove('旧分类'),'retry completes incomplete removal')
return n
