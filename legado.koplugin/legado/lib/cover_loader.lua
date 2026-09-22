local Errors = require("legado.lib.errors")
local Identity = require("legado.lib.identity")

local CoverLoader = {}
CoverLoader.__index = CoverLoader
CoverLoader.MAX_BYTES = 2 * 1024 * 1024

local function image_extension(bytes)
    if type(bytes) ~= 'string' or #bytes > CoverLoader.MAX_BYTES then return end
    if #bytes >= 24 and bytes:sub(1, 8) == '\137PNG\r\n\26\n' then return '.png' end
    if #bytes >= 4 and bytes:sub(1, 3) == '\255\216\255' and bytes:sub(-2) == '\255\217' then return '.jpg' end
    if #bytes >= 13 and (bytes:sub(1, 6) == 'GIF87a' or bytes:sub(1, 6) == 'GIF89a') then return '.gif' end
    if #bytes >= 12 and bytes:sub(1, 4) == 'RIFF' and bytes:sub(9, 12) == 'WEBP' then return '.webp' end
end

function CoverLoader.new(options)
    options = options or {}
    assert(options.request_engine, "CoverLoader requires request_engine")
    assert(options.fs and options.root, "CoverLoader requires filesystem root")
    options.fs:ensureDirectory(options.root)
    return setmetatable({ requests = options.request_engine, fs = options.fs, root = options.root, pending = {} }, CoverLoader)
end

function CoverLoader:load(book, callback)
    assert(type(callback) == "function", "cover callback is required")
    if type(book) ~= "table" or type(book.cover_url) ~= "string" or book.cover_url == "" then
        callback(nil, Errors.new(Errors.INVALID_INPUT, "book cover URL is missing"))
        return { cancel = function() return false end }
    end
    local stem = self.root .. "/cover-" .. Identity.hash(tostring(book.id or "") .. "\n" .. book.cover_url)
    if type(self.fs.readBounded) == "function" then
        for _, extension in ipairs({ ".jpg", ".png", ".webp", ".gif" }) do
            local bytes = self.fs:readBounded(stem .. extension, CoverLoader.MAX_BYTES)
            if image_extension(bytes) == extension then
                callback(stem .. extension, nil)
                return { cancel = function() return false end }
            end
        end
    end
    local flight = self.pending[stem]
    local waiter = { callback = callback, active = true }
    local function subscription()
        return { cancel = function()
            if not waiter.active or flight.done then return false end
            waiter.active = false
            for _, other in ipairs(flight.waiters) do if other.active then return true end end
            flight.done, self.pending[stem] = true, nil
            if flight.handle and flight.handle.cancel then pcall(flight.handle.cancel, flight.handle) end
            return true
        end }
    end
    if flight then flight.waiters[#flight.waiters + 1] = waiter; return subscription() end
    flight = { waiters = { waiter } }
    self.pending[stem] = flight
    local function finish(path, err)
        if flight.done then return end
        flight.done, self.pending[stem] = true, nil
        for _, other in ipairs(flight.waiters) do if other.active then pcall(other.callback, path, err) end end
    end
    local ok, handle, request_error = pcall(self.requests.execute, self.requests,
        { url = book.cover_url, source_id = book.source_id, max_bytes = CoverLoader.MAX_BYTES, binary = true }, function(response, err)
            if flight.done then return end
            if err then finish(nil, err); return end
            local bytes = response and response.body
            local extension = image_extension(bytes)
            if not extension then finish(nil, Errors.new(Errors.PARSE_ERROR, 'cover response is not a supported image')); return end
            local path = stem .. extension
            local write_ok, saved, save_error = pcall(self.fs.atomicWrite, self.fs, path, bytes)
            if not write_ok or not saved then
                finish(nil, type(save_error) == 'table' and save_error or Errors.new(Errors.STORAGE_ERROR, 'cover image could not be saved'))
            else finish(path, nil) end
        end)
    if not ok or not handle then finish(nil, request_error or Errors.new(Errors.NETWORK_ERROR, 'cover request did not start'))
    elseif not flight.done then flight.handle = handle end
    return subscription()
end

return CoverLoader
