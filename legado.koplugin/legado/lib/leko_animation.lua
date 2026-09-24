-- Adapted from jnjnnjzch/leko-reader, 57dff8958dd43a5d95cb2dac22ca363d874de29b.
-- Upstream: AGPL-3.0-or-later. See phase3-core-interface.md for source mapping.
-- Swipe strip edge/reveal logic also adapted from Swipe_Animation v4.3,
-- 59dce480c38538976325f7ebc0831e36bc4c6ed4, GPLv3; upstream notices must accompany distribution.
-- Circular ripple reveal is a local extension using the same refresh settings.
-- Reader-local transition coordinator.
--
-- Same-chapter pages use the device's native swipe when the device advertises
-- that capability, and otherwise use the small local software strip fallback.
-- Chapter boundaries may use the travelling black/white cleanup wave. No
-- global KOReader refresh policy is changed here.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Time = require("ui/time")

local ChapterWaveRefresh = require("legado.lib.leko_chapter_wave")
local SwipeAnimation = require("legado.lib.leko_native_swipe")

local Screen = Device.screen

local SwipeRefresh = {}
SwipeRefresh.__index = SwipeRefresh

SwipeRefresh.FORWARD = "forward"
SwipeRefresh.BACKWARD = "backward"

-- This is the legacy fallback for devices without KOReader's hardware swipe
-- capability.  It keeps the .40/.42 visual contract (one target strip per UI
-- tick) without retaining an old framebuffer or creating an animation queue.
local PORTRAIT_STRIPS = 8
local LANDSCAPE_STRIPS = 6
local SOFTWARE_ALIGNMENT = 8
local SOFTWARE_OVERLAP = 8
local RIPPLE_EFFECTS = { ripple=true, side_ripple=true, ripple_in=true, wave=true }
local function now()
    if Time.now and Time.to_s then return Time.to_s(Time.now()) end
    return 0 -- Hosts without monotonic time retain the configured delay.
end

local function freeBuffer(buffer)
    if buffer and type(buffer.free) == "function" then
        pcall(buffer.free, buffer)
    end
end

local function traceback(err)
    return debug and debug.traceback and debug.traceback(tostring(err), 2)
        or tostring(err)
end

function SwipeRefresh:new(options)
    options = options or {}
    local screen = options.screen or Screen
    local instance = setmetatable({
        screen = screen,
        ui_manager = options.ui_manager,
        device = options.device or Device,
        clock = options.clock or now,
        target_framebuffer = nil,
        direction = nil,
        running = false,
        pending_frame = nil,
        generation = 0,
        mode = nil,
        strip_index = 0,
        strip_count = 0,
        _on_complete = nil,
    }, self)
    instance.native_swipe = SwipeAnimation:new{
        device = instance.device,
        screen = screen,
    }
    instance.chapter_wave = ChapterWaveRefresh:new{
        screen = screen,
        ui_manager = options.ui_manager,
    }
    return instance
end

function SwipeRefresh:isRunning()
    return self.running == true
end

function SwipeRefresh:isNativeSwipeAvailable()
    return self.native_swipe:isAvailable()
end

function SwipeRefresh:isChapterWaveAvailable()
    return self.chapter_wave:isAvailable()
end

function SwipeRefresh:isWaveRunning()
    return self.running == true and self.mode == "wave"
end

function SwipeRefresh:isSoftwareSwipeAvailable()
    local screen = self.screen
    local bb = screen and screen.bb
    return screen
        and bb
        and type(bb.getWidth) == "function"
        and type(bb.getHeight) == "function"
        and type(bb.blitFrom) == "function"
        and type(screen.refreshUI) == "function"
end

function SwipeRefresh:_unschedulePendingFrame()
    if self.pending_frame and self.ui_manager
            and type(self.ui_manager.unschedule) == "function" then
        pcall(self.ui_manager.unschedule, self.ui_manager, self.pending_frame)
    end
    self.pending_frame = nil
end

-- This callback is a submission-ownership handoff, not a claim that the E Ink
-- waveform has finished.  Screen.bb has already been copied/submitted, so the
-- temporary target can be released on the next UI turn.
function SwipeRefresh:_scheduleNativeSubmissionCommit(token)
    local callback
    callback = function()
        if self.pending_frame == callback then self.pending_frame = nil end
        if token ~= self.generation or self.mode ~= "native" or not self.running then return end
        self:_completeNativeSubmission(token)
    end
    self.pending_frame = callback

    local manager = self.ui_manager
    if not manager then return nil, "动画调度器不可用" end
    if type(manager.scheduleIn) == "function" then
        local ok,err=pcall(manager.scheduleIn,manager,0,callback)
        if not ok then self:_unschedulePendingFrame();return nil,tostring(err) end
    elseif type(manager.nextTick) == "function" then
        local ok,err=pcall(manager.nextTick,manager,callback)
        if not ok then self:_unschedulePendingFrame();return nil,tostring(err) end
    else
        self.pending_frame = nil
        callback()
    end
    return true
end

function SwipeRefresh:_scheduleSoftwareFrame(token, delay)
    if not self.running or token ~= self.generation or self.mode ~= "software" then
        return nil, "动画效果已失效"
    end

    local callback
    callback = function()
        if self.pending_frame == callback then self.pending_frame = nil end
        self:_runSoftwareFrame(token)
    end
    self.pending_frame = callback

    local manager = self.ui_manager
    if not manager then return nil, "动画调度器不可用" end
    local ok, err
    if type(manager.scheduleIn) == "function" then
        ok, err = pcall(manager.scheduleIn, manager, delay or 0, callback)
    elseif type(manager.nextTick) == "function" then
        ok, err = pcall(manager.nextTick, manager, callback)
    else
        self.pending_frame = nil
        return nil, "动画调度器不可用"
    end
    if not ok then
        self:_unschedulePendingFrame()
        return nil, tostring(err)
    end
    return true
end

function SwipeRefresh:_invalidate()
    self:_unschedulePendingFrame()
    local previous_mode = self.mode
    local target = self.target_framebuffer
    if previous_mode == "wave" then
        target = self.chapter_wave:cancel() or target
    end
    if previous_mode == "native" then self.native_swipe:reset() end
    self.generation = self.generation + 1
    self.running = false
    self.mode = nil
    self.direction = nil
    self.strip_index = 0
    self.strip_count = 0
    self.reveal_edges = nil
    self._on_complete = nil
    self.target_framebuffer = nil
    freeBuffer(target)
end

function SwipeRefresh:_newTarget(width, height, bb_type)
    local target = Blitbuffer.new(width, height, bb_type)
    if type(target.fill) == "function" then target:fill(Blitbuffer.COLOR_WHITE) end
    return target
end

function SwipeRefresh:_renderTarget(widget)
    local screen = self.screen
    local screen_bb = screen and screen.bb
    if not screen_bb or type(widget) ~= "table" or type(widget.paintTo) ~= "function" then
        return nil, "正文目标 framebuffer 不可用"
    end

    local width = screen_bb:getWidth()
    local height = screen_bb:getHeight()
    local bb_type = type(screen_bb.getType) == "function" and screen_bb:getType() or nil
    local allocated, target_or_err = pcall(self._newTarget, self, width, height, bb_type)
    if not allocated then return nil, tostring(target_or_err) end
    local target = target_or_err
    if type(screen_bb.getRotation) == "function" and type(target.setRotation) == "function" then
        local rotated, rotation = pcall(screen_bb.getRotation, screen_bb)
        if rotated then
            local rotation_set, rotation_err = pcall(target.setRotation, target, rotation)
            if not rotation_set then
                freeBuffer(target)
                return nil, tostring(rotation_err)
            end
        end
    end

    local ok, err = xpcall(function()
        local painted, cause = widget:paintTo(target, 0, 0)
        if painted == false then error(type(cause) == 'table' and cause.message or cause or '正文绘制失败') end
    end, traceback)
    if not ok then
        freeBuffer(target)
        return nil, err
    end
    return target
end

function SwipeRefresh:_submitTarget(target)
    local screen = self.screen
    local bb = screen and screen.bb
    if not bb or type(screen.refreshUI) ~= "function" then
        return nil, "Screen UI refresh API 不可用"
    end
    local width = bb:getWidth()
    local height = bb:getHeight()
    if width <= 0 or height <= 0 then return nil, "正文 framebuffer 尺寸无效" end
    if target:getWidth() ~= width or target:getHeight() ~= height then
        return nil, "正文 framebuffer 尺寸已改变"
    end

    if type(screen.beforePaint) == "function" then pcall(screen.beforePaint, screen) end
    local ok, err = xpcall(function()
        bb:blitFrom(target, 0, 0, 0, 0, width, height)
        local result = screen:refreshUI(0, 0, width, height)
        if result == false then error("目标页刷新失败") end
    end, traceback)
    if type(screen.afterPaint) == "function" then pcall(screen.afterPaint, screen) end
    if not ok then return nil, err end
    return true
end

function SwipeRefresh:_completeNativeSubmission(token)
    if token ~= self.generation or self.mode ~= "native" or not self.running then return end
    self:_unschedulePendingFrame()
    local target = self.target_framebuffer
    local callback = self._on_complete
    self.target_framebuffer = nil
    self._on_complete = nil
    self.running = false
    self.mode = nil
    self.direction = nil
    self.native_swipe:reset()
    freeBuffer(target)
    if type(callback) == "function" then pcall(callback, token, true) end
end

function SwipeRefresh:_completeSoftware(token, painted)
    if token ~= self.generation or self.mode ~= "software" or not self.running then return end
    self:_unschedulePendingFrame()
    local target = self.target_framebuffer
    local callback = self._on_complete
    self.target_framebuffer = nil
    self._on_complete = nil
    self.running = false
    self.mode = nil
    self.direction = nil
    self.strip_index = 0
    self.strip_count = 0
    self.reveal_edges = nil
    freeBuffer(target)
    if type(callback) == "function" then pcall(callback, token, painted) end
end

function SwipeRefresh:_softwareSteps(width, height)
    if width > height then return LANDSCAPE_STRIPS end
    return PORTRAIT_STRIPS
end

function SwipeRefresh:_softwareStripFor(index, width, steps)
    if self.software_effect == 'swipe' then
        local edges = self.strip_edges
        local slot = self.direction == SwipeRefresh.FORWARD and (#edges - index) or index
        return edges[slot], edges[slot + 1] - edges[slot]
    end
    local previous = math.floor((index - 1) * width / steps)
    local current = math.floor(index * width / steps)
    local strip_width = current - previous
    if self.direction == SwipeRefresh.FORWARD then
        -- Next-page content enters from the right and moves left.
        return width - current, strip_width
    end
    -- Previous-page content enters from the left and moves right.
    return previous, strip_width
end

function SwipeRefresh:_refreshSoftwareRegion(x, y, width, height)
    local screen = self.screen
    local refresh = screen.refreshUI
    if (self.software_effect == 'swipe' or RIPPLE_EFFECTS[self.software_effect])
            and self.refresh_mode == 'fast' and type(screen.refreshFast) == 'function' then
        refresh = screen.refreshFast
    end
    if refresh(screen, x, y, width, height) == false then error("动画效果刷新失败") end
end

function SwipeRefresh:_submitRippleFrame(target, index, width, height)
    local screen, bb = self.screen, self.screen.bb
    if type(screen.beforePaint) == "function" then pcall(screen.beforePaint, screen) end
    local ok, err = xpcall(function()
        local align = self.software_alignment
        local effect, progress = self.software_effect, index / self.strip_count
        local cx, cy = width / 2, height / 2
        if effect == 'side_ripple' then cx, cy = width, height / 3 end
        local inward = effect == 'ripple_in'
        local radius_squared = (math.max(cx,width-cx)^2 + math.max(cy,height-cy)^2)
            * (inward and 1-progress or progress)^2
        local band = math.max(4,align)
        local split = math.floor(height/2/band)*band
        local damage = {}
        local function reveal(x, edge, y, hh, side)
            if edge <= x then return end
            bb:blitFrom(target,x,y,x,y,edge-x,hh)
            local slot = (y < split and 0 or 2)+side
            local box=damage[slot] or {width,height,0,0};damage[slot]=box
            box[1],box[2]=math.min(box[1],x),math.min(box[2],y)
            box[3],box[4]=math.max(box[3],edge),math.max(box[4],y+hh)
        end
        for y=0,height-1,band do
            local hh=math.min(band,height-y)
            local left,right=math.floor(cx),math.floor(cx)
            if index==self.strip_count then
                if not inward then left,right=0,width end
            elseif effect=='wave' then
                -- Low-amplitude wave: keep text still and change only the front.
                local edge=width*(1-progress)+math.min(width,height)*.03
                    * math.sin(math.pi*progress)*math.sin(2*math.pi*(y+hh/2)/height)
                if self.direction==SwipeRefresh.FORWARD then left,right=math.ceil(edge),width
                else left,right=0,math.floor(width-edge) end
            else
                local dy=inward and math.max(0,y-cy,cy-(y+hh))
                    or math.max(math.abs(y-cy),math.abs(y+hh-cy))
                if inward or dy*dy<radius_squared then
                    local half=math.sqrt(math.max(0,radius_squared-dy*dy))
                    if inward then left,right=math.floor(cx-half),math.ceil(cx+half)
                    else left,right=math.ceil(cx-half),math.floor(cx+half) end
                end
            end
            left,right=math.max(0,left),math.min(width,right)
            if right<left then left,right=math.floor(cx),math.floor(cx) end
            local old=self.reveal_edges[y]
            if not old then
                local start=effect=='wave' and (self.direction==SwipeRefresh.FORWARD and width or 0) or math.floor(cx)
                old=inward and {0,width} or {start,start}
            end
            if inward then
                reveal(old[1],left,y,hh,1);reveal(right,old[2],y,hh,2)
            else
                reveal(left,old[1],y,hh,1);reveal(old[2],right,y,hh,2)
            end
            self.reveal_edges[y]={left,right}
        end
        -- At most four driver updates, grouped by half-screen and moving edge.
        -- Exclude completed inner text where possible, with no final full pass.
        for _,pair in ipairs{{1,2},{3,4}} do
            local a,b=damage[pair[1]],damage[pair[2]]
            local function aligned(box)
                if not box then return end
                box[1],box[2]=math.floor(box[1]/align)*align,math.floor(box[2]/align)*align
                box[3],box[4]=math.min(width,math.ceil(box[3]/align)*align),math.min(height,math.ceil(box[4]/align)*align)
            end
            aligned(a);aligned(b)
            if a and b and a[3]>=b[1] then
                a[1],a[2],a[3],a[4]=math.min(a[1],b[1]),math.min(a[2],b[2]),math.max(a[3],b[3]),math.max(a[4],b[4]);b=nil
            end
            for _,box in pairs{a,b} do self:_refreshSoftwareRegion(box[1],box[2],box[3]-box[1],box[4]-box[2]) end
        end
    end, traceback)
    if type(screen.afterPaint) == "function" then pcall(screen.afterPaint, screen) end
    if not ok then return nil, err end
    return true
end

function SwipeRefresh:_submitSoftwareStrip(target, x, width, height)
    local screen = self.screen
    local bb = screen and screen.bb
    if not bb or width <= 0 then return true end

    local screen_width = bb:getWidth()
    local left = math.max(0, math.floor((x - SOFTWARE_OVERLAP) / SOFTWARE_ALIGNMENT)
        * SOFTWARE_ALIGNMENT)
    local right = math.min(screen_width,
        math.ceil((x + width + SOFTWARE_OVERLAP) / SOFTWARE_ALIGNMENT)
            * SOFTWARE_ALIGNMENT)
    if self.software_effect == 'swipe' then
        left, right = x, math.min(screen_width, x + width)
    end
    local refreshed_width = right - left
    if refreshed_width <= 0 then return true end

    if type(screen.beforePaint) == "function" then pcall(screen.beforePaint, screen) end
    local ok, err = xpcall(function()
        -- The target is the only retained page buffer.  Re-copying the small
        -- overlap makes adjacent UI submissions share their edge instead of
        -- leaving an unpainted one-pixel seam on aligned Kindle panels.
        bb:blitFrom(target, left, 0, left, 0, refreshed_width, height)
        -- KOReader builds differ: some expose refreshFast as a non-callable
        -- placeholder (or omit it entirely). Keep the Swipe animation alive
        -- by selecting Fast only when it is an actual function.
        self:_refreshSoftwareRegion(left, 0, refreshed_width, height)
    end, traceback)
    if type(screen.afterPaint) == "function" then pcall(screen.afterPaint, screen) end
    if not ok then return nil, err end
    return true
end

function SwipeRefresh:_runSoftwareFrame(token)
    if token ~= self.generation or self.mode ~= "software" or not self.running then return end

    local screen = self.screen
    local bb = screen and screen.bb
    local target = self.target_framebuffer
    if not bb or not target then
        self:_completeSoftware(token)
        return
    end

    local width = bb:getWidth()
    local height = bb:getHeight()
    if target:getWidth() ~= width or target:getHeight() ~= height then
        self:_completeSoftware(token)
        return
    end
    if self.upstream_swipe then
        local painted = self:_runUpstreamSwipe(token, target, width, height)
        self:_completeSoftware(token, painted)
        return
    end
    local frame_started = self.clock()
    local index = self.strip_index + 1
    local submitted = true
    if RIPPLE_EFFECTS[self.software_effect] then
        submitted = self:_submitRippleFrame(target, index, width, height)
    else
        local x, strip_width = self:_softwareStripFor(index, width, self.strip_count)
        if strip_width > 0 then submitted = self:_submitSoftwareStrip(target, x, strip_width, height) end
    end
    if not submitted then
        -- ReaderView rebuilds its current logical page on a driver error.
        self:_completeSoftware(token)
        return
    end
    self.strip_index = index

    if self.strip_index >= self.strip_count then
        self:_completeSoftware(token, true)
    else
        local delay=math.max(self.frame_delay>0 and .001 or 0,self.frame_delay-(self.clock()-frame_started))
        local scheduled = self:_scheduleSoftwareFrame(token, delay)
        if not scheduled then self:_completeSoftware(token) end
    end
end

-- Swipe_Animation's wipe runs as one paint transaction: copy/submit each
-- aligned strip, then wait between strips (8 portrait / 6 landscape).
-- Unlike the other local effects, do not return to background UI work between
-- strips. Keep this opt-in path local; never replace the host repaint loop.
function SwipeRefresh:_runUpstreamSwipe(token, target, width, height)
    local screen, bb = self.screen, self.screen.bb
    local steps = self.strip_count
    if type(screen.beforePaint) == 'function' then pcall(screen.beforePaint, screen) end
    local ok, painted = xpcall(function()
        for i = 1, steps do
            if token ~= self.generation or not self.running or screen.bb ~= bb
                    or bb:getWidth() ~= width or bb:getHeight() ~= height then return false end
            local left, strip_width = self:_softwareStripFor(i, width, steps)
            bb:blitFrom(target, left, 0, left, 0, strip_width, height)
            self:_refreshSoftwareRegion(left, 0, strip_width, height)
            if token ~= self.generation or not self.running then return false end
            self.strip_index = i
            if i < steps and self.frame_delay > 0 then
                require('ffi/util').usleep(self.frame_delay * 1000000)
            end
        end
        return true
    end, traceback)
    if type(screen.afterPaint) == 'function' then pcall(screen.afterPaint, screen) end
    return ok and painted == true
end

function SwipeRefresh:_completeWave(request_generation, wave_token, target, painted)
    if request_generation ~= self.generation or self.mode ~= "wave" or not self.running then
        freeBuffer(target)
        return
    end
    local callback = self._on_complete
    self.target_framebuffer = nil
    self._on_complete = nil
    self.running = false
    self.mode = nil
    self.direction = nil
    freeBuffer(target)
    if type(callback) == "function" then pcall(callback, wave_token, painted) end
end

-- Render the latest page and replace any active transition. The options are
-- deliberately explicit so a chapter boundary can never accidentally use a
-- same-page native swipe.
function SwipeRefresh:begin(widget, direction, on_complete, options)
    options = options or {}
    if direction ~= SwipeRefresh.FORWARD and direction ~= SwipeRefresh.BACKWARD then
        return nil, "无效的翻页方向"
    end

    local chapter_changed = options.chapter_changed == true
    local page_animation_enabled = options.page_animation_enabled ~= false
    if not page_animation_enabled then
        return nil, "页面动画已关闭"
    end

    self:_invalidate()
    local use_wave = chapter_changed
        and options.chapter_clean_wave_enabled == true
        and self:isChapterWaveAvailable()
    local use_native = options.effect ~= 'swipe' and options.effect ~= 'swipe_classic'
        and not RIPPLE_EFFECTS[options.effect] and self:isNativeSwipeAvailable()
    local use_software = not use_native
        and self:isSoftwareSwipeAvailable()
    if not use_wave and not use_native and not use_software then
        return nil, "当前正文刷新后端没有启用的页面动画"
    end
    if not self.ui_manager
            or (type(self.ui_manager.scheduleIn) ~= "function"
                and type(self.ui_manager.nextTick) ~= "function") then
        return nil, "动画调度器不可用"
    end

    local target, err = self:_renderTarget(widget)
    if not target then return nil, err end
    self.target_framebuffer = target
    self.direction = direction
    self.running = true
    self._on_complete = on_complete
    local request_generation = self.generation

    if use_wave then
        self.mode = "wave"
        local started, wave_token_or_err = self.chapter_wave:begin(target, direction,
            function(wave_token, completed_target, painted)
                self:_completeWave(request_generation, wave_token, completed_target, painted)
            end)
        if not started then
            self:_invalidate()
            return nil, wave_token_or_err
        end
        return true, request_generation
    end

    if use_native then
        self.mode = "native"
        local submitted, submit_err = self.native_swipe:submit(target, direction)
        if not submitted then
            self:_invalidate()
            return nil, submit_err
        end
        local scheduled, schedule_err = self:_scheduleNativeSubmissionCommit(request_generation)
        if not scheduled then
            self:_invalidate()
            return nil, schedule_err
        end
        return true, request_generation
    end

    self.mode = "software"
    local width = self.screen.bb:getWidth()
    local height = self.screen.bb:getHeight()
    self.upstream_swipe = options.effect == 'swipe_classic'
    self.software_effect = (options.effect == 'original' or self.upstream_swipe) and 'swipe' or options.effect
    self.refresh_mode = options.refresh_mode == 'fast' and 'fast' or 'ui'
    local delay = tonumber(width > height and options.landscape_delay_ms or options.portrait_delay_ms)
    if not delay or delay ~= delay or delay < 0 or delay > 200 then delay = width > height and 10 or 20 end
    self.frame_delay = delay / 1000
    self.strip_index = 0
    self.strip_count = self:_softwareSteps(width, height)
    local align = tonumber(self.screen.alignment_constraint)
    if self.device.isKobo and self.device:isKobo() and self.device.hasColorScreen and self.device:hasColorScreen() then align = nil end
    if not align or align ~= align or align < 2 or align > 128 or align % 1 ~= 0 then align = nil end
    self.software_alignment = align or SOFTWARE_ALIGNMENT
    self.reveal_edges = RIPPLE_EFFECTS[options.effect] and {} or nil
    if self.software_effect == 'swipe' then
        -- Strip edges adapted from Swipe_Animation v4.3, 59dce480 (GPLv3).
        -- Keep device alignment without taking over the global repaint loop.
        self.strip_edges = {0}
        for i = 1, self.strip_count - 1 do
            local raw = width * i / self.strip_count
            local cut = align and align >= 2 and math.floor((raw + align / 2) / align) * align or math.floor(raw)
            if cut > self.strip_edges[#self.strip_edges] and cut < width then self.strip_edges[#self.strip_edges+1] = cut end
        end
        self.strip_edges[#self.strip_edges+1] = width
        self.strip_count = #self.strip_edges - 1
    end
    local scheduled, schedule_err = self:_scheduleSoftwareFrame(request_generation, 0)
    if not scheduled then
        self:_invalidate()
        return nil, schedule_err
    end
    return true, request_generation
end

-- Finish the target before another local UI surface is shown.  This commits
-- the target to Screen.bb and returns immediately; the physical waveform is
-- owned by Screen/EPDC and is never synchronously awaited here.
function SwipeRefresh:settle()
    if not self.running or not self.target_framebuffer then return false end
    if self.mode == "wave" then
        return self.chapter_wave:settle()
    end

    local token = self.generation
    self:_unschedulePendingFrame()
    self.generation = self.generation + 1
    local target = self.target_framebuffer
    local callback = self._on_complete
    local mode = self.mode
    self.target_framebuffer = nil
    self._on_complete = nil
    self.running = false
    self.mode = nil
    self.direction = nil
    self.strip_index = 0
    self.strip_count = 0
    self.reveal_edges = nil
    local painted=mode == 'native' or self:_submitTarget(target)
    if mode == "native" then
        -- The MTK backend normally consumes this one-shot flag with the
        -- original refresh.  Clear it again at this UI boundary so a host
        -- that deferred submission cannot carry native swipe into a menu.
        self.native_swipe:reset()
    end
    -- Screen:refreshUI has copied the target into the Screen.bb working
    -- surface and submitted it.  The driver owns the physical waveform from
    -- this point; this method never waits for that waveform to finish.
    freeBuffer(target)
    if type(callback) == "function" then pcall(callback, token, painted==true) end
    return true
end

-- Used when the reader is being covered or destroyed. The next UI surface owns
-- its own repaint, so do not submit a half-complete target here.
function SwipeRefresh:cancel()
    if not self.running and not self.target_framebuffer then return nil end
    self:_invalidate()
    return true
end

return SwipeRefresh
