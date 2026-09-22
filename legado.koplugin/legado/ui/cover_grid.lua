local CoverGrid = {}

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

local function copy_key_events(events)
    local copied = {}
    for name, binding in pairs(events or {}) do copied[name] = binding end
    return copied
end

local function dependencies(injected)
    injected = injected or {}
    return {
        focus_manager = injected.focus_manager or require("ui/widget/focusmanager"),
        button = injected.button or require("ui/widget/button"),
        horizontal_group = injected.horizontal_group or require("ui/widget/horizontalgroup"),
        vertical_group = injected.vertical_group or require("ui/widget/verticalgroup"),
        frame = injected.frame or require("ui/widget/container/framecontainer"),
        image = injected.image or require("ui/widget/imagewidget"),
        text = injected.text or require("ui/widget/textwidget"),
        font = injected.font or require("ui/font"),
        ui_manager = injected.ui_manager or require("ui/uimanager"),
        device = injected.device or optional("device"),
    }
end

function CoverGrid.new(options)
    options = options or {}
    local deps = dependencies(options.dependencies)
    local model, layout, rows, cells = options.model or { items = {} }, {}, {}, {}
    local close_grid
    local function navigate(callback, ...)
        if not close_grid() then return false end
        return callback(...)
    end
    local screen = deps.device and deps.device.screen
    local function scale(value) return screen and screen.scaleBySize and screen:scaleBySize(value) or value end
    local cell_width = math.floor((screen and screen:getWidth() or 600) / 3) - scale(12)
    local cover_width = math.min(options.cover_width or scale(120), cell_width)
    local cover_height = options.cover_height or scale(160)
    local function cover_for(item)
        if item.cover then return deps.image:new({ file = item.cover, width = cover_width, height = cover_height, scale_factor = 0 }) end
        return deps.text:new({ text = item.cover_text or "无封面", face = deps.font:getFace("cfont", 18),
            max_width = cover_width, forced_height = cover_height, forced_baseline = math.floor(cover_height / 2) })
    end
    for offset = 1, #(model.items or {}), 3 do
        local focus_row, visual_row = {}, {}
        for column = 0, 2 do
            local item = model.items[offset + column]
            if item then
                local cover = cover_for(item)
                local button = deps.button:new({ text = item.title or "未命名", width = cell_width, radius = scale(10), avoid_text_truncation = false,
                    callback = function() if options.on_select then return navigate(options.on_select, item.book) end end })
                local visual = deps.vertical_group:new({ cover, button })
                cells[#cells + 1] = { item = item, visual = visual, button = button }
                visual_row[#visual_row + 1] = deps.frame:new({ padding = scale(4), bordersize = scale(1), radius = scale(8), visual })
                focus_row[#focus_row + 1] = button
            end
        end
        rows[#rows + 1] = deps.horizontal_group:new(visual_row)
        layout[#layout + 1] = focus_row
    end
    local controls = {}
    local function control(text, callback)
        if callback then
            local button = deps.button:new({ text = text, callback = callback, width = cell_width, radius = scale(10), avoid_text_truncation = false })
            controls[#controls + 1] = button
        end
    end
    control("上一页", options.on_prev)
    control("文字模式", options.on_toggle)
    control("下一页", options.on_next)
    for _, extra in ipairs(options.extra_controls or {}) do
        if extra.callback then control(extra.text, function() return navigate(extra.callback) end) end
    end
    control("返回", function() return close_grid() end)
    for offset = 1, #controls, 3 do
        local row = {}
        for index = offset, math.min(offset + 2, #controls) do row[#row + 1] = controls[index] end
        rows[#rows + 1] = deps.horizontal_group:new(row)
        layout[#layout + 1] = row
    end
    local Grid = deps.focus_manager
    if type(deps.focus_manager.extend) == "function" then Grid = deps.focus_manager:extend({}) end
    local widget = Grid:new({ layout = layout, deps.vertical_group:new(rows) })
    widget.kind, widget.cells, widget.model, widget.alive = "cover_grid", cells, model, true
    local closed, closing_terminal = false, true
    local function finalize_close(terminal)
        if closed then return false end
        closed = true
        widget.alive = false
        for _, cell in ipairs(cells) do cell.item.on_update = nil end
        if terminal and options.on_close then options.on_close() end
        return true
    end
    close_grid = function()
        if closed then return false end
        closing_terminal = true
        if deps.ui_manager and type(deps.ui_manager.close) == "function" then deps.ui_manager:close(widget) end
        finalize_close(true)
        return true
    end
    widget.close_button = controls[#controls]
    widget.key_events = copy_key_events(widget.key_events)
    if deps.device and type(deps.device.hasKeys) == "function" and deps.device:hasKeys()
        and deps.device.input and deps.device.input.group and deps.device.input.group.Back then
        widget.key_events.Close = { { deps.device.input.group.Back } }
    else
        widget.key_events.Close = nil
    end
    widget.onClose = close_grid
    widget.closeForReplacement = function()
        if closed then return false end
        closing_terminal = false
        if deps.ui_manager and type(deps.ui_manager.close) == "function" then deps.ui_manager:close(widget) end
        finalize_close(false)
        return true
    end
    for _, cell in ipairs(cells) do
        cell.item.on_update = function(item)
            if not widget.alive then return end
            local old_cover = cell.visual[1]
            cell.visual[1] = cover_for(item)
            if type(old_cover.free) == "function" then old_cover:free() end
            if type(cell.visual.resetLayout) == "function" then cell.visual:resetLayout() end
            for _, row in ipairs(rows) do if type(row.resetLayout) == "function" then row:resetLayout() end end
            if widget[1] and type(widget[1].resetLayout) == "function" then widget[1]:resetLayout() end
            if deps.ui_manager and type(deps.ui_manager.setDirty) == "function" then deps.ui_manager:setDirty(widget, "ui") end
        end
    end
    widget.onCloseWidget = function() return finalize_close(closing_terminal) end
    return widget
end

return CoverGrid
