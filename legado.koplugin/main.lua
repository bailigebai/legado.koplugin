local WidgetContainer = require("ui/widget/container")

local Legado = WidgetContainer:extend({
    name = "legado",
    is_doc_only = false,
})

function Legado:_getApp()
    if not self._app then self._app = require("legado.ui.bootstrap").build(self) end
    return self._app
end

function Legado:launch()
    return self:_getApp():openBookshelf()
end

function Legado:openBookshelf()
    return self:_getApp():openBookshelf()
end

function Legado:addToMainMenu(menu_items)
    if type(menu_items) ~= "table" then
        return
    end

    local app = self:_getApp()
    menu_items.legado = {
        text = "书源阅读",
        sorting_hint = "network",
        sub_item_table = app:menuItems(),
    }
end

return Legado
