-- Production App -> Presenter -> LibraryScreen with unmodified KOReader widgets.
local native = require("native_library_harness").install()
package.loaded['ui/widget/confirmbox']={new=function(_,options) return options end}
local A = require("assertions")
local count=0
local function equal(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local function truthy(actual,message) count=count+1;A.truthy(actual,message) end
local function copy(value)
    if type(value)~="table" then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end

local shown,windows={},{}
native.ui.show=function(_,widget) shown[#shown+1]=widget;windows[widget]=true;if widget.getSize then widget:getSize() end end
native.ui.close=function(_,widget) windows[widget]=nil;if widget.onCloseWidget then widget:onCloseWidget() end end

local Presenter=require("legado.ui.presenter")
local App=require("legado.ui.app")
local books,progress,callbacks,cancels={},{},{},0
local storage={listShelf=function() return copy(books) end,getProgress=function(_,id) return progress[id] end}
local presenter=Presenter.new{ui_manager=native.ui,cover_loader=function(book,callback)
    callbacks[book.id]=callback
    if book.id=="cached" then callback("cached.jpg") end
    return {cancel=function() cancels=cancels+1 end}
end}
local app=App.new{storage=storage,show=function(view) return presenter:show(view) end,
    cover_loader=function(book,callback)
        callbacks[book.id]=callback
        if book.id=="cached" then callback("cached.jpg") end
        return {cancel=function() cancels=cancels+1 end}
    end}
presenter.app=app -- Same binding as production Bootstrap.

local empty=app:openHome()
local empty_screen=shown[#shown]
equal("bookshelf",empty.kind,"production App opens the complete shelf")
equal("library_screen",empty_screen.kind,"empty Home reaches the native fullscreen library")
equal(0,#empty_screen.cells,"empty Home has a strong empty body instead of a fake menu")
truthy(empty_screen:getSize().w<=600 and empty_screen:getSize().h<=800,"empty Home fits 600x800")

books={{id="recent",name="最近阅读",author="作者甲",intro="简介甲",cover_url="https://cover.test/1"},
    {id="cached",name="已缓存封面",author="作者乙",intro="简介乙",cover_url="https://cover.test/2"},
    {id="unread",name="尚未读过"}}
progress={recent={updated_at=20},cached={updated_at=10}}
local home=app:openHome()
local screen=shown[#shown]
equal("library_screen",screen.kind,"populated Home uses LibraryScreen")
equal(3,#screen.cells,"default shelf includes unread books")
equal("cached.jpg",screen.cells[2].cover[1].file,"synchronous cached cover reaches ImageWidget")
local old_height=screen:getSize().h
callbacks.recent("recent.jpg")
equal("recent.jpg",screen.cells[1].cover[1].file,"asynchronous cover reaches the visible card")
equal(old_height,screen:getSize().h,"cover arrival does not move controls")
truthy(native.dirty>0,"cover arrival requests an e-ink repaint")

presenter.detail_factory=function(book)
    return {kind="book_detail",book=book,info={author="Writer"},alternatives={},
        startReading=function(_,callback) callback({},nil);return {} end}
end
screen.cells[1].button.callback()
equal(nil,windows[screen],"book selection replaces the Home screen")
equal(true,home.alive,"detail replacement preserves Home controller for Back navigation")
equal("library_screen",shown[#shown].kind,"selection opens native detail screen")
local detail=shown[#shown]
local read_button
for _,row in ipairs(detail.layout) do
    for _,button in ipairs(row) do
        if button.text=="开始阅读" or button.text=="继续阅读" then read_button=button end
    end
end
truthy(read_button,"native detail exposes a reachable start/resume-reading button")
read_button.callback()
equal(presenter.backdrop,next(windows),"starting the reader retains the session background below the document")

local nav_home=app:openHome()
local nav_screen=shown[#shown]
local shelf_button
for _,row in ipairs(nav_screen.layout) do
    for _,button in ipairs(row) do if button.text=="书架" then shelf_button=button end end
end
truthy(shelf_button,"bottom navigation is focus/touch reachable")
shelf_button.callback()
equal(nil,windows[nav_screen],"navigation replaces the old Home screen")
equal(false,nav_home.alive,"navigation closes the old Home controller")
local shelf=shown[#shown]
equal("library_screen",shelf.kind,"navigation opens shelf as native library")
shelf:onClose()
equal(true,windows[shelf],"Back keeps shelf visible while requesting confirmation")
shelf:closeForReplacement()
truthy(cancels>=4,"screen replacement and close cancel outstanding cover handles")
local dirty_after=native.dirty
callbacks.recent("ignored.jpg")
equal(dirty_after,native.dirty,"closed screens ignore late image completion")

return count
