local assertx = require("assertions")

package.preload["ui/widget/container"] = function()
    return {
        extend = function(base, fields)
            return setmetatable(fields or {}, { __index = base })
        end,
    }
end

local plugin = require("main")
local menu_items = {}
plugin:addToMainMenu(menu_items)
plugin:addToMainMenu(nil)

assertx.type("table", plugin, "plugin loads without optional KOReader services")
assertx.type("table", menu_items.legado, "menu remains available without optional services")
assertx.truthy(plugin:launch(), "launch remains safe without optional services")

return 3
