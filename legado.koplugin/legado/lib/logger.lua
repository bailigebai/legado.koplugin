local Logger = {}
local Instance = {}
Instance.__index = Instance

local function sensitive_key(key)
    local lower = tostring(key or ""):lower()
    return lower:find("cookie", 1, true)
        or lower:find("authorization", 1, true)
        or lower:find("password", 1, true)
        or lower:find("token", 1, true)
        or lower:find("api_key", 1, true)
        or lower:find("api-key", 1, true)
        or lower == "body"
        or (lower:find("chapter", 1, true) and lower:find("content", 1, true))
        or (lower:find("chapter", 1, true) and lower:find("body", 1, true))
        or lower == "content"
end

local function redact_query(value)
    value = value:gsub("^([%a][%w+.-]*://)([^/@]+)@", "%1[REDACTED]@")
    return value:gsub("([?&])([%w_%-]+)=([^&#]*)", function(prefix, key, ignored)
        local lower = key:lower()
        if lower:find("token", 1, true)
            or lower:find("password", 1, true)
            or lower:find("passwd", 1, true)
            or lower:find("secret", 1, true)
            or lower:find("authorization", 1, true)
            or lower == "auth"
            or lower == "api_key"
            or lower == "api-key"
            or lower == "apikey"
            or lower == "signature"
            or lower == "session" then
            return prefix .. key .. "=[REDACTED]"
        end
        return prefix .. key .. "=" .. ignored
    end)
end

local function redact(value, key, seen)
    if sensitive_key(key) then
        return "[REDACTED]"
    end
    if type(value) == "string" then
        return redact_query(value)
    end
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return "[REDACTED CYCLE]"
    end
    seen[value] = true
    local copy = {}
    for child_key, child_value in pairs(value) do
        copy[child_key] = redact(child_value, child_key, seen)
    end
    seen[value] = nil
    return copy
end

Logger.redact = function(value)
    return redact(value)
end

function Logger.new(options)
    options = options or {}
    return setmetatable({ sink = options.sink or function(level, value)
        if _G.print then
            print("[legado][" .. level .. "] " .. tostring(value))
        end
    end }, Instance)
end

function Instance:log(level, value)
    self.sink(level, redact(value))
end

function Instance:debug(value) self:log("debug", value) end
function Instance:info(value) self:log("info", value) end
function Instance:warn(value) self:log("warn", value) end
function Instance:error(value) self:log("error", value) end

local default_logger = Logger.new()
function Logger.debug(value) default_logger:debug(value) end
function Logger.info(value) default_logger:info(value) end
function Logger.warn(value) default_logger:warn(value) end
function Logger.error(value) default_logger:error(value) end

return Logger
