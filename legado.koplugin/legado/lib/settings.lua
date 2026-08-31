local Settings = {}
Settings.__index = Settings

Settings.SCHEMA_VERSION = 1
Settings.DEFAULTS = {
    timeout = 20,
    max_response_bytes = 4 * 1024 * 1024,
    redirects = 5,
    concurrency = 2,
    max_concurrency = 3,
    pagination = 20,
    prefetch = 3,
    prefetch_min = 0,
    prefetch_max = 10,
    shelf_page = 20,
    covers_enabled = true,
    log_level = "info",
}

local function copy(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function koreader_adapter()
    local loaded_settings, LuaSettings = pcall(require, "luasettings")
    local loaded_storage, DataStorage = pcall(require, "datastorage")
    if not (loaded_settings and loaded_storage and LuaSettings and DataStorage) then return nil end
    if type(LuaSettings.open) ~= "function" or type(DataStorage.getDataDir) ~= "function" then return nil end
    local path = DataStorage:getDataDir() .. "/settings/legado.lua"
    local store = LuaSettings:open(path)
    return {
        read = function() return store:readSetting("legado_settings") or {} end,
        write = function(value) store:saveSetting("legado_settings", value); store:flush() return true end,
    }
end

function Settings.new(adapter)
    adapter = adapter or koreader_adapter() or { read = function() return {} end, write = function() return true end }
    local stored = adapter.read and adapter.read() or {}
    local values = copy(Settings.DEFAULTS)
    for key, value in pairs(stored or {}) do values[key] = value end
    values.schema_version = Settings.SCHEMA_VERSION
    local self = setmetatable({ adapter = adapter, values = values }, Settings)
    self:_write()
    return self
end

function Settings:_write()
    if self.adapter.write then return self.adapter.write(copy(self.values)) end
    return true
end

function Settings:get(key)
    return self.values[key]
end

function Settings:set(key, value)
    if key == "prefetch" then
        value = math.max(Settings.DEFAULTS.prefetch_min, math.min(Settings.DEFAULTS.prefetch_max, tonumber(value) or Settings.DEFAULTS.prefetch))
    elseif key == "concurrency" then
        value = math.max(1, math.min(Settings.DEFAULTS.max_concurrency, tonumber(value) or Settings.DEFAULTS.concurrency))
    end
    self.values[key] = value
    return self:_write()
end

function Settings:all()
    return copy(self.values)
end

return Settings
