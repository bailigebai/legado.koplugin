local Json = require("legado.lib.json_codec")

local Store = {}
Store.__index = Store

function Store.new(settings)
    return setmetatable({ settings = settings, direct_values = {} }, Store)
end

-- Some Kindle/FAT combinations can create the settings file but cannot
-- replace an existing file atomically. Keep the license receipt in a small
-- sibling file so authorization is independent from ordinary preferences.
function Store:_licenseFile()
    local settings = self.settings
    local adapter = settings and settings.adapter
    local path = settings and settings.storage_path
    local fs = adapter and adapter.fs
    if type(path) ~= "string" or path == "" or type(fs) ~= "table"
        or type(fs.read) ~= "function" or type(fs.atomicWrite) ~= "function" then
        return nil, nil
    end
    local directory = path:match("^(.*)[/\\][^/\\]+$")
    if not directory or directory == "" then return nil, nil end
    return directory .. "/legado-license.json", fs
end

function Store:_readLicenseFile()
    local path, fs = self:_licenseFile()
    if not path then return nil, false end
    local ok, raw, read_error = pcall(fs.read, fs, path)
    if not ok then return nil, false end
    if raw == nil then
        local details = type(read_error) == "table" and read_error.details or nil
        if type(details) == "table" and details.reason == "missing" then return {}, true end
        return nil, false
    end
    if type(raw) ~= "string" or raw == "" then return nil, false end
    local decoded, value = pcall(Json.decode, raw)
    if not decoded or type(value) ~= "table" then return nil, true end
    return value, true
end

function Store:_writeLicenseFile(values)
    local path, fs = self:_licenseFile()
    if not path then return false end
    local encoded, bytes = pcall(Json.encode, values or {})
    if not encoded then return false end
    local ok, result = pcall(fs.atomicWrite, fs, path, bytes)
    return ok and result ~= false and result ~= nil
end

local function license_value(key, value)
    if key ~= "license_receipt" then return value end
    local ok, encoded = pcall(Json.encode, value)
    return ok and encoded or nil
end

local function decode_license_value(key, value)
    if key ~= "license_receipt" or type(value) ~= "string" or value == "" then return value end
    local ok, decoded = pcall(Json.decode, value)
    return ok and decoded or nil
end

function Store:readSetting(key)
    local license_file, available = self:_readLicenseFile()
    if available and type(license_file) == "table" and license_file[key] ~= nil then
        return decode_license_value(key, license_file[key])
    end
    if not self.settings or type(self.settings.get) ~= "function" then return nil end
    local value = self.settings:get(key)
    if key == "license_receipt" and type(value) == "string" and value ~= "" then
        local ok, decoded = pcall(Json.decode, value)
        return ok and decoded or nil
    end
    return value ~= "" and value or nil
end

function Store:saveSetting(key, value)
    if self.settings and type(self.settings.set) == "function" then
        local candidate = value
        if key == "license_receipt" then
            local encoded, result = pcall(Json.encode, value)
            if not encoded then return false end
            candidate = result
        end
        local ok, saved = pcall(self.settings.set, self.settings, key, candidate)
        if ok and saved ~= nil then
            self.direct_values[key] = nil
            return true
        end
    end
    local license_file, available = self:_readLicenseFile()
    if not available or type(license_file) ~= "table" then return false end
    local encoded = license_value(key, value)
    license_file[key] = encoded
    if not self:_writeLicenseFile(license_file) then return false end
    self.direct_values[key] = value
    return true
end

local function same_value(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same_value(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

-- Disk rollback can fail too. Restore the cached value independently so an
-- unconfirmed activation is never usable in the current reading session.
function Store:restoreSetting(key, value)
    if key == "license_receipt" and value ~= nil then value = Json.encode(value) end
    self.settings.values[key] = value or ""
end

function Store:flush()
    if next(self.direct_values) ~= nil then
        local values, available = self:_readLicenseFile()
        if not available or type(values) ~= "table" then return false end
        for key, expected in pairs(self.direct_values) do
            local actual = decode_license_value(key, values[key])
            if not same_value(expected, actual) then return false end
        end
        return true
    end
    -- Settings:set already writes atomically; confirm through its disk reader,
    -- not the cached values, before License accepts the activation.
    local adapter = self.settings and self.settings.adapter
    if not adapter or type(adapter.read) ~= "function" then return false end
    local ok, saved = pcall(adapter.read)
    if not ok or type(saved) ~= "table" then return false end
    for _, key in ipairs({ "license_receipt", "license_installation_id" }) do
        if saved[key] ~= self.settings:get(key) then return false end
    end
    return true
end

return Store
