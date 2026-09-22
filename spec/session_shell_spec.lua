local h=require('native_library_harness').install()
local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1;A.equal(a,b,m) end
local native={name='FileManager',file_chooser={path='/books'}}
local windows={native}
local watch,exposed=false,0
local function top() return windows[#windows] end
local function check() if watch and top()==native then exposed=exposed+1 end end
h.ui.show=function(_,w) windows[#windows+1]=w end
h.ui.close=function(_,w)
    for i=#windows,1,-1 do if windows[i]==w then table.remove(windows,i) end end
    if w.onCloseWidget then w:onCloseWidget() end
    check()
end
local scheduled={}
h.ui.scheduleIn=function(_,_,fn) scheduled[#scheduled+1]=fn end
local function tick() local pending=scheduled;scheduled={};for _,fn in ipairs(pending) do fn() end end
local dialog={new=function(_,v) return v end}
package.loaded['ui/widget/confirmbox']=dialog
package.loaded['apps/filemanager/filemanager']={instance=native,showFiles=function(_,path) eq('/books',path,'exit restores original directory');h.ui:show(native) end}
local app=require('legado.ui.app').new{storage={listShelf=function() return {} end,listSources=function() return {} end},
    book_service={search=function() return {cancel=function() end} end},download_manager={list=function() return {} end},scheduler=h.ui}
local presenter=require('legado.ui.presenter').new{app=app,ui_manager=h.ui,menu=dialog,input_dialog=dialog,info_message=dialog}
app.show=function(view) return presenter:show(view) end
app:openBookshelf();watch=true
app:openSearch()
eq(0,exposed,'search dialog keeps a plugin background instead of exposing FileManager')
eq(true,presenter.backdrop~=nil,'one persistent Legado background exists')
top().buttons[1][1].callback()
eq('bookshelf',presenter.library_view.kind,'cancel search returns to shelf')
app:openDownloads()
top().close_callback();tick()
eq('bookshelf',presenter.library_view.kind,'download manager return goes to shelf')
eq(0,exposed,'download return never exposes FileManager')
presenter:_startReading(function() return nil,{code='STORAGE_ERROR'} end)
eq('bookshelf',presenter.library_view and presenter.library_view.kind,'immediate startup failure restores a usable shelf')
h.ui:close(top())
eq(presenter.library_widget,top(),'dismissing startup failure leaves no frozen preparation screen')
local shelf=presenter.library_widget
shelf:onClose();tick()
eq(true,top().text:find('退出',1,true)~=nil,'leaving shelf requires an exit confirmation')
eq(true,shelf.alive,'confirmation retains shelf underneath')
h.ui:close(top()) -- cancel/dismiss the confirmation
eq(shelf,top(),'cancel exit keeps the same shelf')
eq(0,exposed,'all internal transitions retain Legado background')
shelf:onClose();tick();watch=false
local confirm=top();h.ui:close(confirm);confirm.ok_callback()
eq(nil,presenter.backdrop,'confirmed exit removes the Legado session background')
return count
