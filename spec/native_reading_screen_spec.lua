-- Real KOReader widgets with desktop-only font, display and image service shims.
local state = require("native_library_harness").install()
local A = require("assertions")
local Screen = require("legado.ui.library_screen")
local count = 0
local function check(value, message) count=count+1; A.truthy(value,message) end
local function equal(want,actual,message) count=count+1; A.equal(want,actual,message) end
local function noop() end
local periods, selected_day, selected_book, status, rating = 0
local book={id="sample",name=string.rep("长书名",20),author="示例作者",coverUrl="cover"}
local categories={{text="累计时长",callback=noop},{text="每日时长",callback=noop},{text="阅读书籍",callback=noop}}
local overview={kind="overview",total_seconds=9010,reading_days=10,average_seconds=901,year=2026,months={},week={},
    unattributed_seconds=3600,on_period_change=function(delta) periods=periods+delta end}
for i=1,12 do overview.months[i]={label=i.."月",seconds=i==8 and 7500 or 0} end
for i=1,7 do overview.week[i]={label="周"..i,seconds=i==1 and 180 or 0} end
local daily={kind="daily",year=2026,month=8,selected_day="2026-08-15",calendar={},day_total=2046,month_days=6,
    day_books={{book=book,seconds=1881},{book=book,seconds=45},{book=book,seconds=120}},on_period_change=overview.on_period_change,
    on_day=function(day) selected_day=day end,on_book=function(value) selected_book=value end}
for i=1,42 do local day=i-5;daily.calendar[i]=day>0 and day<=31 and {day=day,date=string.format("2026-08-%02d",day),seconds=day==15 and 2046 or 0} or {} end
local books={kind="books",records={},on_book=daily.on_book}
for i=1,6 do books.records[i]={book=book,seconds=1800,progress_text="约 30%",fraction=.3} end
books.records[1].fraction=nil
local receipt={kind="receipt",book=book,seconds=108115,day_count=36,position_label="已读章节",position_text="773/795",
    progress_text="约 97%",chapter_title=string.rep("长章节名称",10),status="finished",rating=4,date_text="2026-09-12",receipt_id="sample",
    on_status=function(value) status=value end,on_rating=function(value) rating=value end}
local function find(widget,text)
    for _,row in ipairs(widget.layout) do for _,button in ipairs(row) do if button.text==text then return button end end end
end
local function paint_and_check(screen)
    local painted={}
    local bb=setmetatable({}, {__index=function(_,name)
        if name=="getWidth" then return function() return state.dimensions.w end end
        if name=="getHeight" then return function() return state.dimensions.h end end
        return function() painted[name]=true end
    end})
    screen:paintTo(bb,0,0)
    check(painted.paintRect or painted.paintBorder,"reading content paints to the native buffer")
    local function inspect(node)
        if node.spots then for i,child in ipairs(node) do
            local p,size=node.spots[i],child:getSize()
            check(p[1]>=0 and p[2]>=0 and p[1]+size.w<=node.dimen.w+1 and p[2]+size.h<=node.dimen.h+1,
                "painted child fits its actual parent: "..tostring(child.text))
        end end
        for _,child in ipairs(node) do inspect(child) end
    end
    inspect(screen.reading_body)
end
local function tap(screen,control)
    local dimen=control.dimen
    local pos=require("ui/geometry"):new{x=dimen.x+dimen.w/2,y=dimen.y+dimen.h/2}
    check(screen:handleEvent(require("ui/event"):new("Gesture",{ges="tap",pos=pos})),"painted touch reaches its control through the full native tree")
end
G_reader_settings.isFalse=function(_,name) return name=="flash_ui" end
for _,dimensions in ipairs{{600,800},{1200,1600}} do
    state.dimensions.w,state.dimensions.h=dimensions[1],dimensions[2]
    local ratio=dimensions[1]/600
    state.screen.scaleBySize=function(_,n) return math.floor(n*ratio+.5) end
    -- Font:getFace already applies device scaling in KOReader.
    package.loaded["ui/font"].getFace=function(_,_,size) size=size or 20;return {size=size*ratio,orig_size=size,
        ftsize={getHeightAndAscender=function() return size*ratio,math.floor(size*ratio*.75) end}} end
    for _,model in ipairs{overview,daily,books,receipt} do
        local opts={title="阅读回顾",subtitle=model.kind~="receipt" and "全部书籍" or "",compact=true,reading_model=model,
            categories=model.kind~="receipt" and categories or nil}
        if model.kind=="receipt" then opts.actions={{text="阅读回顾",callback=noop}}
        elseif model.kind~="overview" then opts.page=1;opts.page_count=2;opts.on_prev=noop;opts.on_next=noop end
        local screen=Screen.new(opts)
        check(screen.reading_body~=nil,"reading models dispatch to a native visual body")
        if model.kind=='receipt' then
            local selected=find(screen,'读完')
            equal(require('ffi/blitbuffer').COLOR_LIGHT_GRAY,selected.frame.background,'selected receipt status uses native fill')
            check(not selected.frame.invert,'selected receipt status preserves rounded corners')
        end
        equal("library_screen",screen.kind,"reading screen retains controller lifecycle contract")
        check(screen.content:getSize().h<=screen.content_height,"reading content stays above navigation at both resolutions")
        check(screen.body:getSize().w<=dimensions[1]-16*ratio,"reading content stays within screen width")
        if #screen.category_buttons>0 then
            check(screen.header[3][1][1].face.size<screen.category_buttons[1].label_widget.face.size*1.5,
                "header and tabs keep a consistent type scale without double device scaling")
        end
        paint_and_check(screen)
        for _,row in ipairs(screen.layout) do for _,control in ipairs(row) do
            check(control:getSize().w<=dimensions[1] and control:getSize().h<=dimensions[2],"all controls fit the screen")
        end end
        if model.kind=="overview" then tap(screen,find(screen,"›"));equal(1,periods,"year forward passes positive delta");periods=0
        elseif model.kind=="daily" then
            tap(screen,find(screen,"15"));equal("2026-08-15",selected_day,"calendar tap selects its full date")
            tap(screen,screen.cells[1].button);equal(book,selected_book,"daily book opens its receipt")
        elseif model.kind=="books" then
            equal(6,#screen.cells,"six books occupy the complete page")
            tap(screen,screen.cells[6].button);equal(book,selected_book,"last cover is selectable")
        else
            tap(screen,find(screen,"搁置"));equal("paused",status,"receipt status button passes the stored status")
            tap(screen,screen.reading_body.rating_buttons[5]);equal(5,rating,"fifth star sets five stars")
            local ticket=screen.reading_body[1]
            local by_text={};for i,child in ipairs(ticket) do if child.text then by_text[child.text]={widget=child,y=ticket.spots[i][2]} end end
            local stars=screen.reading_body.rating_buttons[1]
            local star_bottom=stars.dimen.y+stars.dimen.h
            local date=by_text["日期：2026-09-12"]
            check(star_bottom<=ticket.dimen.y+date.y,"rating stars stay above the receipt date with a footer action")
            check(find(screen,"搁置").dimen.y+find(screen,"搁置").dimen.h<stars.dimen.y,"status stays above receipt barcode and stars")
        end
        screen:closeForReplacement()
    end
end
state.dimensions.w,state.dimensions.h=600,800
state.screen.scaleBySize=function(_,n) return n end
package.loaded["ui/font"].getFace=function(_,_,size) size=size or 20;return {size=size,orig_size=size,
    ftsize={getHeightAndAscender=function() return size,math.floor(size*.75) end}} end
local callbacks,cancels,back={},0,0
local screen=Screen.new{title="阅读小票",compact=true,reading_model=receipt,on_back=function() back=back+1 end,
    cover_loader=function(_,callback) callbacks[#callbacks+1]=callback;return {cancel=function() cancels=cancels+1 end} end}
callbacks[1]("good.jpg")
equal("good.jpg",screen.cells[1].cover[1].file,"late receipt cover replaces the placeholder")
local cover_size=screen.cells[1].cover:getSize()
callbacks[1]("bad.jpg")
equal(nil,screen.cells[1].cover[1].file,"corrupt cover falls back to a native placeholder")
equal(cover_size.h,screen.cells[1].cover:getSize().h,"failed cover preserves receipt geometry")
screen.back_button.callback()
equal(1,back,"receipt Back closes the entire screen and navigates once")
equal(1,cancels,"receipt Back cancels its cover request")
local dirty=state.dirty; callbacks[1]("late.jpg")
equal(dirty,state.dirty,"closed receipt ignores late cover callbacks")
equal(false,screen:onClose(),"receipt close is idempotent")
local replaced=Screen.new{title="阅读小票",reading_model=receipt,on_back=function() back=back+1 end,
    cover_loader=function(_,cb) callbacks[#callbacks+1]=cb;return {cancel=function() cancels=cancels+1 end} end}
replaced:closeForReplacement()
equal(1,back,"replacing a receipt does not navigate backwards")
equal(2,cancels,"replacing a receipt cancels the old request")
for _,kind in ipairs{"overview","daily","books","receipt"} do
    local empty=Screen.new{title="空记录",compact=true,reading_model={kind=kind}}
    check(empty.content:getSize().h<=empty.content_height,"empty "..kind.." remains usable")
    paint_and_check(empty)
    empty:closeForReplacement()
end
return count
