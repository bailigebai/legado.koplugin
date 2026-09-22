local assertx = require("assertions")
local Bootstrap = require("legado.ui.bootstrap")
local Presenter = require("legado.ui.presenter")
local Json = require("legado.lib.json_codec")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local path = "bootstrap-data/settings/legado.json"
local corrupt = '{"schema_version":1,"settings":{"prefetch":3,"prefetch":4}}'
local files, writes = { [path] = corrupt }, 0
local fs = {}
function fs:read(candidate)
    if files[candidate] ~= nil then return files[candidate] end
    return nil, { code = "STORAGE_ERROR", details = { reason = "missing" } }
end
function fs:atomicWrite(candidate, value)
    writes = writes + 1
    files[candidate] = value
    return true
end

local app = Bootstrap.build({}, { settings_options = { data_dir = "bootstrap-data", fs = fs } })
equal("RECOVERY_REQUIRED", app.settings_error and app.settings_error.code,
    "Bootstrap retains the Settings.new initialization error")
local view = app:openSettings()
equal(true, view:status().recovery_required, "Bootstrap passes recovery state into SettingsView")
local saved, locked_error = view:set("prefetch", 9)
equal(nil, saved, "ordinary setting edit is locked in recovery mode")
equal("RECOVERY_REQUIRED", locked_error and locked_error.code, "locked edit remains structured")
equal(corrupt, files[path], "locked edit preserves original canonical bytes")

local shown, closed = {}, {}
local function widget(kind) return { new = function(_, options) options.kind = kind; return options end } end
local presenter = Presenter.new({
    ui_manager = { show = function(_, item) shown[#shown + 1] = item end,
        close = function(_, item) closed[#closed + 1] = item end },
    menu = widget("menu"), input_dialog = widget("input"), info_message = widget("info"),
})
local menu = presenter:show(view)
equal("设置文件损坏，正在使用安全默认值，普通保存已锁定", menu.item_table[1].text,
    "settings page visibly explains recovery lock")
equal(false, menu.item_table[1].enabled, "recovery warning is informational")
local retry_item, reset_item
for _, item in ipairs(menu.item_table) do
    if item.text == "重试读取" then retry_item = item end
    if item.text == "备份后重置" then reset_item = item end
end
truthy(type(retry_item and retry_item.callback) == "function", "retry action is keyboard-focusable")
truthy(type(reset_item and reset_item.callback) == "function", "reset action is keyboard-focusable")

local nested_view = {
    values = { progress_bar = true, progress_bar_mode = "details", progress_bar_font_size = 12, progress_bar_height = 24 },
    refresh = function(self) return self.values end,
    status = function() return { recovery_required = true } end,
    set = function() return nil, { code = "RECOVERY_REQUIRED" } end,
    retryRecovery = function() return false, { code = "RECOVERY_REQUIRED" } end,
}
local progress_menu = presenter:_readerProgressSettings(nested_view)
local progress_recovery = false
for _, item in ipairs(progress_menu.item_table) do
    if item.text == "设置文件损坏，普通保存已锁定" then progress_recovery = true end
end
truthy(progress_recovery, "bottom progress settings expose recovery state")
local chrome_menu = presenter:_readerChromeSettings(nested_view)
local chrome_recovery = false
for _, item in ipairs(chrome_menu.item_table) do
    if item.text == "设置文件损坏，普通保存已锁定" then chrome_recovery = true end
end
truthy(chrome_recovery, "header footer settings expose recovery state")

retry_item.callback()
equal(true, view:status().recovery_required, "retry against unchanged corrupt bytes remains locked")
equal(corrupt, files[path], "failed retry preserves corrupt canonical bytes")

reset_item.callback()
local dialog = shown[#shown]
equal("input", dialog.kind, "reset requires an explicit confirmation dialog")
local closed_before = #closed
dialog.buttons[1][2].callback("wrong")
equal(closed_before, #closed, "incorrect confirmation keeps reset dialog open")
equal(corrupt, files[path], "incorrect confirmation cannot reset settings")
dialog.buttons[1][2].callback("重置")
equal(closed_before + 1, #closed, "correct confirmation closes the reset dialog once")
equal(false, view:status().recovery_required, "confirmed backup and reset clears recovery mode")
equal(corrupt, files[path .. ".corrupt-1"], "UI reset backup preserves exact original bytes")
local envelope = Json.decode(files[path])
equal(3, envelope.settings.prefetch, "UI reset publishes safe versioned defaults")
truthy(shown[#shown].text:find("corrupt%-1") ~= nil, "success message identifies the backup path")

local restarted = Bootstrap.build({}, { settings_options = { data_dir = "bootstrap-data", fs = fs } })
equal(nil, restarted.settings_error, "Bootstrap restart accepts the recovered canonical settings")
equal(3, restarted:openSettings().values.prefetch, "restarted SettingsView uses recovered defaults")
equal(true, writes >= 2, "recovery uses atomic writes for backup and canonical publication")

local initial_files, initial_fail = {}, true
local initial_fs = {}
function initial_fs:read(candidate)
    if initial_files[candidate] then return initial_files[candidate] end
    return nil, { code = "STORAGE_ERROR", details = { reason = "missing" } }
end
function initial_fs:atomicWrite(candidate, value)
    if initial_fail then return nil, { code = "STORAGE_ERROR" } end
    initial_files[candidate] = value
    return true
end
local initial_app = Bootstrap.build({}, { settings_options = { data_dir = "initial-data", fs = initial_fs } })
equal("STORAGE_ERROR", initial_app.settings_error and initial_app.settings_error.code,
    "Bootstrap retains an initial publication warning")
local initial_view = initial_app:openSettings()
local initial_menu = presenter:show(initial_view)
equal("设置持久化暂不可用，修改后将重试保存", initial_menu.item_table[1].text,
    "initial write failure is visible but not recovery-locked")
initial_fail = false
equal(6, initial_view:set("prefetch", 6), "ordinary edit retries after an initial publication failure")
equal(false, initial_view:status().initial_write_failed, "successful edit clears persistence warning state")

return count
