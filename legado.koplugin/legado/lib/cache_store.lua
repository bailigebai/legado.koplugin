local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Identity = require("legado.lib.identity")
local Json = require("legado.lib.json_codec")

local CacheStore = {}
CacheStore.__index = CacheStore
CacheStore.VERSION = 1
CacheStore.MAX_BODY_BYTES = 4 * 1024 * 1024

local function safe_id(value)
    return type(value) == "string" and value:match("^[%w_-]+$") and value or nil
end

local function utf8(value)
    local index, length = 1, #value
    while index <= length do
        local byte = value:byte(index)
        local width = byte < 0x80 and 1 or (byte >= 0xC2 and byte <= 0xDF and 2 or (byte >= 0xE0 and byte <= 0xEF and 3 or (byte >= 0xF0 and byte <= 0xF4 and 4 or 0)))
        if width == 0 or index + width - 1 > length then return false end
        for offset = 2, width do if value:byte(index + offset - 1) < 0x80 or value:byte(index + offset - 1) > 0xBF then return false end end
        index = index + width
    end
    return true
end

local function encode(value)
    local value_type = type(value)
    if value_type == "nil" then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then return tostring(value) end
    if value_type == "string" then return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"' end
    local is_array, count = true, 0
    for key in pairs(value) do count = count + 1; if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then is_array = false end end
    if is_array then
        local chunks = {}; for index = 1, count do chunks[index] = encode(value[index]) end
        return "[" .. table.concat(chunks, ",") .. "]"
    end
    local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys)
    local chunks = {}; for _, key in ipairs(keys) do chunks[#chunks + 1] = encode(tostring(key)) .. ":" .. encode(value[key]) end
    return "{" .. table.concat(chunks, ",") .. "}"
end

function CacheStore.new(options)
    options = options or {}
    assert(type(options.root) == "string" and options.root ~= "", "CacheStore requires root")
    local self = setmetatable({ fs = options.fs or Fs.new(), root = options.root:gsub("[/\\]+$", ""), quarantine = options.quarantine ~= false }, CacheStore)
    self.fs:ensureDirectory(self.root)
    return self
end

function CacheStore:_path(source_id, book_id, kind, chapter)
    source_id, book_id = safe_id(source_id), safe_id(book_id)
    if not source_id or not book_id then return nil, Errors.new(Errors.INVALID_INPUT, "cache ids must be opaque path-safe identifiers") end
    local pieces = { source_id, book_id, kind }
    if chapter then
        local uid = safe_id(type(chapter) == "table" and chapter.uid or chapter)
        if not uid then return nil, Errors.new(Errors.INVALID_INPUT, "chapter uid must be an opaque path-safe identifier") end
        pieces[#pieces + 1] = uid
    end
    local path, err = self.fs:join(self.root, unpack(pieces))
    if not path then return nil, err end
    -- `join` rejects separators; this second check catches non-conforming FS adapters.
    local canonical_root = self.root:gsub("\\", "/") .. "/"
    if path:gsub("\\", "/"):sub(1, #canonical_root) ~= canonical_root then return nil, Errors.new(Errors.INVALID_INPUT, "cache path escapes root") end
    local lfs, ancestor = self.fs.lfs, self.root
    if lfs and type(lfs.symlinkattributes) == "function" then
        local info = lfs.symlinkattributes(ancestor)
        if info and info.mode == "link" then return nil, Errors.new(Errors.INVALID_INPUT, "cache root must not be a symlink") end
        for _, piece in ipairs(pieces) do
            ancestor = ancestor .. "/" .. piece
            info = lfs.symlinkattributes(ancestor)
            if info and info.mode == "link" then return nil, Errors.new(Errors.INVALID_INPUT, "cache path contains a symlink") end
        end
    end
    return path
end

function CacheStore:path(source_id, book_id, kind, chapter, extension)
    local base, err = self:_path(source_id, book_id, kind, chapter)
    if not base then return nil, err end
    if extension then base = base .. extension end
    return base
end

function CacheStore:_write(source_id, book_id, kind, chapter, value, extension)
    if type(value) ~= "string" or #value > self.MAX_BODY_BYTES then return nil, Errors.new(Errors.RESPONSE_TOO_LARGE, "invalid cache payload") end
    if kind ~= "cover" and not utf8(value) then return nil, Errors.new(Errors.ENCODING_ERROR, "cache payload is not UTF-8") end
    local path, err = self:path(source_id, book_id, kind, chapter, extension)
    if not path then return nil, err end
    local saved, save_error = self.fs:atomicWrite(path, value)
    if not saved then return nil, save_error end
    local manifest = encode({ version = self.VERSION, bytes = #value, checksum = Identity.hash(value) })
    saved, save_error = self.fs:atomicWrite(path .. ".meta", manifest)
    if not saved then return nil, save_error end
    return path
end

function CacheStore:_read(source_id, book_id, kind, chapter, extension)
    local path, err = self:path(source_id, book_id, kind, chapter, extension)
    if not path then return nil, err end
    local value, read_error = self.fs:readBounded(path, self.MAX_BODY_BYTES)
    if not value then return nil, read_error end
    local manifest = self.fs:readBounded(path .. ".meta", 4096)
    local decoded = nil
    if manifest then
        local decoded_ok, decoded_value = pcall(Json.decode, manifest)
        if decoded_ok then decoded = decoded_value end
    end
    if type(decoded) ~= "table" or decoded.version ~= self.VERSION or decoded.bytes ~= #value or decoded.checksum ~= Identity.hash(value) or (kind ~= "cover" and not utf8(value)) then
        if self.quarantine then self.fs:removeFile(path .. ".meta") end
        return nil, Errors.new(Errors.STORAGE_ERROR, "cache entry failed integrity validation", { path = path })
    end
    return value, path
end

function CacheStore:writeBody(source, book, chapter, value) return self:_write(source, book, "chapters", chapter, value, ".body") end
function CacheStore:readBody(source, book, chapter) return self:_read(source, book, "chapters", chapter, ".body") end
function CacheStore:writeHtml(source, book, chapter, value) return self:_write(source, book, "html", chapter, value, ".html") end
function CacheStore:readHtml(source, book, chapter) return self:_read(source, book, "html", chapter, ".html") end
function CacheStore:writeCover(source, book, value) return self:_write(source, book, "cover", nil, value, ".img") end
function CacheStore:readCover(source, book) return self:_read(source, book, "cover", nil, ".img") end
function CacheStore:writeCatalog(source, book, catalog) return self:_write(source, book, "catalog", nil, encode(catalog), ".json") end
function CacheStore:readCatalog(source, book)
    local value, err = self:_read(source, book, "catalog", nil, ".json")
    if not value then return nil, err end
    local decoded_ok, decoded = pcall(Json.decode, value)
    if not decoded_ok or type(decoded) ~= "table" then return nil, Errors.new(Errors.STORAGE_ERROR, "invalid cached catalog") end
    return decoded
end

return CacheStore
