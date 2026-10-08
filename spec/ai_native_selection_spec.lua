local A=require('assertions')
require('native_library_harness').install()
local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local buttons,closed={},0
local reader={document={file='/mnt/us/book.mobi'},highlight={
    addToHighlightDialog=function(_,key,factory) buttons[key]=factory end,
    removeFromHighlightDialog=function(_,key) buttons[key]=nil end}}
local Plugin=dofile('legado.koplugin/main.lua')
local selected,document,result=nil,nil,true
local app={explainSelection=function(_,text,doc) selected,document=text,doc;return result end}
local plugin=setmetatable({ui=reader,_getApp=function() return app end},{__index=Plugin})
plugin:onReaderReady()
eq('function',type(buttons['11_legado_ai']),'ordinary local books have the same AI highlight entry')
local highlight={selected_text={text='从前一行到后一行\n完整的原句',pos0='xp0',pos1='xp1'},
    onClose=function() closed=closed+1 end}
local old=buttons['11_legado_ai'](highlight)
old.callback()
eq(highlight.selected_text.text,selected,'native cross-line selection is forwarded without reselecting or truncating')
eq(reader,document.reader,'ordinary local book supplies a live document context')
eq(1,closed,'successfully opening analysis closes the native selection dialog')
plugin:onCloseDocument()
eq(true,document.closed,'document close invalidates pending local-book AI results')
eq(nil,buttons['11_legado_ai'],'closing local books removes the AI entry')
selected=nil;old.callback()
eq(nil,selected,'cached native actions cannot analyze text from a closed book')
plugin:onReaderReady()
local stale=buttons['11_legado_ai'](highlight)
plugin:onReaderReady()
selected=nil;stale.callback()
eq(nil,selected,'reattaching invalidates old selection callbacks')
result=nil
buttons['11_legado_ai'](highlight).callback()
eq(1,closed,'failed AI opening keeps native selected text available')
local total=0;for key in pairs(buttons) do if key=='11_legado_ai' then total=total+1 end end
eq(1,total,'reader-ready notifications do not duplicate the AI entry')
plugin:onCloseDocument()
return n
