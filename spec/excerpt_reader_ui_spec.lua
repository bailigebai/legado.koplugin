package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local Context=require('legado.lib.excerpt_context')
local buttons,closed={},0
local reader={highlight={addToHighlightDialog=function(_,key,factory) buttons[key]=factory end,
 removeFromHighlightDialog=function(_,key) buttons[key]=nil end}}
local result=false;local text,document,range
local function capture(t,d,r) text,document,range=t,d,r;return result end
Context.attach(reader,capture)
Context.attach(reader,capture,{reading_state={book={name='书源'}}})
local count=0;for _ in pairs(buttons) do count=count+1 end
eq(1,count,'native and source adapters share one highlight entry')
local highlight={selected_text={text='原句',pos0='xp0',pos1='xp1'},onClose=function() closed=closed+1 end}
buttons[Context.BUTTON](highlight).callback()
eq('原句',text,'native selected text passed through')
eq('xp0',range.pos0,'location captured before selection cleared')
eq('书源',document.reading_state.book.name,'generated reader keeps original book context')
eq(0,closed,'failed save leaves native selection available for retry')
result=true;buttons[Context.BUTTON](highlight).callback();eq(1,closed,'successful save closes native selection')
Context.detach(reader);eq(nil,buttons[Context.BUTTON],'reader cleanup removes button')
reader.document={file='/mnt/us/test.mobi'}
Context.attach(reader,capture)
local old=buttons[Context.BUTTON](highlight);local before_closed=closed;text=nil
Context.detach(reader);reader.document=nil
eq(false,old.callback(),'closing local document invalidates existing selection callback')
eq(nil,text,'closed local book cannot capture stale text')
eq(before_closed,closed,'expired callback leaves unrelated UI alone')
local View=require('legado.ui.leko_reader')
local selected,selected_range,failed=nil,nil,true
local view=assert(View.new{book={name='无感书'},chapter={title='第一章'},index=1,count=1,body='<p>优秀的句子值得摘录。</p>',
 callbacks={excerpt=function(_,t,r) selected=t;selected_range=r;if failed then return nil,{code='STORAGE_ERROR'} end;return true end}})
h.ui:show(view)
local selection={text=function() return '优秀的句子' end,range=function() return {paragraph=1,char=1},{paragraph=1,char=6} end}
view.selection=selection;view:showSelectionActions()
local function find()
 for _,row in ipairs(view.selection_dialog.buttons) do for _,button in ipairs(row) do if button.text=='摘录到 Obsidian' then return button end end end
end
eq(true,find()~=nil,'immersive selection offers Obsidian capture')
find().callback();eq(selection,view.selection,'failed save preserves immersive selection')
failed=false;view:showSelectionActions();find().callback()
eq('优秀的句子',selected,'immersive captures exact selection')
eq(6,selected_range.last.char,'immersive range includes end character')
eq(nil,view.selection,'successful capture clears selection')
view:close()
-- Refresh replaces a manager menu; back must not leave an old copy underneath.
local Presenter=require('legado.ui.presenter')
local shown,hidden={},{}
local presenter=Presenter.new{menu={new=function(_,options) return options end},
 info_message={new=function(_,options) return options end},ui_manager={
 show=function(_,w) shown[#shown+1]=w end,close=function(_,w) hidden[w]=true end}}
local callback
local service={busy=false,list=function() return {} end,schedule=function() end,
 client={config=function() return {folder='阅读摘录'} end,testConnection=function(_,cb) callback=cb end}}
local manager=presenter:showExcerpts(service)
local function button(w,text) for _,item in ipairs(w.item_table) do if item.text==text then return item end end end
button(manager,'刷新列表').callback()
eq(true,hidden[manager],'refresh closes previous manager widget')
local refreshed=shown[#shown]
button(refreshed,'测试连接').callback();refreshed.close_callback()
local before=#shown;callback(true)
eq(before+1,#shown,'selection naturally closes menu but connection result remains visible')
manager=presenter:showExcerpts(service)
button(manager,'测试连接').callback();manager.close_callback()
local progress=shown[#shown]
if progress.onCloseWidget then progress:onCloseWidget() end
before=#shown;callback(true)
eq(before,#shown,'dismissed connection operation ignores late result')
return n
