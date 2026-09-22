local assertx = require("assertions")
local Settings = require("legado.lib.settings")
local Json = require("legado.lib.json_codec")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function memory_fs(initial)
    local state = { files = initial or {}, writes = 0, mode = "ok" }
    local fs = {}
    function fs:read(path)
        local value = state.files[path]
        if value == nil then return nil, { code = "STORAGE_ERROR", details = { reason = "missing" } } end
        return value
    end
    function fs:atomicWrite(path, value)
        state.writes = state.writes + 1
        if state.mode == "fail" or state.fail_path == path then return nil, { code = "STORAGE_ERROR" } end
        if state.mode == "throw" or state.throw_path == path then error("atomic backend panic") end
        state.files[path] = value
        return true
    end
    return fs, state
end

local flush_calls = 0
package.loaded["luasettings"] = nil
package.loaded["datastorage"] = nil
package.preload["luasettings"] = function()
    return { open = function()
        return {
            readSetting = function() return {} end,
            saveSetting = function(self) return self end,
            flush = function(self) flush_calls = flush_calls + 1; return self end,
        }
    end }
end
package.preload["datastorage"] = function()
    return { getDataDir = function() return "wrong-luasettings-root" end }
end

local json_path = "settings-root/settings/legado.json"
local legacy_path = "settings-root/settings/legado.lua"
local fs, state = memory_fs()
local settings, init_error = Settings.new(nil, { data_dir = "settings-root", fs = fs })
equal(nil, init_error, "fresh default settings initialize through the atomic store")
equal(0, flush_calls, "production default settings never call LuaSettings flush")
equal(1, state.writes, "fresh settings are atomically created once")
truthy(type(state.files[json_path]) == "string", "default settings use a dedicated JSON file")
local envelope = Json.decode(state.files[json_path])
equal(1, envelope.schema_version, "settings file is versioned")
equal(3, envelope.settings.prefetch, "settings JSON contains normalized defaults")

equal(9, settings:set("prefetch", 9), "atomic default store accepts updates")
settings:set('progress_bar_mode','bar')
settings:set('progress_bar_font_size',18)
settings:set('progress_bar_height',32)
settings:set('receipt_style','calendar')
settings:set('receipt_width',80)
settings:set('receipt_height',85)
settings:set('receipt_background','/mnt/us/pictures/背景 image.jpg')
local restarted = Settings.new(nil, { data_dir = "settings-root", fs = fs })
equal(9, restarted:get("prefetch"), "atomic settings survive restart")
equal('bar',restarted:get('progress_bar_mode'),'JSON validator accepts saved footer mode')
equal(18,restarted:get('progress_bar_font_size'),'footer font survives JSON reload')
equal(32,restarted:get('progress_bar_height'),'footer height survives JSON reload')
equal('calendar',restarted:get('receipt_style'),'receipt style survives JSON reload')
equal(80,restarted:get('receipt_width'),'receipt width survives JSON reload')
equal(85,restarted:get('receipt_height'),'receipt height survives JSON reload')
equal('/mnt/us/pictures/背景 image.jpg',restarted:get('receipt_background'),'background path with Unicode and spaces survives reload')
for _,style in ipairs{'bookshop','boarding','library','cinema','postcard','newspaper',
    'exhibition','passport','contact','archive','timeline','bookmark'} do
    equal(style,restarted:set('receipt_style',style),'new receipt style is accepted for saving')
    local loaded,err=Settings.new(nil,{data_dir='settings-root',fs=fs})
    equal(nil,err,'new receipt style passes strict JSON validation')
    equal(style,loaded:get('receipt_style'),'new receipt style survives restart')
end

local disk_before = state.files[json_path]
state.mode = "fail"
local saved, write_error = restarted:set("prefetch", 2)
equal(nil, saved, "atomicWrite false rejects the update")
equal("STORAGE_ERROR", write_error and write_error.code, "atomicWrite false is structured")
equal(9, restarted:get("prefetch"), "atomicWrite false preserves memory")
equal(disk_before, state.files[json_path], "atomicWrite false preserves disk")
state.mode = "throw"
saved, write_error = restarted:set("prefetch", 1)
equal(nil, saved, "atomicWrite panic is contained")
equal("STORAGE_ERROR", write_error and write_error.code, "atomicWrite panic is structured")
equal(9, restarted:get("prefetch"), "atomicWrite panic preserves memory")
state.mode = "ok"
equal(1, restarted:set("prefetch", 1), "default store recovers after a transient write outage")
equal(1, Settings.new(nil, { data_dir = "settings-root", fs = fs }):get("prefetch"),
    "recovered settings persist on restart")

local corrupted_fs, corrupted = memory_fs({ [json_path] = "{broken" })
local corrupted_settings, corrupted_error = Settings.new(nil, { data_dir = "settings-root", fs = corrupted_fs })
equal("table", type(corrupted_settings), "corrupt settings still return an inspectable object")
equal("RECOVERY_REQUIRED", corrupted_error and corrupted_error.code, "corrupt JSON requires explicit recovery")
equal(0, corrupted.writes, "corrupt JSON is never overwritten with defaults")
equal("{broken", corrupted.files[json_path], "corrupt settings remain available for manual recovery")
saved, write_error = corrupted_settings:set("prefetch", 4)
equal(nil, saved, "ordinary set is locked while canonical recovery is required")
equal("RECOVERY_REQUIRED", write_error and write_error.code, "locked set returns RECOVERY_REQUIRED")
equal("{broken", corrupted.files[json_path], "locked set preserves corrupt canonical bytes")
local retried, retry_error = corrupted_settings:retryRecovery()
equal(nil, retried, "retry remains locked while canonical bytes are still corrupt")
equal("RECOVERY_REQUIRED", retry_error and retry_error.code, "failed retry remains structured")
corrupted.files[json_path] = Json.encode({ schema_version = 1, settings = { prefetch = 8 } })
equal(true, corrupted_settings:retryRecovery(), "retry succeeds after external canonical repair")
equal(8, corrupted_settings:get("prefetch"), "successful retry adopts repaired settings")
equal(false, corrupted_settings.recovery_required, "successful retry clears recovery mode")

local reset_original = '{"schema_version":1,"settings":{"prefetch":3,"prefetch":4}}'
local reset_fs, reset_state = memory_fs({ [json_path] = reset_original,
    [json_path .. ".corrupt-1"] = "older backup" })
local reset_settings = Settings.new(nil, { data_dir = "settings-root", fs = reset_fs })
local backup_path, reset_error = reset_settings:resetCorrupt()
equal(nil, reset_error, "explicit corrupt reset succeeds")
equal(json_path .. ".corrupt-2", backup_path, "reset never overwrites an existing backup")
equal(reset_original, reset_state.files[backup_path], "reset backup preserves exact corrupt bytes")
local reset_envelope = Json.decode(reset_state.files[json_path])
equal(3, reset_envelope.settings.prefetch, "reset publishes versioned safe defaults")
equal(false, reset_settings.recovery_required, "successful reset clears recovery mode")
equal(3, Settings.new(nil, { data_dir = "settings-root", fs = reset_fs }):get("prefetch"),
    "reset canonical settings survive restart")

local backup_fail_fs, backup_fail = memory_fs({ [json_path] = reset_original })
backup_fail.fail_path = json_path .. ".corrupt-1"
local backup_fail_settings = Settings.new(nil, { data_dir = "settings-root", fs = backup_fail_fs })
backup_path, reset_error = backup_fail_settings:resetCorrupt()
equal(nil, backup_path, "backup failure aborts reset")
equal("STORAGE_ERROR", reset_error and reset_error.code, "backup failure is structured")
equal(reset_original, backup_fail.files[json_path], "backup failure preserves original canonical bytes")
equal(true, backup_fail_settings.recovery_required, "backup failure remains recovery-locked")

local publish_fail_fs, publish_fail = memory_fs({ [json_path] = reset_original })
publish_fail.fail_path = json_path
local publish_fail_settings = Settings.new(nil, { data_dir = "settings-root", fs = publish_fail_fs })
backup_path, reset_error = publish_fail_settings:resetCorrupt()
equal(nil, backup_path, "canonical publication failure aborts reset")
equal("STORAGE_ERROR", reset_error and reset_error.code, "canonical publication failure is structured")
equal(reset_original, publish_fail.files[json_path], "canonical publication failure preserves original bytes")
equal(true, publish_fail_settings.recovery_required, "canonical publication failure remains recovery-locked")
local first_failed_backup = publish_fail.files[json_path .. ".corrupt-1"]
publish_fail.fail_path = json_path
backup_path, reset_error = publish_fail_settings:resetCorrupt()
equal(nil, backup_path, "a repeated failed reset remains blocked")
equal(reset_original, first_failed_backup, "the first successful backup retains the corrupt bytes")
equal(reset_original, publish_fail.files[json_path .. ".corrupt-1"],
    "a repeated reset never overwrites the first backup")
equal(reset_original, publish_fail.files[json_path .. ".corrupt-2"],
    "a repeated reset allocates the next unused backup name")

local backup_throw_fs, backup_throw = memory_fs({ [json_path] = reset_original })
backup_throw.throw_path = json_path .. ".corrupt-1"
local backup_throw_settings = Settings.new(nil, { data_dir = "settings-root", fs = backup_throw_fs })
backup_path, reset_error = backup_throw_settings:resetCorrupt()
equal(nil, backup_path, "throwing backup aborts reset")
equal("STORAGE_ERROR", reset_error and reset_error.code, "throwing backup is structured")
equal(reset_original, backup_throw.files[json_path], "throwing backup preserves original bytes")
equal(true, backup_throw_settings.recovery_required, "throwing backup remains recovery-locked")

local publish_throw_fs, publish_throw = memory_fs({ [json_path] = reset_original })
publish_throw.throw_path = json_path
local publish_throw_settings = Settings.new(nil, { data_dir = "settings-root", fs = publish_throw_fs })
backup_path, reset_error = publish_throw_settings:resetCorrupt()
equal(nil, backup_path, "throwing canonical publication aborts reset")
equal("STORAGE_ERROR", reset_error and reset_error.code, "throwing canonical publication is structured")
equal(reset_original, publish_throw.files[json_path], "throwing canonical publication preserves original bytes")
equal(true, publish_throw_settings.recovery_required, "throwing canonical publication remains recovery-locked")

local read_error_fs, read_error_state = memory_fs()
function read_error_fs:read(candidate)
    if candidate == json_path then return nil, { code = "STORAGE_ERROR", details = { reason = "permission denied" } } end
    return nil, { code = "STORAGE_ERROR", details = { reason = "missing" } }
end
local read_error_settings, read_error = Settings.new(nil, { data_dir = "settings-root", fs = read_error_fs })
equal("RECOVERY_REQUIRED", read_error and read_error.code,
    "a canonical read error is distinct from an absent canonical file")
equal(true, read_error_settings.recovery_required, "a canonical read error locks ordinary writes")
equal(0, read_error_state.writes, "a canonical read error performs no writes")

local read_throw_fs, read_throw_state = memory_fs()
function read_throw_fs:read(candidate)
    if candidate == json_path then error("read backend panic") end
    return nil, { code = "STORAGE_ERROR", details = { reason = "missing" } }
end
local read_throw_settings, read_throw_error = Settings.new(nil, { data_dir = "settings-root", fs = read_throw_fs })
equal("RECOVERY_REQUIRED", read_throw_error and read_throw_error.code,
    "a throwing canonical read is contained as explicit recovery")
equal(true, read_throw_settings.recovery_required, "a throwing canonical read stays locked")
equal(0, read_throw_state.writes, "a throwing canonical read performs no writes")

local legacy = [[-- settings-root/settings/legado.lua
return {
    ["legado_settings"] = {
        ["prefetch"] = 7,
        ["concurrency"] = 3,
        ["covers_enabled"] = false,
        ["log_level"] = "info",
    },
}]]
local legacy_fs, migrated = memory_fs({ [legacy_path] = legacy })
local migrated_settings, migration_error = Settings.new(nil, { data_dir = "settings-root", fs = legacy_fs })
equal(nil, migration_error, "safe legacy scalar settings migrate")
equal(7, migrated_settings:get("prefetch"), "legacy value is retained")
equal(false, migrated_settings:get("covers_enabled"), "legacy boolean is retained")
truthy(type(migrated.files[json_path]) == "string", "successful migration atomically creates JSON")
equal(7, Settings.new(nil, { data_dir = "settings-root", fs = legacy_fs }):get("prefetch"),
    "restart prefers the migrated JSON file")

local migration_fail_fs, migration_failed = memory_fs({ [legacy_path] = legacy })
migration_failed.mode = "fail"
local migration_failed_settings, migration_write_error = Settings.new(nil,
    { data_dir = "settings-root", fs = migration_fail_fs })
equal("STORAGE_ERROR", migration_write_error and migration_write_error.code,
    "failed atomic legacy migration is reported")
equal(7, migration_failed_settings:get("prefetch"), "failed migration retains legacy values in memory")
equal(legacy, migration_failed.files[legacy_path], "failed migration preserves the legacy disk file")
equal(nil, migration_failed.files[json_path], "failed migration never publishes partial JSON")
migration_failed.mode = "ok"
local recovered_migration, recovered_migration_error = Settings.new(nil,
    { data_dir = "settings-root", fs = migration_fail_fs })
equal(nil, recovered_migration_error, "legacy migration can recover on the next startup")
equal(7, recovered_migration:get("prefetch"), "recovered migration retains the legacy value")
truthy(type(migration_failed.files[json_path]) == "string", "recovered migration publishes JSON atomically")

local invalid_envelope = Json.encode({ schema_version = 1, settings = { prefetch = 99 } })
local invalid_json_fs, invalid_json = memory_fs({ [json_path] = invalid_envelope })
local _, invalid_json_error = Settings.new(nil, { data_dir = "settings-root", fs = invalid_json_fs })
equal("RECOVERY_REQUIRED", invalid_json_error and invalid_json_error.code, "out-of-range canonical settings fail closed")
equal(0, invalid_json.writes, "invalid canonical settings are not normalized and overwritten")

for _, duplicate_json in ipairs({
    '{"schema_version":1,"schema_version":1,"settings":{}}',
    '{"schema_version":1,"settings":{},"settings":{}}',
    '{"schema_version":1,"settings":{"prefetch":3,"prefetch":4}}',
    '{"schema_version":1,"settings":{"nested":{"key":1,"key":2}}}',
}) do
    local duplicate_fs, duplicate_state = memory_fs({ [json_path] = duplicate_json })
    local _, duplicate_error = Settings.new(nil, { data_dir = "settings-root", fs = duplicate_fs })
    equal("RECOVERY_REQUIRED", duplicate_error and duplicate_error.code,
        "duplicate canonical JSON enters explicit recovery mode")
    equal(0, duplicate_state.writes, "duplicate canonical JSON is never overwritten")
    equal(duplicate_json, duplicate_state.files[json_path], "duplicate canonical bytes remain unchanged")
end

for _, hostile in ipairs({
    'return { ["legado_settings"] = { ["prefetch"] = os.execute("bad") } }',
    'return { ["legado_settings"] = { ["prefetch"] = 3, ["prefetch"] = 4 } }',
    'return { ["legado_settings"] = { ["unknown"] = 1 } }',
    'return { ["legado_settings"] = { ["log_level"] = [[info]] } }',
    'return setmetatable({}, {})',
}) do
    local hostile_fs, hostile_state = memory_fs({ [legacy_path] = hostile })
    local _, hostile_error = Settings.new(nil, { data_dir = "settings-root", fs = hostile_fs })
    equal("STORAGE_ERROR", hostile_error and hostile_error.code, "unsafe or invalid legacy syntax is rejected")
    equal(0, hostile_state.writes, "rejected legacy data is never migrated")
end

local oversized_fs, oversized = memory_fs({ [legacy_path] = "return {" .. string.rep(" ", 65537) .. "}" })
local _, oversized_error = Settings.new(nil, { data_dir = "settings-root", fs = oversized_fs })
equal("STORAGE_ERROR", oversized_error and oversized_error.code, "oversized legacy settings are rejected")
equal(0, oversized.writes, "oversized legacy settings are not migrated")

local mode_fs = memory_fs()
local mode_settings = Settings.new(nil, { data_dir = 'settings-root', fs = mode_fs })
equal(true, mode_settings:set('immersive_reader', true), 'enable mode saves successfully')
equal(true, mode_settings:get('immersive_reader'), 'enabled mode is visible immediately')
equal(true, Settings.new(nil, { data_dir = 'settings-root', fs = mode_fs }):get('immersive_reader'), 'enabled mode survives restart')
equal(false, mode_settings:set('immersive_reader', false), 'disable mode is a successful false value')
equal(false, Settings.new(nil, { data_dir = 'settings-root', fs = mode_fs }):get('immersive_reader'), 'disabled mode survives restart')
return count
