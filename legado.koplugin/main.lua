local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Legado = WidgetContainer:extend({
    name = "legado",
    is_doc_only = false,
})

function Legado:init()
    self.ui.menu:registerToMainMenu(self)
end

function Legado:onReaderReady()
    require('legado.lib.ai_selection_context').attach(self.ui,function(text,document)
        return self:_getApp():explainSelection(text,document)
    end)
    require('legado.lib.excerpt_context').attach(self.ui,function(text,document,range)
        return self:_getApp():captureExcerpt(text,document,range)
    end)
    if self._app and self._app.excerpt_service then self._app.excerpt_service:schedule() end
end

function Legado:onNetworkConnected()
    if self._app and self._app.excerpt_service then self._app.excerpt_service:schedule() end
end

function Legado:onCloseDocument()
    require('legado.lib.ai_selection_context').detach(self.ui)
    require('legado.lib.excerpt_context').detach(self.ui)
end

function Legado:_getApp()
    if not self._app then self._app = require("legado.ui.bootstrap").build(self) end
    return self._app
end

function Legado:launch()
    return self:openHome()
end

function Legado:openHome()
    return self:_open("openHome")
end

function Legado:openBookshelf()
    return self:_open("openBookshelf")
end

function Legado:_open(method)
    local ok, result = pcall(function()
        local app = self:_getApp()
        return app[method](app)
    end)
    if ok then return result end

    local detail = ""
    if type(result) == "string" then
        local missing = result:match("module '([%w_./%-]+)' not found")
        local location = result:match("([%w_%-]+%.lua:%d+):")
        if missing then detail = detail .. "\n缺少模块：" .. missing end
        if location then detail = detail .. "\n位置：" .. location end
    end
    local text = "不亦阅乎打开失败（" .. (self.version or "未知版本") .. "）。" .. detail
        .. "\n请保留此提示和本次启动的 koreader/crash.log 供排查。"
    print("[legado] " .. text)
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = text })
    return false
end

function Legado:addToMainMenu(menu_items)
    if type(menu_items) ~= "table" then
        return
    end

    menu_items.legado = {
        text = "不亦阅乎",
        sorting_hint = "tools",
        sub_item_table = {
            { text = "打开书架", callback = function() return self:openBookshelf() end },
            { text = "Obsidian 摘录", callback = function() return self:_getApp():openExcerpts() end },
        },
    }
end

return Legado
