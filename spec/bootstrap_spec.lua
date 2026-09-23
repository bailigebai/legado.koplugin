require("library_screen_stub")
local assertx = require("assertions")
local data_root = assert(os.getenv("LEGADO_PLUGIN_ROOT")):gsub("/legado%.koplugin$", "") .. "/.tools/bootstrap-data"
local events = {}
local sources = {}
local storage_license

package.preload["datastorage"] = function() return { getDataDir = function() return data_root end } end
package.preload["ui/uimanager"] = function() return {
    scheduleIn = function(_, _, action) return action end,
    show = function() end,
} end
package.preload["ui/event"] = function() return { new = function(_, name) return { name = name } end } end
package.preload["legado.lib.storage"] = function() return { new = function(options)
    storage_license=options.license
    return {
    listShelf = function() return {} end, listSources = function() return sources end,
    replaceSources = function(_, value) sources = value; return true end,
    getSource = function() end,
    listDownloadTasks = function() return {} end,
    putDownloadTask = function(_, task) return task end,
    listChapters = function() return {} end,
    replaceChapters = function() return true end,
} end } end
package.preload["legado.lib.request_engine"] = function() return { new = function(options) return {
    scheduler = options.scheduler,
    execute = function() return { cancel = function() return true end } end,
} end } end

local Bootstrap = require("legado.ui.bootstrap")
local plugin = { ui = { handleEvent = function(_, event) events[#events + 1] = event; return true end } }
local app = Bootstrap.build(plugin, { settings_adapter = { read = function() return {} end, write = function() return true end } })
assertx.equal("table", type(app), "real bootstrap composes an App with complete boundary fakes")
assertx.equal(app.license, storage_license, "book admission shares the app's verified offline license")
assertx.equal("search", app:openSearch().kind, "bootstrap wires BookService into search controller")
assertx.equal("bookshelf", app:openBookshelf().kind, "bootstrap wires storage into shelf controller")
local settings = app:openSettings()
assertx.equal(true, settings.actions[1].callback(), "native appearance action is handled")
assertx.equal("ShowConfigMenu", events[1].name, "appearance action uses KOReader reader-config event API")
assertx.truthy(app.cover_loader, "bootstrap injects nonblocking cover loader")
assertx.truthy(app.download_manager, "bootstrap composes EPUB download manager from KOReader services")
assertx.equal(0, #app:openSearch():sourceChoices(), "fresh startup leaves sources empty until the user imports them")
assertx.equal(nil, app.settings:get('default_sources_initialized'), "startup has no default-source initialization setting")

return 10
