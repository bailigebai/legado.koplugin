local assertx = require("assertions")
local CoverGrid = require("legado.ui.cover_grid")
local Presenter = require("legado.ui.presenter")

local function class(kind)
    return { new = function(_, options) options.kind = kind; return options end }
end

local function focus_class()
    local Focus = class("focus")
    function Focus:extend(prototype)
        prototype.new = function(_, options)
            setmetatable(options, { __index = prototype })
            return options
        end
        return prototype
    end
    return Focus
end

local function grid_dependencies(ui, device)
    return {
        focus_manager = focus_class(), button = class("button"), horizontal_group = class("horizontal"),
        vertical_group = class("vertical"), frame = class("frame"), image = class("image"), text = class("text"),
        ui_manager = ui, device = device,
    }
end

do
    local back_group = { "device-back-group" }
    local grid = CoverGrid.new({
        model = { items = {} },
        dependencies = grid_dependencies({ close = function() end }, {
            hasKeys = function() return true end,
            input = { group = { Back = back_group } },
        }),
    })
    assertx.equal(back_group, grid.key_events.Close[1][1], "cover grid preserves Device.input.group.Back object identity")
end

do
    local grid = CoverGrid.new({
        model = { items = {} },
        dependencies = grid_dependencies({ close = function() end }, {
            hasKeys = function() return false end,
            input = { group = { Back = { "unused" } } },
        }),
    })
    assertx.equal(nil, grid.key_events.Close, "cover grid leaves Close unregistered on a device without keys")
end

do
    local stack, close_calls = {}, 0
    local ui = {
        show = function(_, widget) stack[#stack + 1] = widget end,
        close = function(_, widget)
            close_calls = close_calls + 1
            for index, candidate in ipairs(stack) do if candidate == widget then table.remove(stack, index); break end end
            if type(widget.onCloseWidget) == "function" then widget:onCloseWidget() end
        end,
        setDirty = function() end,
    }
    local presenter = Presenter.new({
        ui_manager = ui,
        cover_grid_factory = function(options)
            options.dependencies = grid_dependencies(ui, { hasKeys = function() return false end, input = { group = { Back = {} } } })
            return CoverGrid.new(options)
        end,
    })
    local operations = {
        { page = 1, button = "下一页" },
        { page = 2, button = "上一页" },
        { page = 1, button = "文字模式" },
    }
    for _, operation in ipairs(operations) do
        local shelf = { kind = "bookshelf", alive = true, last_item = nil }
        function shelf:page(page, mode)
            local item = { title = "一本书", cover_text = "封面加载中", book = { id = "book" } }
            self.last_item = item
            return { page = page, page_count = 2, mode = mode, items = { item } }
        end
        function shelf:close() self.alive = false; return true end
        local old = presenter:_shelf(shelf, operation.page, "cover")
        local late_item = shelf.last_item
        local button
        for _, candidate in ipairs(old.layout[#old.layout]) do
            if candidate.text == operation.button then button = candidate; break end
        end
        assertx.truthy(button, operation.button .. " control is reachable")
        button.callback()
        local current = stack[#stack]
        assertx.truthy(current ~= old, operation.button .. " replaces the old cover grid")
        assertx.equal(false, old.alive, operation.button .. " marks the old grid inactive")
        assertx.equal(true, shelf.alive, operation.button .. " does not terminate the shelf controller")
        assertx.equal(nil, late_item.on_update, operation.button .. " detaches old cover update callback before a late result")
        if late_item.on_update then late_item.on_update(late_item) end
        assertx.equal(1, #stack, operation.button .. " leaves exactly one active widget on the UI stack")
        if current.kind == "cover_grid" then current:onClose() else ui:close(current) end
    end
    assertx.truthy(close_calls >= 6, "replacement and terminal closes both reach UIManager")
end

return 24
