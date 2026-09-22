-- Execute upstream layout, text, button and focus widgets; shim only platform services.
local source = os.getenv("LEGADO_KOREADER_SOURCE") or ".tools/koreader"
local probe = io.open(source .. "/frontend/ui/widget/textboxwidget.lua", "rb")
if not probe then error("run scripts/check-koreader-compat.ps1 to obtain the upstream UI sources") end
probe:close()
package.path = package.path .. ";" .. source .. "/frontend/?.lua;" .. source .. "/common/?.lua"

local A = require("assertions")
local count = 0
local function equal(expected, actual, message) count=count+1; A.equal(expected, actual, message) end
local function truthy(actual, message) count=count+1; A.truthy(actual, message) end
local function noop() end
local function no() return false end
local function yes() return true end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function chars(text)
    local result = {}; for byte in tostring(text):gmatch(".") do result[#result+1] = byte end; return result
end
table.pack = table.pack or function(...) return { n=select("#", ...), ... } end

G_defaults = { readSetting=function(_, _, default) return default or 24 end }
G_reader_settings = { nilOrTrue=no, isTrue=no, readSetting=function(_, _, default) return default end }
local dimensions = { w=600, h=800 }
local screen = {
    getWidth=function() return dimensions.w end, getHeight=function() return dimensions.h end,
    scaleBySize=function(_, value) return value end, scaleByDPI=function(_, value) return value end,
    isColorEnabled=no,
}
local back_group = { "Back" }
package.loaded.device = { screen=screen, hasDPad=no, hasFewKeys=no, hasKeys=yes, isTouchDevice=yes,
    input={ group={ Back=back_group } } }
package.loaded["ui/bidi"] = { mirroredUILayout=no }
package.loaded.logger = { dbg=noop, warn=noop, err=noop, info=noop }
package.loaded.dbg = setmetatable({guard=noop}, {__call=noop})
package.loaded.gettext = function(text) return text end
package.loaded.optmath = { round=function(value) return math.floor(value + 0.5) end }
package.loaded.depgraph = {}
package.loaded["ui/time"] = { s=function(value) return value end, ms=function(value) return value / 1000 end }
package.loaded["ffi/utf8proc"] = { lowercase=function(text) return text end }
package.loaded.util = {
    tableDeepCopy=copy, getDefaultArg=function(value, default) if value == nil then return default end return value end,
    splitToChars=chars, isSplittable=function() return true end, utf8Reverse=function(text) return text:reverse() end,
}
local function buffer(width, height)
    return { getWidth=function() return width end, getHeight=function() return height end, getType=function() return 1 end,
        fill=noop, free=noop, blitFrom=noop, paintRectRGB32=noop, darkenRect=noop }
end
package.loaded["ffi/blitbuffer"] = { COLOR_BLACK=0, COLOR_WHITE=255, COLOR_LIGHT_GRAY=204, COLOR_DARK_GRAY=85, TYPE_BB8=1,
    TYPE_BBRGB32=4, isColor8=yes, new=function(width, height) return buffer(width, height) end }
package.loaded["ui/font"] = {
    getFace=function(_, _, size)
        size = size or 20
        return { size=size, orig_size=size, ftsize={getHeightAndAscender=function() return size, math.floor(size*.75) end} }
    end,
    getAdjustedFace=function(_, face, bold) return face, bold end,
}
package.loaded["ui/rendertext"] = {
    sizeUtf8Text=function(_, _, _, face, text) return {x=#tostring(text)*face.size/3} end,
    truncateTextByWidth=function(_, text, face, width) return text:sub(1, math.max(1, math.floor(width*3/face.size))) end,
    getSubTextByWidth=function(_, text, face, width) return text:sub(1, math.max(1, math.floor(width*3/face.size))) end,
    getEllipsisWidth=function(_, face) return face.size/3 end, renderUtf8Text=noop,
}
package.loaded["ui/widget/iconwidget"] = {}

local closed, dirty, sent = {}, 0, 0
local ui = {
    close=function(_, widget) closed[#closed+1]=widget; if widget.onCloseWidget then widget:onCloseWidget() end end,
    setDirty=function() dirty=dirty+1 end,
    sendEvent=function() sent=sent+1 end,
}
package.loaded["ui/uimanager"] = ui
local Widget = require("ui/widget/widget")
local failed_image_frees = 0
local Image = Widget:extend{
    getSize=function(self) if self.file == "bad.jpg" then error("lazy decode") end return {w=self.width,h=self.height} end,
    free=function(self) if self.file == "bad.jpg" then failed_image_frees=failed_image_frees+1 end end,
}
package.loaded["ui/widget/imagewidget"] = Image

local LibraryScreen = require("legado.ui.library_screen")
local callbacks, cancels = {}, 0
local function loader(book, callback)
    callbacks[book.id] = callback
    if book.id == "sync" then callback("sync.jpg") end
    return { cancel=function() cancels=cancels+1 end }
end
local selected, back = nil, 0
local items = {
    {book={id="sync"},title="同步封面",subtitle="作者甲",intro="第一本书的简介",cover_url="one",source_count=2},
    {book={id="late"},title="异步封面",subtitle="作者乙",intro="第二本书的较长简介",cover_url="two",source_count=3},
    {book={id="bad"},title="损坏封面",subtitle="作者丙",intro="第三本书简介",cover_url="three",source_count=1},
}
local cards = LibraryScreen.new{ title="书架", subtitle="我的收藏", items=items, mode="cards", cover_loader=loader,
    on_select=function(book) selected=book.id end, on_back=function() back=back+1 end,
    navigation={{text="搜索",callback=noop},{text="发现",callback=noop},{text="书源",callback=noop}} }
local size = cards:getSize()
equal("library_screen", cards.kind, "production class exposes its screen kind")
equal(3, #cards.cells, "cards mode keeps every supplied item")
truthy(size.w <= 600 and size.h <= 800, "three cards and navigation fit a 600x800 screen")
for _, cell in ipairs(cards.cells) do truthy(cell.frame:getSize().w <= 580, "card including border fits content width") end
equal("sync.jpg", cards.cells[1].cover[1].file, "synchronous cover completion is rendered")
local before = cards:getSize().h
callbacks.late("late.jpg")
equal("late.jpg", cards.cells[2].cover[1].file, "late cover completion replaces the placeholder")
equal(before, cards:getSize().h, "cover completion preserves screen geometry")
callbacks.bad("bad.jpg")
equal(nil, cards.cells[3].cover[1].file, "decode failure keeps a native text placeholder")
equal(1, failed_image_frees, "lazy decode failure frees the failed native image")
truthy(dirty >= 2, "cover completions request native repaints")
equal(true, cards.cells[2].button.callback(), "card handles touch even when the business callback returns nil")
equal("late", selected, "touch callback selects the underlying book")
equal(back_group, cards.key_events.Close[1][1], "hardware Back uses the platform key group")
truthy(cards:onPress(), "focused keyboard press is handled by the native focus manager")
equal(1, sent, "keyboard press emits the native focused tap event")
cards:onClose()
equal(1, back, "terminal close invokes controller back once")
equal(false, cards.alive, "terminal close marks the catalog widget dead")
equal(3, cancels, "terminal close cancels every cover request")
local dirty_after_close = dirty
callbacks.late("ignored.jpg")
equal(dirty_after_close, dirty, "late completion after close is ignored")
equal(false, cards:onClose(), "close is idempotent")

local deferred, deferred_back = {}, 0
local deferred_ui = {
    close=function(_, widget) deferred.closed=widget; if widget.onCloseWidget then widget:onCloseWidget() end end,
    setDirty=noop,
    scheduleIn=function(_, _, callback) deferred.callback=callback end,
}
local deferred_screen = LibraryScreen.new{title="延迟关闭", items={{title="章节",callback=noop}},
    ui_manager=deferred_ui, on_back=function() deferred_back=deferred_back+1 end}
deferred_screen:onClose()
equal(0, deferred_back, "controller navigation waits for the next UI tick")
equal(false, deferred_screen.alive, "deferred close removes the old catalog immediately")
deferred.callback()
equal(1, deferred_back, "deferred close navigates exactly once")

local busy_cards = LibraryScreen.new{title="搜索",items=items,mode="cards",actions={
    {text="重新搜索",callback=noop},{text="搜索诊断",callback=noop},{text="清空结果",callback=noop}},
    page=2,page_count=3,on_prev=noop,on_next=noop,navigation={
        {text="书架",callback=noop},{text="搜索",callback=noop},{text="发现",callback=noop},{text="书源",callback=noop}}}
equal(busy_cards.content_height, busy_cards.content:getSize().h, "three large cards, search actions, paging and navigation fit anchored 600x800 bounds")
equal(110, busy_cards.cells[1].cover:getSize().w, "cards use a prominent 110px cover")
equal(154, busy_cards.cells[1].cover:getSize().h, "cards preserve the requested portrait cover ratio")
equal(nil, busy_cards.cells[1].title_widget.bordersize, "card title is text without a redundant inner button border")
equal(4, #busy_cards.layout[#busy_cards.layout], "all four app tabs stay together on the bottom row")
equal("书架", busy_cards.layout[#busy_cards.layout][1].text, "bottom tab row starts with bookshelf after paging")

local function books(amount)
    local result={}; for index=1,amount do result[index]={book={id=tostring(index)},title="Book "..index,
        subtitle="Author "..index,intro="Intro "..index} end; return result
end
local categories={{text="全部",active=true,callback=noop},{text="在读",callback=noop},
    {text="未读",callback=noop},{text="分类",callback=noop}}
local grid = LibraryScreen.new{title="书架",subtitle="第 1/2 页",items=books(12),mode="grid",compact=true,
    grid_columns=4,grid_rows=3,categories=categories,
    actions={{text="搜索添加",callback=noop},{text="更多",callback=noop}},
    page=1,page_count=2,on_prev=noop,on_next=noop,navigation={{text="书架",callback=noop},{text="搜索",callback=noop},{text="发现",callback=noop}}}
equal(12, #grid.cells, "compact grid keeps the presenter's complete 12-book page")
truthy(grid:getSize().h <= 800, "twelve-cover compact grid fits 600x800")
truthy(grid.body:getSize().w <= 584, "four framed grid cells fit the compact content row")
equal(grid.content_height, grid.content:getSize().h, "measured spacer anchors header top and footer bottom")
equal(4, #grid.category_buttons, "all category tabs are visible above the shelf")
equal(require('ffi/blitbuffer').COLOR_LIGHT_GRAY, grid.category_buttons[1].frame.background, "selected category has a visible native background")
truthy(not grid.category_buttons[1].frame.invert, "selected rounded category does not invert square corners")
equal(10, grid.category_buttons[1].radius, "compact category buttons use gentle rounded corners")
equal(1, grid.category_buttons[1].bordersize, "compact category buttons use a light border")
equal(10, grid.back_button.radius, "compact Back matches the rounded controls")
equal(4, #grid.layout[3], "first compact grid row exposes four reachable books")
equal(4, #grid.layout[4], "second compact grid row exposes four reachable books")
equal(4, #grid.layout[5], "third compact grid row exposes four reachable books")
equal(3, #grid.layout[6], "compact paging stays on one row")
equal(5, #grid.layout[7], "two actions and three navigation buttons share one compact row")
equal(13, grid.cells[1].title_widget.face.orig_size, "compact grid uses small book-title type")
equal(8, grid.cells[1].frame.radius, "compact cards use gentle rounded corners")
equal(1, grid.cells[1].frame.bordersize, "compact cards retain only a light border")
equal(2, grid.cells[1].title_widget.lines_per_page, "long titles may use two stable lines below the cover")
local idle_frame_size = grid.cells[1].frame:getSize()
grid.cells[1].button:onFocus()
equal(idle_frame_size.w, grid.cells[1].frame:getSize().w, "compact focus keeps the four-column row width stable")
equal(idle_frame_size.h, grid.cells[1].frame:getSize().h, "compact focus keeps card height stable")
equal(0, grid.cells[1].frame.color, "compact focus uses the native black focus border")
grid.cells[1].button:onUnfocus()
equal(idle_frame_size.w, grid.cells[1].frame:getSize().w, "compact unfocus keeps the four-column row width stable")
equal(idle_frame_size.h, grid.cells[1].frame:getSize().h, "compact unfocus keeps card height stable")
equal(255, grid.cells[1].frame.color, "compact unfocus restores the invisible white border")

local compact_cards = LibraryScreen.new{title="搜索",compact=true,items=books(1),mode="cards"}
equal(14, compact_cards.cells[1].intro_widget.face.orig_size, "compact card introductions use smaller type")
local compact_empty = LibraryScreen.new{title="空书架",compact=true,items={},mode="grid"}
equal(16, compact_empty.empty_widget.face.orig_size, "compact empty states avoid oversized type")

local long_intro = string.rep("完整简介段落，用于确认详情页可以继续向下阅读。", 40)
local detail = LibraryScreen.new{title="详情",compact=true,items={{book={id="detail"},title="长篇小说",
    subtitle="作者 · 类型 · 状态",intro=long_intro}},mode="detail",actions={
    {text="阅读",callback=noop},{text="更多",callback=noop}},navigation={{text="书架",callback=noop}}}
truthy(detail:getSize().h <= 800, "detail cover, complete intro and compact controls fit 600x800")
equal(150, detail.cells[1].cover:getSize().w, "detail keeps a large cover")
equal(long_intro, detail.detail_intro.text, "detail retains the complete introduction in its native scroll widget")
equal(14, detail.detail_intro.face.orig_size, "detail introduction uses compact readable type")
truthy(detail.detail_intro.width >= 550, "detail introduction uses the full content width below the cover")
truthy(detail.detail_intro.height >= 230, "detail gives the introduction a useful reading area")
truthy(detail.detail_intro.text_widget:getAllLineCount() > detail.detail_intro.text_widget:getVisLineCount(),
    "long detail introductions have additional scrollable lines")
truthy(detail.detail_intro.ges_events.ScrollText ~= nil, "detail keeps native touch scrolling")
equal(nil, detail.cells[1].button.ges_events.TapSelect, "detail wrapper does not consume taps meant for intro scrolling")
truthy(detail.detail_intro:scrollDown() == nil, "native detail scrolling handles a page-down action")
local choices={}; for index=1,8 do choices[index]={title="来源 "..index,callback=noop} end
local list = LibraryScreen.new{title="来源",items=choices}
equal(8, #list.cells, "choice list keeps all eight entries")
truthy(list:getSize().h <= 800, "eight choices fit 600x800")
truthy(list.content:getSize().h <= list.content_height, "eight choice rows stay inside anchored content bounds")
local subtitled = LibraryScreen.new{title="分类",items={{title="玄幻",subtitle="30 本书",callback=noop}}}
equal("30 本书", subtitled.cells[1].visual[3][1].text, "choice rows visibly retain category/source status")
local replaced = LibraryScreen.new{title="替换",items=books(1),cover_loader=loader,on_back=function() back=back+1 end}
truthy(replaced:closeForReplacement(), "replacement closes the native widget")
equal(1, back, "replacement does not invoke controller callbacks")

-- Repeat the sizing contract at another common portrait resolution.
dimensions.w, dimensions.h = 758, 1024
local kindle = LibraryScreen.new{title="Kindle",items=books(6),mode="grid",navigation={{text="书架",callback=noop}}}
truthy(kindle:getSize().w <= 758 and kindle:getSize().h <= 1024, "grid fits a 758x1024 portrait screen")

return count
