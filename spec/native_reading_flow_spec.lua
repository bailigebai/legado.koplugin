local A=require('assertions')
local count=0
local function eq(a,b,m) count=count+1;A.equal(a,b,m) end
local h=require('native_library_harness').install()
local storage=require('legado.lib.storage').new{sqlite_loader=function() end,
    fs={read=function() end,atomicWrite=function() return true end}}
local date=os.date('%Y-%m-%d')
for i=1,8 do storage:putProgress{book_id='b'..i,book_snapshot={id='b'..i,name='书籍'..i},
    reading_seconds=120,reading_daily={[date]=120}} end
local app=require('legado.ui.app').new{storage=storage,license={isAuthorized=function() return true end}}
local presenter=require('legado.ui.presenter').new{app=app,ui_manager=h.ui}
app.show=function(view) return presenter:show(view) end
app:openReadingReview()
local widget=presenter.library_widget
eq(true,widget.reading_body~=nil,'production presenter dispatches to native custom reading body')
eq(true,widget.content:getSize().h<=widget.content_height,'native dashboard fits within its screen')
-- Header is row 1; reference tabs form row 2 in the real FocusManager layout.
widget.layout[2][3].callback()
widget=presenter.library_widget
eq(6,#widget.cells,'native book grid receives six actual saved books')
eq(true,widget.content:getSize().h<=widget.content_height,'six book cards fit above the new background action')
local first=widget.cells[1]
first.button:onTapSelect()
widget=presenter.receipt_widget
eq(5,#widget.rating_buttons,'native card tap opens interactive receipt')
eq(true,widget.covers_fullscreen,'book history receipt hides the underlying record grid with a background')
widget.rating_buttons[4].callback()
eq(4,storage:getProgress(first.book.id).reading_rating,'native star persists for the tapped book')
presenter.receipt_widget:onClose()
eq(6,#presenter.library_widget.cells,'real return closes receipt and restores book grid')
presenter.library_widget.layout[2][2].callback()
eq(true,presenter.library_widget.reading_body~=nil,'calendar retains native custom body after switching')
eq(true,presenter.library_widget.content:getSize().h<=800,'calendar day pagination fits actual native shell')
return count
