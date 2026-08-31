local CoverGrid = {}

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
        ui_manager = injected.ui_manager or require("ui/uimanager"),
    }
end

function CoverGrid.new(options)
    options = options or {}
    local deps = dependencies(options.dependencies)
    local model, layout, rows, cells = options.model or { items = {} }, {}, {}, {}
    for offset = 1, #(model.items or {}), 3 do
        local focus_row, visual_row = {}, {}
        for column = 0, 2 do
            local item = model.items[offset + column]
            if item then
                local cover
                if item.cover then cover = deps.image:new({ file = item.cover, width = options.cover_width or 120, height = options.cover_height or 160, scale_factor = 0 })
                else cover = deps.text:new({ text = item.cover_text or "无封面", width = options.cover_width or 120 }) end
                local button = deps.button:new({ text = item.title or "未命名", callback = function() if options.on_select then return options.on_select(item.book) end end })
                local visual = deps.vertical_group:new({ cover, button })
                cells[#cells + 1] = { item = item, visual = visual, button = button }
                visual_row[#visual_row + 1] = deps.frame:new({ visual })
                focus_row[#focus_row + 1] = button
            end
        end
        rows[#rows + 1] = deps.horizontal_group:new(visual_row)
        layout[#layout + 1] = focus_row
    end
    local controls, focus_controls = {}, {}
    local close_grid
    local function control(text, callback)
        if callback then
            local button = deps.button:new({ text = text, callback = callback })
            controls[#controls + 1], focus_controls[#focus_controls + 1] = button, button
        end
    end
    control("上一页", options.on_prev)
    control("文字模式", options.on_toggle)
    control("下一页", options.on_next)
    control("返回", function() return close_grid() end)
    if #controls > 0 then rows[#rows + 1] = deps.horizontal_group:new(controls); layout[#layout + 1] = focus_controls end
    local Grid = deps.focus_manager
    if type(deps.focus_manager.extend) == "function" then Grid = deps.focus_manager:extend({}) end
    local widget = Grid:new({ layout = layout, deps.vertical_group:new(rows) })
    widget.kind, widget.cells, widget.model, widget.alive = "cover_grid", cells, model, true
    local closed = false
    local function finalize_close()
        if closed then return false end
        closed = true
        widget.alive = false
        for _, cell in ipairs(cells) do cell.item.on_update = nil end
        if options.on_close then options.on_close() end
        return true
    end
    close_grid = function()
        if closed then return false end
        if deps.ui_manager and type(deps.ui_manager.close) == "function" then deps.ui_manager:close(widget) end
        finalize_close()
        return true
    end
    widget.close_button = controls[#controls]
    widget.key_events = widget.key_events or {}
    widget.key_events.Close = { { "Back" }, { "Close" }, event = "Close" }
    widget.onClose = close_grid
    for _, cell in ipairs(cells) do
        cell.item.on_update = function(item)
            if not widget.alive then return end
            if item.cover then cell.visual[1] = deps.image:new({ file = item.cover, width = options.cover_width or 120, height = options.cover_height or 160, scale_factor = 0 }) end
            if type(cell.visual.resetLayout) == "function" then cell.visual:resetLayout() end
            if widget[1] and type(widget[1].resetLayout) == "function" then widget[1]:resetLayout() end
            if deps.ui_manager and type(deps.ui_manager.setDirty) == "function" then deps.ui_manager:setDirty(widget, "ui") end
        end
    end
    widget.onCloseWidget = finalize_close
    return widget
end

return CoverGrid
