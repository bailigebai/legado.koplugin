-- Adapted from jnjnnjzch/leko-reader, 57dff8958dd43a5d95cb2dac22ca363d874de29b.
-- Upstream: AGPL-3.0-or-later. See phase3-core-interface.md for source mapping.
-- Chapter-boundary cleanup wave for Leko's text-only ReaderView.
--
-- The wave is deliberately local to the reader surface. It does not read
-- the physical display, keep an old-page framebuffer, or touch UIManager's
-- global refresh policy. The only retained page is the newly rendered target
-- page; the current Screen.bb remains the working surface.

local Blitbuffer = require("ffi/blitbuffer")

local ChapterWaveRefresh = {}
ChapterWaveRefresh.__index = ChapterWaveRefresh

local FORWARD = "forward"
local BACKWARD = "backward"
local FRAME_DELAY = 0.004
local DRIVER_ALIGNMENT = 8

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function alignDown(value)
    return math.floor(value / DRIVER_ALIGNMENT) * DRIVER_ALIGNMENT
end

local function alignUp(value)
    return math.ceil(value / DRIVER_ALIGNMENT) * DRIVER_ALIGNMENT
end

local function traceback(err)
    return debug and debug.traceback and debug.traceback(tostring(err), 2)
        or tostring(err)
end

function ChapterWaveRefresh:new(options)
    options = options or {}
    return setmetatable({
        screen = options.screen,
        ui_manager = options.ui_manager,
        target_framebuffer = nil,
        direction = nil,
        running = false,
        pending_frame = nil,
        generation = 0,
        step_index = 0,
        step_count = 0,
        band_width = 0,
        step_width = 0,
        overlap_width = DRIVER_ALIGNMENT * 2,
        revealed_edge = 0,
        _on_complete = nil,
    }, self)
end

function ChapterWaveRefresh:isRunning()
    return self.running == true
end

function ChapterWaveRefresh:isAvailable()
    local screen = self.screen
    local bb = screen and screen.bb
    local can_paint = bb and (type(bb.paintRect) == "function" or type(bb.fillRect) == "function")
    return screen
        and bb
        and can_paint
        and type(bb.getWidth) == "function"
        and type(bb.getHeight) == "function"
        and type(bb.blitFrom) == "function"
        and type(screen.refreshUI) == "function"
end

function ChapterWaveRefresh:_unschedulePendingFrame()
    if self.pending_frame and self.ui_manager
            and type(self.ui_manager.unschedule) == "function" then
        pcall(self.ui_manager.unschedule, self.ui_manager, self.pending_frame)
    end
    self.pending_frame = nil
end

function ChapterWaveRefresh:_scheduleFrame(token, delay)
    if not self.running or token ~= self.generation then return nil, "波刷新已失效" end

    local callback
    callback = function()
        if self.pending_frame == callback then self.pending_frame = nil end
        self:_runFrame(token)
    end
    self.pending_frame = callback

    local manager = self.ui_manager
    if not manager then return nil, "动画调度器不可用" end
    if type(manager.scheduleIn) == "function" then
        manager:scheduleIn(delay or 0, callback)
    elseif type(manager.nextTick) == "function" then
        manager:nextTick(callback)
    else
        self.pending_frame = nil
        callback()
    end
    return true
end

function ChapterWaveRefresh:_refreshRect(x, width, height)
    if width <= 0 then return true end
    local screen = self.screen
    local screen_width = screen.bb:getWidth()
    local left = clamp(alignDown(x - self.overlap_width), 0, screen_width)
    local right = clamp(alignUp(x + width + self.overlap_width), 0, screen_width)
    if right <= left then return true end

    -- Keep the 0.15.45 chapter-wave submission path: prefer KOReader's
    -- scoped no-merge UI entry point so adjacent black/white/target states
    -- are submitted separately. Older hosts may expose only refreshUI, which
    -- remains a compatible fallback. Ordinary page turns and all other
    -- ReaderView surfaces retain their existing refresh paths.
    local refresh = type(screen.refreshNoMergeUI) == "function"
        and screen.refreshNoMergeUI or screen.refreshUI
    local result = refresh(screen, left, 0, right - left, height)
    if result == false then return nil, "跨章净屏动画刷新失败" end
    return true
end

function ChapterWaveRefresh:_paintRect(x, width, height, color)
    local screen = self.screen
    local bb = screen.bb
    local left = clamp(alignDown(x), 0, bb:getWidth())
    local right = clamp(alignUp(x + width), 0, bb:getWidth())
    local clipped = right - left
    if clipped <= 0 then return true end

    if type(bb.paintRect) == "function" then
        bb:paintRect(left, 0, clipped, height, color)
    elseif type(bb.fillRect) == "function" then
        bb:fillRect(left, 0, clipped, height, color)
    else
        return nil, "正文 framebuffer 不支持区域填充"
    end
    return true
end

function ChapterWaveRefresh:_copyTarget(x, width, height)
    local screen = self.screen
    local bb = screen.bb
    local left = clamp(alignDown(x), 0, bb:getWidth())
    local right = clamp(alignUp(x + width), 0, bb:getWidth())
    local clipped = right - left
    if clipped <= 0 then return true end
    bb:blitFrom(self.target_framebuffer, left, 0, left, 0, clipped, height)
    return true
end

function ChapterWaveRefresh:_waitBeforeMutation()
    local screen = self.screen
    -- This is deliberately submission-only.  Waiting for refreshWaitForLast()
    -- here would wait for the physical E Ink waveform after every strip and
    -- turn an asynchronous wave into a serial full-speed refresh loop.
    -- KOReader's Kindle refreshUI path already fences the previous UI marker
    -- before submitting the next UI update.  Use an explicit submission fence
    -- only on hosts that expose one; never fall back to completion here.
    for _, method_name in ipairs({
        "refreshWaitForSubmission",
        "waitForUpdateSubmission",
        "refreshWaitForUpdateSubmission",
    }) do
        if type(screen and screen[method_name]) == "function" then
            local ok = pcall(screen[method_name], screen)
            if ok then return true end
        end
    end
    return false
end

function ChapterWaveRefresh:_beginPaint()
    if self.screen and type(self.screen.beforePaint) == "function" then
        pcall(self.screen.beforePaint, self.screen)
    end
end

function ChapterWaveRefresh:_endPaint()
    if self.screen and type(self.screen.afterPaint) == "function" then
        pcall(self.screen.afterPaint, self.screen)
    end
end

function ChapterWaveRefresh:_submitFullTarget()
    local screen = self.screen
    local bb = screen and screen.bb
    local target = self.target_framebuffer
    if not bb or not target then return nil, "章节目标 framebuffer 不可用" end
    local width = bb:getWidth()
    local height = bb:getHeight()
    self:_beginPaint()
    local ok, err = xpcall(function()
        bb:blitFrom(target, 0, 0, 0, 0, width, height)
        local result = screen:refreshUI(0, 0, width, height)
        if result == false then error("章节目标页刷新失败") end
    end, traceback)
    self:_endPaint()
    if not ok then return nil, err end
    return true
end

function ChapterWaveRefresh:_finish(token)
    if token ~= self.generation or not self.running then return end
    self:_unschedulePendingFrame()

    -- Every target region has already been copied and submitted by the last
    -- wave frame.  Do not submit the whole page again: that extra UI update
    -- adds latency and turns the final target->target pass into another source
    -- of seams.  Screen:refreshUI owns the submitted update after this point;
    -- do not wait for the physical waveform before releasing the target.

    local target = self.target_framebuffer
    local callback = self._on_complete
    self.target_framebuffer = nil
    self._on_complete = nil
    self.running = false
    self.direction = nil
    self.step_index = 0
    self.step_count = 0
    if type(callback) == "function" then pcall(callback, token, target) end
end

function ChapterWaveRefresh:_runFrame(token)
    if token ~= self.generation or not self.running then return end
    local screen = self.screen
    local bb = screen and screen.bb
    local target = self.target_framebuffer
    if not bb or not target then
        self:_finish(token)
        return
    end

    local width = bb:getWidth()
    local height = bb:getHeight()
    local travelled = math.min(self.step_index * self.step_width, width + self.band_width)
    local front = self.direction == FORWARD and width - travelled or travelled
    local previous_edge = self.revealed_edge
    local new_edge
    local refresh_left
    local refresh_right

    if self.direction == FORWARD then
        -- OLD | BLACK | WHITE | NEW, moving from right to left.
        new_edge = clamp(front + self.band_width, 0, width)
    else
        -- NEW | WHITE | BLACK | OLD, the exact mirror image.
        new_edge = clamp(front - self.band_width, 0, width)
    end

    self:_beginPaint()
    local ok, err = xpcall(function()
        if self.direction == FORWARD then
            if new_edge < previous_edge then
                self:_copyTarget(new_edge, previous_edge - new_edge, height)
            end
            self:_paintRect(front - self.band_width, self.band_width, height,
                Blitbuffer.COLOR_BLACK)
            self:_paintRect(front, self.band_width, height, Blitbuffer.COLOR_WHITE)
            refresh_left = math.min(front - self.band_width, new_edge)
            refresh_right = math.max(front + self.band_width, previous_edge)
        else
            if new_edge > previous_edge then
                self:_copyTarget(previous_edge, new_edge - previous_edge, height)
            end
            self:_paintRect(front, self.band_width, height, Blitbuffer.COLOR_BLACK)
            self:_paintRect(front - self.band_width, self.band_width, height,
                Blitbuffer.COLOR_WHITE)
            refresh_left = math.min(previous_edge, front - self.band_width)
            refresh_right = math.max(front + self.band_width, new_edge)
        end
        local refreshed, refresh_err = self:_refreshRect(
            refresh_left, refresh_right - refresh_left, height)
        if not refreshed then error(refresh_err) end
    end, traceback)
    self:_endPaint()
    if not ok or err then
        self:_finish(token)
        return
    end

    self.revealed_edge = new_edge
    self.step_index = self.step_index + 1
    self:_waitBeforeMutation()
    if self.step_index > self.step_count then
        self:_finish(token)
    else
        self:_scheduleFrame(token, FRAME_DELAY)
    end
end

-- Start one chapter wave. The target is owned by the caller and is returned to
-- the completion/cancel callback; this lets SwipeRefresh keep ownership of
-- the only page framebuffer and avoid a hidden old-page cache.
function ChapterWaveRefresh:begin(target, direction, on_complete)
    if not self:isAvailable() then return nil, "跨章净屏动画所需的正文刷新 API 不可用" end
    if direction ~= FORWARD and direction ~= BACKWARD then
        return nil, "无效的翻页方向"
    end
    if not target then return nil, "章节目标 framebuffer 不可用" end

    self:_unschedulePendingFrame()
    self.generation = self.generation + 1
    self.running = false
    self.direction = nil
    self.target_framebuffer = nil
    self._on_complete = nil

    local width = self.screen.bb:getWidth()
    local height = self.screen.bb:getHeight()
    if width <= 0 or height <= 0 then return nil, "正文 framebuffer 尺寸无效" end

    -- Keep the black/white bands wider than one movement so every pixel still
    -- crosses the cleanup states, but use fewer driver submissions.  The
    -- 8-pixel grid matches the alignment used by Kindle's MXCFB path and the
    -- small overlap is also refreshed on both sides of a moving frame.
    local band = math.floor(width / 6)
    band = math.max(32, math.min(128, band))
    band = math.max(DRIVER_ALIGNMENT,
        alignDown(math.min(band, math.max(DRIVER_ALIGNMENT, math.floor(width / 2)))))
    local step = math.max(DRIVER_ALIGNMENT, alignDown(band - DRIVER_ALIGNMENT))
    local count = math.max(1, math.ceil((width + band) / step))

    self.target_framebuffer = target
    self.direction = direction
    self.running = true
    self.step_index = 0
    self.step_count = count
    self.band_width = band
    self.step_width = step
    self.revealed_edge = direction == FORWARD and width or 0
    self._on_complete = on_complete

    local token = self.generation
    local scheduled, err = self:_scheduleFrame(token, 0)
    if not scheduled then
        self.running = false
        self.target_framebuffer = nil
        self._on_complete = nil
        return nil, err
    end
    return true, token
end

function ChapterWaveRefresh:settle()
    if not self.running or not self.target_framebuffer then return false end
    self:_unschedulePendingFrame()
    self.generation = self.generation + 1
    local token = self.generation - 1
    self.running = false
    self.direction = nil
    self:_submitFullTarget()

    local target = self.target_framebuffer
    local callback = self._on_complete
    self.target_framebuffer = nil
    self._on_complete = nil
    self.step_index = 0
    self.step_count = 0
    if type(callback) == "function" then pcall(callback, token, target) end
    return true
end

function ChapterWaveRefresh:cancel()
    if not self.running and not self.target_framebuffer then return nil end
    self:_unschedulePendingFrame()
    self.generation = self.generation + 1
    self.running = false
    self.direction = nil
    self._on_complete = nil
    local target = self.target_framebuffer
    self.target_framebuffer = nil
    self.step_index = 0
    self.step_count = 0
    return target
end

return ChapterWaveRefresh
