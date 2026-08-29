local assertx = require("assertions")
local plugin_root = assert(os.getenv("LEGADO_PLUGIN_ROOT"), "missing plugin root")

local function extend(base, fields)
    fields = fields or {}
    return setmetatable(fields, { __index = base })
end

package.preload["ui/widget/container"] = function()
    return { extend = extend }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

local metadata = dofile(plugin_root .. "/_meta.lua")
local plugin = require("main")
local menu_items = {}

assertx.equal("legado", metadata.name, "plugin discovery metadata")
assertx.type("table", plugin, "plugin loads with KOReader fakes")
assertx.equal("legado", plugin.name, "plugin name")
assertx.equal(false, plugin.is_doc_only, "plugin is available outside documents")
assertx.type("function", plugin.addToMainMenu, "main menu hook")
assertx.type("function", plugin.launch, "stable launch entry point")
assertx.type("function", plugin.openBookshelf, "stable bookshelf entry point")

plugin:addToMainMenu(menu_items)
assertx.type("table", menu_items.legado, "plugin menu registration")
assertx.type("table", menu_items.legado.sub_item_table, "planned menu entries")

local labels = {}
for _, item in ipairs(menu_items.legado.sub_item_table) do
    labels[#labels + 1] = item.text
end
assertx.equal("书架", labels[1], "bookshelf label")
assertx.equal("搜索", labels[2], "search label")
assertx.equal("书源管理", labels[3], "source management label")
assertx.equal("下载管理", labels[4], "download management label")
assertx.equal("设置", labels[5], "settings label")
assertx.equal("关于", labels[6], "about label")
assertx.truthy(plugin:launch(), "launch is safe before later UI tasks")
assertx.truthy(plugin:openBookshelf(), "bookshelf entry is safe before later UI tasks")

return 20
