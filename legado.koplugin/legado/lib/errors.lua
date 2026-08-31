local Errors = {
    INVALID_INPUT = "INVALID_INPUT",
    STORAGE_ERROR = "STORAGE_ERROR",
    MIGRATION_ERROR = "MIGRATION_ERROR",
    NETWORK_ERROR = "NETWORK_ERROR",
    TIMEOUT = "TIMEOUT",
    CANCELLED = "CANCELLED",
    RESPONSE_TOO_LARGE = "RESPONSE_TOO_LARGE",
    ENCODING_ERROR = "ENCODING_ERROR",
    PARSE_ERROR = "PARSE_ERROR",
    UNSUPPORTED_RULE = "UNSUPPORTED_RULE",
    SITE_REJECTED = "SITE_REJECTED",
}

local ErrorValue = {}
ErrorValue.__index = ErrorValue

function ErrorValue:__tostring()
    if self.message and self.message ~= "" then
        return self.code .. ": " .. self.message
    end
    return self.code
end

function Errors.new(code, message, details)
    return setmetatable({
        code = code or Errors.INVALID_INPUT,
        message = message or "",
        details = details,
    }, ErrorValue)
end

function Errors.is(value, code)
    return type(value) == "table" and value.code == code
end

return Errors
