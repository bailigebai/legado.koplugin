local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Json = require("legado.lib.json_codec")

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

local MAX_SETTINGS_BYTES = 64 * 1024

local function parse_legacy(input)
    if type(input) ~= "string" or #input > MAX_SETTINGS_BYTES then error("invalid legacy settings size") end
    local position, length = 1, #input
    local function whitespace()
        while position <= length and input:sub(position, position):match("%s") do position = position + 1 end
    end
    local function consume(value)
        whitespace()
        if input:sub(position, position + #value - 1) ~= value then error("invalid legacy settings syntax") end
        position = position + #value
    end
    local parse_value
    local function parse_string()
        whitespace()
        local quote = input:sub(position, position)
        if quote ~= '"' and quote ~= "'" then error("legacy string expected") end
        position = position + 1
        local output = {}
        while position <= length do
            local character = input:sub(position, position)
            position = position + 1
            if character == quote then return table.concat(output) end
            if character == "\n" or character == "\r" then error("unterminated legacy string") end
            if character ~= "\\" then output[#output + 1] = character
            else
                local escaped = input:sub(position, position)
                position = position + 1
                local simple = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", v = "\v",
                    ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
                if simple[escaped] then output[#output + 1] = simple[escaped]
                elseif escaped:match("%d") then
                    local digits = escaped
                    for _ = 1, 2 do
                        local next_digit = input:sub(position, position)
                        if not next_digit:match("%d") then break end
                        digits, position = digits .. next_digit, position + 1
                    end
                    local byte = tonumber(digits)
                    if not byte or byte > 255 then error("invalid legacy string escape") end
                    output[#output + 1] = string.char(byte)
                else error("unsupported legacy string escape") end
            end
        end
        error("unterminated legacy string")
    end
    local function parse_identifier()
        whitespace()
        local identifier = input:sub(position):match("^[_%a][_%w]*")
        if not identifier then error("legacy identifier expected") end
        position = position + #identifier
        return identifier
    end
    local function parse_table(depth)
        if depth > 4 then error("legacy settings nesting limit") end
        consume("{")
        local result, seen, array_index = {}, {}, 1
        whitespace()
        while input:sub(position, position) ~= "}" do
            if position > length then error("unterminated legacy table") end
            local key
            if input:sub(position, position) == "[" then
                position = position + 1
                key = parse_value(depth + 1)
                if type(key) ~= "string" and type(key) ~= "number" then error("invalid legacy table key") end
                consume("]"); consume("=")
            else
                local saved = position
                local ok, identifier = pcall(parse_identifier)
                whitespace()
                if ok and input:sub(position, position) == "=" then
                    position = position + 1; key = identifier
                else
                    position = saved; key = array_index; array_index = array_index + 1
                end
            end
            if seen[key] then error("duplicate legacy setting") end
            seen[key] = true
            result[key] = parse_value(depth + 1)
            whitespace()
            local delimiter = input:sub(position, position)
            if delimiter == "," or delimiter == ";" then position = position + 1; whitespace()
            elseif delimiter ~= "}" then error("invalid legacy table delimiter") end
        end
        position = position + 1
        return result
    end
    parse_value = function(depth)
        whitespace()
        local character = input:sub(position, position)
        if character == "{" then return parse_table(depth) end
        if character == '"' or character == "'" then return parse_string() end
        local tail = input:sub(position)
        local number = tail:match("^%-?%d+%.?%d*[eE][+%-]?%d+") or tail:match("^%-?%d+%.?%d*")
        if number then
            position = position + #number
            local value = tonumber(number)
            if not value or value ~= value or value == math.huge or value == -math.huge then error("invalid legacy number") end
            return value
        end
        local identifier = parse_identifier()
        if identifier == "true" then return true end
        if identifier == "false" then return false end
        if identifier == "nil" then return nil end
        error("unsupported legacy expression")
    end
    if input:sub(1, 3) == "-- " then
        local newline = input:find("\n", 4, true)
        if not newline then error("invalid legacy settings header") end
        position = newline + 1
    end
    whitespace()
    if input:sub(position, position + 5) ~= "return" or input:sub(position + 6, position + 6):match("[_%w]") then
        error("legacy settings must be a return literal")
    end
    position = position + 6
    local root = parse_value(0)
    whitespace()
    if position <= length or type(root) ~= "table" then error("trailing legacy settings content") end
    local settings
    for key, value in pairs(root) do
        if key ~= "legado_settings" or settings ~= nil then error("unknown legacy root key") end
        settings = value
    end
    if type(settings) ~= "table" then error("legacy settings table missing") end
    return settings
end

local function validate_settings(value)
    if type(value) ~= "table" then error("settings must be an object") end
    for key, child in pairs(value) do
        local expected = Settings.DEFAULTS[key]
        if key == "schema_version" then
            if child ~= Settings.SCHEMA_VERSION then error("unsupported settings schema") end
        elseif expected == nil or type(child) ~= type(expected) then error("unknown or invalid setting")
        elseif type(child) == "table" then error("settings values must be scalar") end
    end
    local function integer_range(key, low, high)
        local child = value[key]
        if child ~= nil and (child % 1 ~= 0 or child < low or child > high) then error("setting out of range") end
    end
    integer_range("prefetch", 0, 10); integer_range("concurrency", 2, 3)
    integer_range("shelf_page", 5, 50); integer_range("redirects", 0, 5)
    integer_range("pagination", 1, 20); integer_range("max_response_bytes", 1, 4 * 1024 * 1024)
    if value.timeout ~= nil and (value.timeout < 1 or value.timeout > 20) then error("setting out of range") end
    if value.max_concurrency ~= nil and value.max_concurrency ~= 3 then error("invalid settings bound") end
    if value.prefetch_min ~= nil and value.prefetch_min ~= 0 then error("invalid settings bound") end
    if value.prefetch_max ~= nil and value.prefetch_max ~= 10 then error("invalid settings bound") end
    if value.log_level ~= nil and not ({ debug = true, info = true, warn = true, error = true })[value.log_level] then
        error("invalid log level")
    end
    return value
end

local function missing(error_value)
    if type(error_value) ~= "table" then return false end
    local details = error_value.details
    if type(details) == "table" and details.reason == "missing" then return true end
    local cause = type(details) == "table" and details.cause or nil
    cause = type(cause) == "string" and cause:lower() or ""
    return cause:find("no such file", 1, true) ~= nil or cause:find("not found", 1, true) ~= nil
end

local function default_adapter(options)
    options = options or {}
    local data_dir = options.data_dir
    if not data_dir then
        local loaded, DataStorage = pcall(require, "datastorage")
        if loaded and DataStorage and type(DataStorage.getDataDir) == "function" then data_dir = DataStorage:getDataDir() end
    end
    if type(data_dir) ~= "string" or data_dir == "" then return nil end
    local fs = options.fs or Fs.new()
    local path = data_dir:gsub("[/\\]+$", "") .. "/settings/legado.json"
    local legacy_path = data_dir:gsub("[/\\]+$", "") .. "/settings/legado.lua"
    local adapter = { path = path, fs = fs }
    local function recovery_failure(raw, message)
        adapter.recovery_required = true
        adapter.canonical_bytes = raw
        error(message)
    end
    adapter.read = function()
            local ok, raw, read_error = pcall(fs.read, fs, path)
            if not ok then recovery_failure(nil, "settings read failed") end
            if raw then
                adapter.canonical_bytes = raw
                if #raw > MAX_SETTINGS_BYTES then recovery_failure(raw, "settings file too large") end
                local decoded_ok, envelope = pcall(Json.decode, raw)
                if not decoded_ok or type(envelope) ~= "table" or envelope.schema_version ~= Settings.SCHEMA_VERSION
                    or type(envelope.settings) ~= "table" then recovery_failure(raw, "invalid settings JSON") end
                for key in pairs(envelope) do
                    if key ~= "schema_version" and key ~= "settings" then recovery_failure(raw, "unknown settings envelope key") end
                end
                local valid, settings = pcall(validate_settings, envelope.settings)
                if not valid then recovery_failure(raw, "invalid settings values") end
                adapter.recovery_required, adapter.source = false, "canonical"
                return settings
            elseif not missing(read_error) then recovery_failure(nil, "settings read failed") end
            adapter.canonical_bytes = nil
            local legacy_ok, legacy, legacy_error = pcall(fs.read, fs, legacy_path)
            if not legacy_ok then error("legacy settings read failed") end
            if not legacy then
                if not missing(legacy_error) then error("legacy settings read failed") end
                adapter.recovery_required, adapter.source = false, "fresh"
                return {}
            end
            local parsed_ok, parsed = pcall(parse_legacy, legacy)
            if not parsed_ok then error("invalid legacy settings") end
            local valid, settings = pcall(validate_settings, parsed)
            if not valid then error("invalid legacy settings values") end
            adapter.recovery_required, adapter.source = false, "legacy"
            return settings
        end
    adapter.write = function(value)
        validate_settings(value)
        local encoded = Json.encode({ schema_version = Settings.SCHEMA_VERSION, settings = value })
        local written, write_error = fs:atomicWrite(path, encoded)
        if written then adapter.canonical_bytes, adapter.source = encoded, "canonical" end
        return written, write_error
    end
    adapter.backupAndReset = function(value)
        if not adapter.recovery_required or type(adapter.canonical_bytes) ~= "string" then
            return nil, Errors.new(Errors.RECOVERY_REQUIRED, "corrupt settings bytes are unavailable")
        end
        local backup_path
        for suffix = 1, 1000 do
            local candidate = path .. ".corrupt-" .. tostring(suffix)
            local read_ok, existing, read_error = pcall(fs.read, fs, candidate)
            if not read_ok then return nil, Errors.new(Errors.STORAGE_ERROR, "settings backup path cannot be checked") end
            if not existing then
                if not missing(read_error) then return nil, Errors.new(Errors.STORAGE_ERROR, "settings backup path cannot be checked") end
                backup_path = candidate
                break
            end
        end
        if not backup_path then return nil, Errors.new(Errors.STORAGE_ERROR, "settings backup name limit reached") end
        local backup_ok, backed = pcall(fs.atomicWrite, fs, backup_path, adapter.canonical_bytes)
        if not backup_ok or not backed then return nil, Errors.new(Errors.STORAGE_ERROR, "corrupt settings backup failed") end
        local encoded_ok, encoded = pcall(Json.encode, { schema_version = Settings.SCHEMA_VERSION, settings = value })
        if not encoded_ok then return nil, Errors.new(Errors.STORAGE_ERROR, "default settings encoding failed") end
        local write_ok, written = pcall(fs.atomicWrite, fs, path, encoded)
        if not write_ok or not written then return nil, Errors.new(Errors.STORAGE_ERROR, "settings reset publication failed") end
        adapter.canonical_bytes, adapter.recovery_required, adapter.source = encoded, false, "canonical"
        return backup_path
    end
    return adapter
end

function Settings.new(adapter, options)
    adapter = adapter or default_adapter(options) or { read = function() return {} end, write = function() return true end }
    local read_ok, stored = true, {}
    if adapter.read then read_ok, stored = pcall(adapter.read) end
    local values = copy(Settings.DEFAULTS)
    if read_ok and type(stored) == "table" then
        for key, value in pairs(stored) do values[key] = normalized(key, value) end
    end
    values.schema_version = Settings.SCHEMA_VERSION
    local self = setmetatable({ adapter = adapter, values = values, storage_path = adapter.path }, Settings)
    if not read_ok or type(stored) ~= "table" then
        self.recovery_required = adapter.recovery_required == true
        self.init_error = self.recovery_required
            and Errors.new(Errors.RECOVERY_REQUIRED, "settings file recovery is required")
            or Errors.new(Errors.STORAGE_ERROR, "settings could not be loaded")
        return self, self.init_error
    end
    local written, write_error = self:_write(values)
    if not written then self.init_error, self.initial_write_failed = write_error, true end
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
    if self.recovery_required then
        return nil, Errors.new(Errors.RECOVERY_REQUIRED, "ordinary settings save is locked until recovery")
    end
    local candidate = copy(self.values)
    candidate[key] = normalized(key, value)
    local written, err = self:_write(candidate)
    if not written then self.init_error, self.initial_write_failed = err, true; return nil, err end
    self.values, self.init_error, self.initial_write_failed = candidate, nil, false
    return candidate[key]
end

function Settings:retryRecovery()
    if not self.recovery_required then return true end
    local ok, stored = pcall(self.adapter.read)
    if not ok or type(stored) ~= "table" then
        self.recovery_required = true
        self.init_error = Errors.new(Errors.RECOVERY_REQUIRED, "settings file recovery is still required")
        return nil, self.init_error
    end
    local candidate = copy(Settings.DEFAULTS)
    for key, value in pairs(stored) do candidate[key] = normalized(key, value) end
    candidate.schema_version = Settings.SCHEMA_VERSION
    local written, write_error = self:_write(candidate)
    if not written then
        self.recovery_required = true
        self.init_error = write_error
        return nil, write_error
    end
    self.values, self.recovery_required, self.init_error, self.initial_write_failed = candidate, false, nil, false
    return true
end

function Settings:resetCorrupt()
    if not self.recovery_required or type(self.adapter.backupAndReset) ~= "function" then
        return nil, Errors.new(Errors.RECOVERY_REQUIRED, "settings reset is unavailable")
    end
    local candidate = copy(Settings.DEFAULTS)
    candidate.schema_version = Settings.SCHEMA_VERSION
    local ok, backup_path, reset_error = pcall(self.adapter.backupAndReset, candidate)
    if not ok or not backup_path then
        self.recovery_required = true
        self.init_error = type(reset_error) == "table" and reset_error
            or Errors.new(Errors.STORAGE_ERROR, "settings reset failed")
        return nil, self.init_error
    end
    self.values, self.recovery_required, self.init_error, self.initial_write_failed = candidate, false, nil, false
    return backup_path
end

function Settings:status()
    return {
        recovery_required = self.recovery_required == true,
        initial_write_failed = self.initial_write_failed == true,
        error = self.init_error,
        storage_path = self.storage_path,
    }
end

function Settings:all()
    return copy(self.values)
end

return Settings
