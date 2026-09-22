package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local Widget=require('ui/widget/widget')
package.loaded['ui/widget/iconwidget']=Widget:extend{getSize=function()return {w=24,h=24}end}
package.loaded['apps/filemanager/filemanager']={}
package.loaded['apps/reader/readerui']={}
local Side=require('legado.ui.side_toc')
local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local function chapters(count)
    local t={};for i=1,count do t[i]={uid='c'..i,index=i,title='Chapter '..i}end;return t
end
local side=Side.new{items=chapters(45),complete=true}
local widget=assert(side:show())
widget:handleEvent(require('ui/event'):new('Close'))
eq(true,side.closed,'native Back/Close event closes the full drawer, not its nested Menu')
eq(widget,h.closed[#h.closed],'the mounted overlay is removed')
side=Side.new{items=chapters(45),complete=true};side:show()
side:goPage(2)
eq(true,side.menu.page_info:getSize().w<=side.refresh_region.w,'footer controls stay inside the narrow drawer')
eq(true,side.menu.page_info_first_chev.enabled,'first-page control follows model page')
eq(true,side.menu.page_info_last_chev.enabled,'last-page control follows model count')
eq(true,side.menu.page_info_text.enabled,'page-number control remains usable with sliced menu entries')
side.menu:onLastPage()
eq('Chapter 31',side.menu.item_table[1].title,'last-page action opens real last page')
side.menu:onFirstPage()
eq('Chapter 1',side.menu.item_table[1].title,'first-page action opens first page')
local button=side.menu.page_info_text
local closed_input=false
button.input_dialog={getInputText=function()return '2'end}
button.closeInputDialog=function()closed_input=true end
local buttons=button.hold_input.buttons
buttons[#buttons][#buttons[#buttons]].callback()
eq(2,side.page,'page-number dialog accepts a model page beyond internal slice page 1')
eq(true,closed_input,'valid page jump closes its input')
side:close()
local many={};for i=1,15000 do many[i]={uid='long'..i,index=i,title='Chapter '..i}end
side=Side.new{items=many,complete=true};side:show();side:goPage(999)
eq(true,side.menu.page_info:getSize().w<=side.refresh_region.w,'long-novel page counts cannot overflow the drawer')
eq(side.footer_page_width,side.menu.page_info_text:getSize().w,'page label keeps its width after native Menu updates')
side:close()
-- Key return also works while another tab is active, and a late page dialog
-- cannot revive a drawer that has already closed.
side=Side.new{items=chapters(45),complete=true,on_tab_items=function()return {{text='Font'}}end}
widget=assert(side:show());side:switchTab('fonts')
widget:handleEvent(require('ui/event'):new('Close'))
eq(true,side.closed,'Back closes a non-TOC tab through the same owner')
-- Exercise the real InputContainer.onInput flow with a lightweight keyboard
-- window, so host closure cannot leave a live child dialog over another book.
package.loaded['ui/widget/inputdialog']=Widget:extend{
    onShowKeyboard=function()end,getInputText=function(self)return self.input end,
}
side=Side.new{items=chapters(45),complete=true};side:show()
button=side.menu.page_info_text
button:onInput(button.hold_input)
local dialog=button.input_dialog
eq(dialog,h.shown,'page input opens as a separate native window')
side:close()
local dialog_closed=false;for _,closed in ipairs(h.closed)do if closed==dialog then dialog_closed=true end end
eq(true,dialog_closed,'closing the drawer also closes its page input window')
eq(nil,button.input_dialog,'closed input window is no longer retained')
-- Incomplete catalogs cannot offer an end-of-book fetch by accident.
side=Side.new{items=chapters(15),complete=false};side:show()
eq(false,side.menu.page_info_last_chev.enabled,'unknown last page is unavailable until catalog is complete')
side:close()
return n
