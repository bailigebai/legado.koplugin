local Errors = require("legado.lib.errors")
local PortableJson = require("legado.lib.json_codec")
local Scanner = require("legado.lib.compatibility_scanner")

local SourceImporter = {}
SourceImporter.__index = SourceImporter
SourceImporter.DEFAULT_MAX_BYTES = 5 * 1024 * 1024

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("source data must not contain cycles") end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    seen[value] = nil
    return result
end

local function trim(value)
    if type(value) ~= "string" then return value end
    return value:match("^%s*(.-)%s*$")
end

local function decode(json, text)
    if type(json) == "function" then return json(text) end
    if type(json) == "table" and type(json.decode) == "function" then return json.decode(text) end
    error("invalid JSON decoder")
end

local function is_array(json, value)
    if type(json) == "table" and type(json.isArray) == "function" and json.isArray(value) then return true end
    if type(value) ~= "table" or next(value) == nil then return false end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    return count == #value
end

local function report_error(report, code, message, details)
    report.rejected = report.rejected + 1
    report.error = Errors.new(code, message, details)
    return report
end

local function warning_for_origin(origin)
    if type(origin) ~= "string" then return nil end
    if origin:lower():match("^http://") then
        return { code = "INSECURE_ORIGIN", message = "HTTP source imports are insecure", origin = origin }
    end
    return nil
end

function SourceImporter.validateRemoteUrl(url)
    if type(url) ~= "string" then return { valid = false, error = Errors.new(Errors.INVALID_INPUT, "remote import URL must be a string") } end
    local normalized = trim(url)
    local scheme = normalized:match("^([%a][%w+.-]*):")
    local lower_scheme = scheme and scheme:lower() or nil
    if lower_scheme == "https" and normalized:match("^[%a][%w+.-]*://[^/%s]+") then return { valid = true, url = normalized } end
    if lower_scheme == "http" and normalized:match("^[%a][%w+.-]*://[^/%s]+") then return { valid = true, url = normalized, warning = warning_for_origin(normalized) } end
    return { valid = false, error = Errors.new(Errors.INVALID_INPUT, "remote import URL must use HTTP or HTTPS", { url = url }) }
end

function SourceImporter:new(options)
    options = options or {}
    assert(options.storage, "SourceImporter requires storage")
    return setmetatable({
        storage = options.storage,
        json = options.json or PortableJson,
        max_bytes = options.max_bytes or SourceImporter.DEFAULT_MAX_BYTES,
        now = options.now or os.time,
    }, self)
end

function SourceImporter:_normalize(value, origin, origin_warning)
    if type(value) ~= "table" or is_array(self.json, value) then return nil, Errors.new(Errors.INVALID_INPUT, "source must be a JSON object") end
    local source = copy(value)
    source.bookSourceUrl = trim(source.bookSourceUrl)
    source.bookSourceName = trim(source.bookSourceName)
    if type(source.bookSourceUrl) ~= "string" or source.bookSourceUrl == "" then
        return nil, Errors.new(Errors.INVALID_INPUT, "source requires bookSourceUrl", { field = "bookSourceUrl" })
    end
    if type(source.bookSourceName) ~= "string" or source.bookSourceName == "" then
        return nil, Errors.new(Errors.INVALID_INPUT, "source requires bookSourceName", { field = "bookSourceName" })
    end
    source.id = source.bookSourceUrl
    source.bookSourceGroup = trim(source.bookSourceGroup or "")
    source.enabled = source.enabled ~= false
    for _, field in ipairs({ "header", "searchUrl", "ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent" }) do
        if source[field] == nil then source[field] = "" elseif type(source[field]) == "string" then source[field] = trim(source[field]) end
    end
    source.import_origin = origin
    source.imported_at = self.now()
    source.insecure_origin_warning = origin_warning and copy(origin_warning) or nil
    return source
end

function SourceImporter:importJson(text, origin)
    local report = { imported = 0, updated = 0, rejected = 0, compatibility = {}, warnings = {} }
    if type(text) ~= "string" then return report_error(report, Errors.INVALID_INPUT, "source JSON must be a string") end
    if #text > self.max_bytes then return report_error(report, Errors.RESPONSE_TOO_LARGE, "source JSON exceeds import limit", { max_bytes = self.max_bytes }) end

    local decoded_ok, decoded = pcall(decode, self.json, text)
    if not decoded_ok then return report_error(report, Errors.PARSE_ERROR, "invalid source JSON", { cause = decoded }) end
    if type(decoded) ~= "table" then return report_error(report, Errors.INVALID_INPUT, "source JSON must contain an object or array") end

    local sources = is_array(self.json, decoded) and decoded or { decoded }
    local origin_warning = warning_for_origin(origin)
    if origin_warning then report.warnings[#report.warnings + 1] = copy(origin_warning) end

    local existing = self.storage:listSources()
    if type(existing) ~= "table" then return report_error(report, Errors.STORAGE_ERROR, "storage cannot list sources") end
    local candidate, by_id = {}, {}
    for _, source in ipairs(existing) do
        local retained = copy(source)
        candidate[#candidate + 1] = retained
        by_id[retained.id or retained.bookSourceUrl] = retained
    end

    local prepared = {}
    for _, member in ipairs(sources) do
        local normalized, normalize_error = self:_normalize(member, origin, origin_warning)
        if not normalized then return report_error(report, normalize_error.code, normalize_error.message, normalize_error.details) end
        local prior = by_id[normalized.id]
        if prior then
            normalized.enabled = prior.enabled
            report.updated = report.updated + 1
            for index, saved in ipairs(candidate) do if saved.id == normalized.id then candidate[index] = normalized break end end
        else
            report.imported = report.imported + 1
            candidate[#candidate + 1] = normalized
        end
        by_id[normalized.id] = normalized
        local compatibility = Scanner.scan(normalized)
        compatibility.source_id = normalized.id
        prepared[#prepared + 1] = compatibility
    end

    local saved, save_error = self.storage:replaceSources(candidate)
    if not saved then
        report.imported, report.updated = 0, 0
        report.error = save_error or Errors.new(Errors.STORAGE_ERROR, "source import was not committed")
        return report
    end
    report.compatibility = prepared
    return report
end

return SourceImporter
