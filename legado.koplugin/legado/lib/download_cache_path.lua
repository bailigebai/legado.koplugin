local Errors = require("legado.lib.errors")

local Path = {}

function Path.resolve(value, default_root)
    if type(value) ~= "string" or type(default_root) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "cache directory must be a path")
    end
    if value == "" then value = default_root end
    if #value > 4096 or value:find("[%z\1-\31\127]") then
        return nil, Errors.new(Errors.INVALID_INPUT, "cache directory contains invalid characters")
    end
    value = value:gsub("\\", "/"):gsub("/+$", "")
    if value == "" or value:sub(1, 2) == "//"
        or not (value:sub(1, 1) == "/" or value:match("^%a:/")) then
        return nil, Errors.new(Errors.INVALID_INPUT, "cache directory must be an absolute local path")
    end
    for segment in value:gmatch("[^/]+") do
        if segment == ".." or segment == "." then
            return nil, Errors.new(Errors.INVALID_INPUT, "cache directory cannot contain traversal")
        end
    end
    if value == "/" or value:match("^%a:$") then
        return nil, Errors.new(Errors.INVALID_INPUT, "cache directory cannot be a filesystem root")
    end
    return value
end

return Path
