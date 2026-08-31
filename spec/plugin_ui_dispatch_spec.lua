local assertx = require("assertions")

package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(base, fields) return setmetatable(fields or {}, { __index = base }) end }
end

local Plugin = require("main")
local calls = {}
Plugin._app = {
    menuItems = function()
        local labels = { "书架", "搜索", "书源管理", "下载管理", "设置", "关于" }
        local methods = { "shelf", "search", "sources", "downloads", "settings", "about" }
        local items = {}
        for index, label in ipairs(labels) do
            items[index] = { text = label, callback = function() calls[#calls + 1] = methods[index]; return methods[index] end }
        end
        return items
    end,
    openBookshelf = function() calls[#calls + 1] = "direct-shelf"; return "direct-shelf" end,
}

local menu = {}
Plugin:addToMainMenu(menu)
for _, item in ipairs(menu.legado.sub_item_table) do item.callback() end
assertx.equal("shelf", calls[1], "shelf menu dispatches to app")
assertx.equal("search", calls[2], "search menu dispatches to app")
assertx.equal("sources", calls[3], "source menu dispatches to app")
assertx.equal("downloads", calls[4], "download menu dispatches to app")
assertx.equal("settings", calls[5], "settings menu dispatches to app")
assertx.equal("about", calls[6], "about menu dispatches to app")
assertx.equal("direct-shelf", Plugin:openBookshelf(), "public shelf entry delegates to app")
assertx.equal("direct-shelf", Plugin:launch(), "stable launch entry opens shelf")

return 8
