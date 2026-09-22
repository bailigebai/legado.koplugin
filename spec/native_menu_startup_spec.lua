require("library_screen_stub")
local A = require("assertions")
local count = 0
local function equal(expected, actual, message)
    count = count + 1; A.equal(expected, actual, message)
end
local function truthy(value, message)
    count = count + 1; A.truthy(value, message)
end

local root = assert(os.getenv("LEGADO_PLUGIN_ROOT")):gsub("\\", "/")
-- PluginLoader adds only plugin/?.lua, never plugin/?/init.lua.
package.path = root .. "/?.lua"
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(base, fields) return setmetatable(fields, { __index = base }) end }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "/memory" end, getSettingsDir = function() return "/memory/settings" end }
end
local messages = {}
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, _, action) return action end,
        show = function(_, widget) messages[#messages + 1] = widget.text end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, value) return value end }
end
local files = {}
local fs = {
    ensureDirectory = function() return true end,
    read = function(_, path) return files[path] end,
    atomicWrite = function(_, path, data) files[path] = data; return true end,
}
require("legado.lib.fs").new = function() return fs end

local plugin = require("main")
local deferred = setmetatable({}, { __index = plugin })
function deferred:_getApp() error("module 'legado.missing' not found: private-input-must-not-appear") end
local deferred_items = {}
local deferred_ok = pcall(deferred.addToMainMenu, deferred, deferred_items)
truthy(deferred_ok, "menu registration does not depend on optional service startup")
truthy(deferred_items.legado, "menu entry remains visible when a service is unavailable")
equal("首页", deferred_items.legado.sub_item_table[1].text, "deferred menu keeps home action")
local click_ok, click_result = pcall(deferred_items.legado.sub_item_table[2].callback)
truthy(click_ok, "startup failure must not crash the host on click")
equal(false, click_result, "failed startup returns an explicit unsuccessful result")
equal(1, #messages, "startup failure displays a diagnostic")
truthy(messages[1]:find("legado.missing", 1, true), "diagnostic identifies the missing module")
equal(nil, messages[1]:find("private-input", 1, true), "diagnostic omits arbitrary error payloads")
function deferred:_getApp() return { openBookshelf = function() return "recovered" end } end
equal("recovered", deferred_items.legado.sub_item_table[2].callback(), "a later click retries startup")

local instance = setmetatable({ ui = {} }, { __index = plugin })
local ok, app = pcall(instance._getApp, instance)
truthy(ok, "full startup resolves modules under KOReader's real plugin search path: " .. tostring(app))
truthy(app.storage, "production storage is initialized")
truthy(app.service, "production book service is initialized")
truthy(app.source_manager, "source management is available")
equal("bookshelf", instance:openBookshelf().kind, "native launch opens the bookshelf")

local items = {}
instance:addToMainMenu(items)
equal("tools", items.legado.sorting_hint, "entry belongs directly to the tools tab")
equal("书源阅读", items.legado.text, "entry keeps its Chinese label")

local upstream = os.getenv("LEGADO_KOREADER_SOURCE")
if upstream then
    package.preload["ffi/util"] = function() return { orderedPairs = pairs } end
    package.preload["libs/libkoreader-lfs"] = function() return {} end
    package.preload["logger"] = function() return { warn = function() end } end
    package.preload["gettext"] = function() return function(text) return text end end
    package.preload["device"] = function()
        return setmetatable({}, { __index = function() return function() return false end end })
    end
    local sorter = dofile(upstream .. "/frontend/ui/menusorter.lua")
    for _, mode in ipairs({ "filemanager", "reader" }) do
        local order = dofile(upstream .. "/frontend/ui/elements/" .. mode .. "_menu_order.lua")
        local native_items = {}
        for id in pairs(order) do native_items[id] = { text = id } end
        instance:addToMainMenu(native_items)
        local sorted = sorter:sort(native_items, order)
        local tools = sorter:findById(sorted, "tools")
        local found = false
        for _, item in ipairs(tools) do if item.id == "legado" then found = true end end
        truthy(found, mode .. " official menu places the entry directly under tools")
    end
end

return count
