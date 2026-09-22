local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Legado = WidgetContainer:extend({
    name = "legado",
    is_doc_only = false,
})

function Legado:init()
    self.ui.menu:registerToMainMenu(self)
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
    local text = "书源阅读打开失败（" .. (self.version or "未知版本") .. "）。" .. detail
        .. "\n请保留此提示和本次启动的 koreader/crash.log 供排查。"
    print("[legado] " .. text)
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = text })
    return false
end

function Legado:addToMainMenu(menu_items)
    if type(menu_items) ~= "table" then
        return
    end

    local function action(name)
        return function()
            return self:_open(name)
        end
    end
    menu_items.legado = {
        text = "书源阅读",
        sorting_hint = "tools",
        sub_item_table = {
            { text = "首页", callback = action("openHome") },
            { text = "书架", callback = action("openBookshelf") },
            { text = "搜索", callback = action("openSearch") },
            { text = "书源管理", callback = action("openSources") },
            { text = "下载管理", callback = action("openDownloads") },
            { text = "设置", callback = action("openSettings") },
            { text = "关于", callback = action("openAbout") },
            { text = "发现", callback = action("openDiscovery") },
        },
    }
end

return Legado
