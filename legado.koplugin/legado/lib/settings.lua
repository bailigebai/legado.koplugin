local Errors = require("legado.lib.errors")

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

local function normalized(key, value)
    if key == "prefetch" then
        return math.max(Settings.DEFAULTS.prefetch_min, math.min(Settings.DEFAULTS.prefetch_max,
            math.floor(tonumber(value) or Settings.DEFAULTS.prefetch)))
    elseif key == "concurrency" then
        return math.max(2, math.min(Settings.DEFAULTS.max_concurrency,
            math.floor(tonumber(value) or Settings.DEFAULTS.concurrency)))
    elseif key == "timeout" then
        return math.max(1, math.min(20, tonumber(value) or Settings.DEFAULTS.timeout))
    elseif key == "shelf_page" then
        return math.max(5, math.min(50, math.floor(tonumber(value) or Settings.DEFAULTS.shelf_page)))
    end
    return value
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
        write = function(value)
            local saved = store:saveSetting("legado_settings", value)
            if saved == false then return false end
            local flushed = store:flush()
            return flushed ~= false
        end,
    }
end

function Settings.new(adapter)
    adapter = adapter or koreader_adapter() or { read = function() return {} end, write = function() return true end }
    local read_ok, stored = true, {}
    if adapter.read then read_ok, stored = pcall(adapter.read) end
    local values = copy(Settings.DEFAULTS)
    if read_ok and type(stored) == "table" then
        for key, value in pairs(stored) do values[key] = normalized(key, value) end
    end
    values.schema_version = Settings.SCHEMA_VERSION
    local self = setmetatable({ adapter = adapter, values = values }, Settings)
    if not read_ok or type(stored) ~= "table" then
        self.init_error = Errors.new(Errors.STORAGE_ERROR, "settings could not be loaded")
        return self, self.init_error
    end
    local written, write_error = self:_write(values)
    if not written then self.init_error = write_error end
    return self, self.init_error
end

function Settings:_write(values)
    if self.adapter.write then
        local ok, written = pcall(self.adapter.write, copy(values or self.values))
        if not ok or written == false or written == nil then
            return nil, Errors.new(Errors.STORAGE_ERROR, "settings could not be saved")
        end
    end
    return true
end

function Settings:get(key)
    return self.values[key]
end

function Settings:set(key, value)
    local candidate = copy(self.values)
    candidate[key] = normalized(key, value)
    local written, err = self:_write(candidate)
    if not written then self.init_error = err; return nil, err end
    self.values, self.init_error = candidate, nil
    return candidate[key]
end

function Settings:all()
    return copy(self.values)
end

return Settings
