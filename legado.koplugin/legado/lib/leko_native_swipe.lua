-- Adapted from jnjnnjzch/leko-reader, 57dff8958dd43a5d95cb2dac22ca363d874de29b.
-- Upstream: AGPL-3.0-or-later. See phase3-core-interface.md for source mapping.
-- Capability adapter for Kindle's native page swipe.
--
-- KOReader's MTK framebuffer treats swipe animation as a one-shot flag on
-- the next submitted update. Keep that detail here so Leko never needs to
-- identify a Kindle model or change the global refresh policy.

local Device = require("device")

local SwipeAnimation = {}
SwipeAnimation.__index = SwipeAnimation

local FORWARD = "forward"

local function traceback(err)
    return debug and debug.traceback and debug.traceback(tostring(err), 2)
        or tostring(err)
end

function SwipeAnimation:new(options)
    options = options or {}
    return setmetatable({
        device = options.device or Device,
        screen = options.screen or (options.device and options.device.screen) or Device.screen,
    }, self)
end

function SwipeAnimation:_canDeviceSwipe()
    local device = self.device
    if not device or type(device.canDoSwipeAnimation) ~= "function" then return false end
    local ok, capable = pcall(function() return device:canDoSwipeAnimation() end)
    return ok and capable == true
end

function SwipeAnimation:isAvailable()
    local screen = self.screen
    return self:_canDeviceSwipe()
        and screen
        and screen.bb
        and type(screen.setSwipeAnimations) == "function"
        and type(screen.setSwipeDirection) == "function"
        and type(screen.refreshUI) == "function"
        and type(screen.bb.getWidth) == "function"
        and type(screen.bb.getHeight) == "function"
        and type(screen.bb.blitFrom) == "function"
end

-- The native backend accepts a boolean named `left`, rather than Leko's
-- semantic direction string. Next-page content enters from the right and
-- moves left; previous-page content is the mirror image.
function SwipeAnimation.directionIsLeft(direction)
    return direction == FORWARD
end

function SwipeAnimation:submit(target, direction)
    if not self:isAvailable() then return nil, "当前设备没有可用的原生 swipe 能力" end
    if direction ~= FORWARD and direction ~= "backward" then
        return nil, "无效的翻页方向"
    end

    local screen = self.screen
    local screen_bb = screen.bb
    local width = screen_bb:getWidth()
    local height = screen_bb:getHeight()
    if width <= 0 or height <= 0 then return nil, "正文 framebuffer 尺寸无效" end

    if type(screen.beforePaint) == "function" then pcall(screen.beforePaint, screen) end
    local ok, err = xpcall(function()
        screen_bb:blitFrom(target, 0, 0, 0, 0, width, height)

        -- These calls must be immediately adjacent to the update that should
        -- animate. `setSwipeAnimations` is reset by the MTK backend after
        -- this refresh, so it cannot leak into menus or other ReaderView UI.
        screen:setSwipeDirection(self.directionIsLeft(direction))
        screen:setSwipeAnimations(true)
        local result = screen:refreshUI(0, 0, width, height)
        if result == false then error("原生 swipe refresh 失败") end
    end, traceback)
    if type(screen.afterPaint) == "function" then pcall(screen.afterPaint, screen) end
    if not ok then return nil, err end
    return true
end

-- The MTK driver consumes this flag on the next refresh.  Clearing it here is
-- a defensive boundary for a refresh that failed before the driver consumed
-- the request; it does not change any global KOReader refresh policy.
function SwipeAnimation:reset()
    local screen = self.screen
    if screen and type(screen.setSwipeAnimations) == "function" then
        pcall(screen.setSwipeAnimations, screen, false)
    end
    return true
end

return SwipeAnimation
