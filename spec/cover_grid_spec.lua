local assertx = require("assertions")
local CoverGrid = require("legado.ui.cover_grid")

local function class(kind)
    return { new = function(_, options) options.kind = kind; return options end }
end
local Focus = class("focus")
local Button = class("button")
local Horizontal = class("horizontal")
local Vertical = class("vertical")
local Frame = class("frame")
local Image, Text = class("image"), class("text")
local back_group = { "back-group" }
local selected
local dirty = 0
local grid = CoverGrid.new({
    model = { items = {
        { title = "One", cover = "one.jpg", book = { id = "1" } },
        { title = "Two", cover_text = "封面不可用", book = { id = "2" } },
        { title = "Three", cover_text = "无封面", book = { id = "3" } },
        { title = "Four", cover_text = "无封面", book = { id = "4" } },
    } },
    on_select = function(book) selected = book.id end,
    dependencies = { focus_manager = Focus, button = Button, horizontal_group = Horizontal, vertical_group = Vertical, frame = Frame, image = Image, text = Text, ui_manager = { setDirty = function() dirty = dirty + 1 end }, device = { hasKeys = function() return true end, input = { group = { Back = back_group } } } },
})

assertx.equal("cover_grid", grid.kind, "cover mode returns a dedicated native widget")
assertx.equal(3, #grid.layout, "four covers plus return controls produce three focus rows")
assertx.equal(3, #grid.layout[1], "cover focus layout uses three columns")
assertx.equal(1, #grid.layout[2], "last focus row keeps remainder")
assertx.equal("返回", grid.layout[3][1].text, "cover focus layout includes a reachable return button")
assertx.equal("horizontal", grid[1][1].kind, "widget tree uses HorizontalGroup rows")
assertx.equal(3, #grid[1][1], "first visual row contains three cells")
assertx.equal("image", grid.cells[1].visual[1].kind, "available cover uses ImageWidget")
assertx.equal("one.jpg", grid.cells[1].visual[1].file, "ImageWidget receives nonblocking loader path")
assertx.equal("封面不可用", grid.cells[2].visual[1].text, "failed cover uses a text fallback")
grid.cells[2].item.cover = "two.jpg"
grid.cells[2].item.on_update(grid.cells[2].item)
assertx.equal("image", grid.cells[2].visual[1].kind, "late nonblocking cover refresh replaces fallback with ImageWidget")
assertx.equal(1, dirty, "late cover refresh requests an e-ink repaint")
grid.layout[1][1].callback()
assertx.equal("1", selected, "touch/press callback selects the book")
assertx.equal(back_group, grid.key_events.Close[1][1], "physical close preserves KOReader Back group object")

return 12
