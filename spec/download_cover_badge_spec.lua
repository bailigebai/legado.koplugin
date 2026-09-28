local A = require("assertions")
local LibraryScreen = require("legado.ui.library_screen")

local count = 0
local function equal(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; A.truthy(value, message) end

local Widget = {}
Widget.__index = Widget
function Widget:extend(fields) return setmetatable(fields or {}, { __index = self }) end
function Widget:new(fields) return setmetatable(fields or {}, { __index = self }) end
function Widget:getSize()
    if self.dimen then return { w = self.dimen.w, h = self.dimen.h } end
    if self.width and self.height then return { w = self.width, h = self.height } end
    if self.text then return { w = math.min(self.max_width or 1000, #self.text * 5), h = self.face and self.face.size or self.height or 14 } end
    local width, height = 0, 0
    for _, child in ipairs(self) do
        local size = child:getSize()
        if self.direction == "horizontal" then width, height = width + size.w, math.max(height, size.h)
        else width, height = math.max(width, size.w), height + size.h end
    end
    if self.padding then
        width = width + 2 * (self.padding + (self.bordersize or 0))
        height = height + 2 * (self.padding + (self.bordersize or 0))
    end
    return { w = width, h = height }
end
function Widget:resetLayout() end

local function factory(extra) return Widget:extend(extra or {}) end
local horizontal = factory({ direction = "horizontal" })
local vertical = factory({ direction = "vertical" })
local deps = {
    focus = factory(), input = factory(), gesture = factory(), button = factory(),
    horizontal = horizontal, vertical = vertical, frame = factory(), center = factory(),
    overlap = factory(), image = factory(), text = factory(), textbox = factory(),
    scrolltext = factory(),
    hspan = factory({ getSize = function(self) return { w = self.width or 0, h = 0 } end }),
    vspan = factory({ getSize = function(self) return { w = 0, h = self.width or 0 } end }),
    font = { getFace = function(_, _, size) return { size = size } end },
    geom = { new = function(_, value) return value end },
    colors = { COLOR_WHITE = 255 },
    ui = { setDirty = function() end },
    device = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
        scaleBySize = function(_, value) return value end } },
}

local finish_cover
local screen = LibraryScreen.new({ title = "书架", mode = "grid", compact = true,
    items = { { book = { id = "offline" }, title = "整本离线", cover_url = "cover", downloaded = true } },
    cover_loader = function(_, callback) finish_cover = callback end, dependencies = deps })
local cover = screen.cells[1].cover
equal("已下载", cover[2][1].text, "completed source book shows the badge")
local offset, size = cover[2].overlap_offset, cover[2]:getSize()
truthy(offset[1] > 0 and offset[1] + size.w <= 96, "badge stays inside the cover's right edge")
truthy(offset[2] > 0 and offset[2] + size.h <= 128, "badge stays inside the cover's bottom edge")
finish_cover("cover.jpg")
equal("cover.jpg", screen.cells[1].cover[1][1].file, "async image replaces the placeholder")
equal("已下载", screen.cells[1].cover[2][1].text, "badge survives cover replacement")

return count
