require("library_screen_stub")
local A = require("assertions")
local View = require("legado.ui.settings")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local values = { download_cache_dir = "" }
local writes = 0
local settings = {
    all = function() return values end,
    get = function(_, key) return values[key] end,
    set = function(_, key, value) writes = writes + 1; values[key] = value; return value end,
    status = function() return {} end,
}
local view = View.new({ settings = settings, default_download_cache_dir = "/mnt/us/koreader/legado/offline-cache",
    validate_download_cache_dir = function(path)
        if path == "/mnt/us/readonly" then return nil, {code="STORAGE_ERROR"} end
        return true
    end })
local value, err = view:set("download_cache_dir", "../wrong")
eq(nil, value, "relative download cache directory is not saved")
eq("INVALID_INPUT", err.code, "invalid path has a structured error")
eq(0, writes, "invalid directory does not touch settings")
value, err = view:set("download_cache_dir", "/mnt/us/readonly")
eq(nil, value, "directory initialization failure is rejected")
eq("STORAGE_ERROR", err.code, "directory failure is reported")
eq(0, writes, "directory initialization failure does not persist")
eq("/mnt/us/books-cache", view:set("download_cache_dir", "/mnt/us/books-cache"),
    "valid directory is persisted")

local shown = {}
local widget = { new = function(_, options) return options end }
local presenter = Presenter.new({ menu = widget, input_dialog = widget,
    ui_manager = { show = function(_, item) shown[#shown + 1] = item end, close = function() return true end } })
local menu = presenter:show(view)
local directory
for _, item in ipairs(menu.item_table) do
    if item.text:find("离线缓存目录", 1, true) then directory = item end
end
eq("function", type(directory and directory.callback), "cache directory has a reachable setting action")
directory.callback()
eq("修改离线缓存目录", shown[#shown].title, "directory uses its own text input")
eq("string", shown[#shown].input_type, "directory input accepts filesystem paths")

return count
