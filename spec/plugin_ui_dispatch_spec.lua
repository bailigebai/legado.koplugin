local assertx = require("assertions")

package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(base, fields) return setmetatable(fields or {}, { __index = base }) end }
end

local Plugin = require("main")
local calls = {}
Plugin._app = {}
local methods = { "openHome", "openBookshelf", "openSearch", "openSources", "openDownloads", "openSettings", "openAbout", "openDiscovery" }
for _, method in ipairs(methods) do
    Plugin._app[method] = function() calls[#calls + 1] = method; return method end
end

local menu = {}
Plugin:addToMainMenu(menu)
for _, item in ipairs(menu.legado.sub_item_table) do item.callback() end
for index, method in ipairs(methods) do
    assertx.equal(method, calls[index], "menu dispatches to " .. method)
end
assertx.equal("openBookshelf", Plugin:openBookshelf(), "public shelf entry delegates to app")
assertx.equal("openHome", Plugin:launch(), "stable launch entry opens home")

return 11
