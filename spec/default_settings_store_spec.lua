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
        if state.mode == "fail" then return nil, { code = "STORAGE_ERROR" } end
        if state.mode == "throw" then error("atomic backend panic") end
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
local restarted = Settings.new(nil, { data_dir = "settings-root", fs = fs })
equal(9, restarted:get("prefetch"), "atomic settings survive restart")

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
equal("STORAGE_ERROR", corrupted_error and corrupted_error.code, "corrupt JSON reports initialization failure")
equal(0, corrupted.writes, "corrupt JSON is never overwritten with defaults")
equal("{broken", corrupted.files[json_path], "corrupt settings remain available for manual recovery")

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
equal("STORAGE_ERROR", invalid_json_error and invalid_json_error.code, "out-of-range canonical settings fail closed")
equal(0, invalid_json.writes, "invalid canonical settings are not normalized and overwritten")

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

return count
