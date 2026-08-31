local Errors = require("legado.lib.errors")
local Identity = require("legado.lib.identity")

local CoverLoader = {}
CoverLoader.__index = CoverLoader
CoverLoader.MAX_BYTES = 2 * 1024 * 1024

local function header(headers, wanted)
    for name, value in pairs(headers or {}) do if tostring(name):lower() == wanted then return tostring(value):lower() end end
end

function CoverLoader.new(options)
    options = options or {}
    assert(options.request_engine, "CoverLoader requires request_engine")
    assert(options.fs and options.root, "CoverLoader requires filesystem root")
    options.fs:ensureDirectory(options.root)
    return setmetatable({ requests = options.request_engine, fs = options.fs, root = options.root }, CoverLoader)
end

function CoverLoader:load(book, callback)
    assert(type(callback) == "function", "cover callback is required")
    if type(book) ~= "table" or type(book.cover_url) ~= "string" or book.cover_url == "" then
        callback(nil, Errors.new(Errors.INVALID_INPUT, "book cover URL is missing"))
        return { cancel = function() return false end }
    end
    return self.requests:execute({ url = book.cover_url, source_id = book.source_id, max_bytes = CoverLoader.MAX_BYTES }, function(response, err)
        if err then callback(nil, err); return end
        local content_type = header(response.headers, "content-type") or ""
        local extension = content_type:find("png", 1, true) and ".png"
            or content_type:find("webp", 1, true) and ".webp"
            or content_type:find("gif", 1, true) and ".gif" or ".jpg"
        if type(response.body) ~= "string" or response.body == "" then callback(nil, Errors.new(Errors.PARSE_ERROR, "cover response is empty")); return end
        local path = self.root .. "/cover-" .. Identity.hash(tostring(book.id or "") .. "\n" .. book.cover_url) .. extension
        local saved, save_error = self.fs:atomicWrite(path, response.body)
        if not saved then callback(nil, save_error); return end
        callback(path, nil)
    end)
end

return CoverLoader
