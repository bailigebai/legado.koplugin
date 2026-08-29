local WidgetContainer = require("ui/widget/container")

local Legado = WidgetContainer:extend({
    name = "legado",
    is_doc_only = false,
})

function Legado:launch()
    return true
end

function Legado:openBookshelf()
    return self:launch()
end

function Legado:addToMainMenu(menu_items)
    if type(menu_items) ~= "table" then
        return
    end

    menu_items.legado = {
        text = "书源阅读",
        sorting_hint = "network",
        sub_item_table = {
            { text = "书架", callback = function() return self:openBookshelf() end },
            { text = "搜索", callback = function() return self:launch() end },
            { text = "书源管理", callback = function() return self:launch() end },
            { text = "下载管理", callback = function() return self:launch() end },
            { text = "设置", callback = function() return self:launch() end },
            { text = "关于", callback = function() return self:launch() end },
        },
    }
end

return Legado
