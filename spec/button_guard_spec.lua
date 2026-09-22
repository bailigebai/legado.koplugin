require("library_screen_stub")
local A=require("assertions")
local Presenter=require("legado.ui.presenter")
local Catalog=require("legado.ui.catalog")
local shown={}
local function screen(options) options.kind="library_screen";shown[#shown+1]=options;return options end
local p=Presenter.new{library_screen_factory=screen,ui_manager={show=function() end,close=function() end}}
local chapters={};for i=1,49 do chapters[i]={index=i,title="第"..i.."章",uid="c"..i} end
local view=Catalog.new(chapters);view._back=function() return true end
local menu=p:_catalog(view)
A.equal(15,#menu.items,"catalog page shows fifteen chapters")
A.equal("上20页",menu.actions[1].text,"catalog has backward jump")
A.equal("下20页",menu.actions[3].text,"catalog has forward jump")
menu.actions[3].callback()
A.equal(4,view.display_page,"forward jump moves twenty pages")
local page3=shown[#shown]
page3.actions[1].callback()
A.equal(1,view.display_page,"backward jump returns twenty pages")
local page1=shown[#shown]
page1.actions[2].callback()
A.equal(true,view.reverse,"order toggle is wired")
local ok=pcall(function() page1.items[1].callback() end)
A.equal(true,ok,"chapter callback never escapes to KOReader")
local search_view={kind="search",alive=true,service={}}
local dialog=p:_search(search_view)
local cancelled=pcall(function() dialog.buttons[1][1].callback() end)
A.equal(true,cancelled,"search cancel returns safely to the plugin shelf")
local guarded=p:_modelMenu({close=function() end},{item_table={{text="坏按钮",callback=function() error("boom") end}}})
local safe=pcall(function() guarded.item_table[1].callback() end)
A.equal(true,safe,"menu callback errors are contained")
local source={id="source-a"}
local source_book={name="书名",author='作者',source_id=require("legado.lib.models").sourceId(source),url="https://a/book"}
local searched,chapter_requested=false,false
local app=require("legado.ui.app").new{book_service={
    search=function(_,_,_,_,cb) searched=true;cb({groups={{book=source_book}}});return {cancel=function() end} end,
    getChapters=function(_,_,_,cb) chapter_requested=true;cb({{index=1,uid="c",title="第一章",url="https://a/c"}},nil,{catalog_complete=true});return {cancel=function() end} end},
    storage={listSources=function() return {source} end}, reader_session={open=function() end}, show=function() end}
local sources=app:openReaderSources({book={name="书名",author='作者',source_id=source_book.source_id},index=1},{})
A.equal(true,searched,"reader source switch searches the same title")
sources.on_select(sources,source_book)
A.equal(true,chapter_requested,"reader source switch loads the selected catalog")
return 12
