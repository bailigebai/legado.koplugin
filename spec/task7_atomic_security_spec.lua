local assertx = require("assertions")
local Fs = require("legado.lib.fs")
local CacheStore = require("legado.lib.cache_store")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local files, links, secure_names = { ["outside"] = "external-sentinel", ["root/target"] = "old" }, { ["root/target.tmp"] = "outside" }, {}
local function handle(path)
    path = links[path] or path
    local buffer = ""
    return {
        write = function(_, data) buffer = buffer .. data; files[path] = buffer; return true end,
        flush = function() return true end,
        close = function() return true end,
    }
end
local lfs = {
    attributes = function(path) return files[path] and { mode = "file", size = #files[path] } or nil end,
    symlinkattributes = function(path)
        if links[path] or path:find("backup%-link", 1) then return { mode = "link" } end
        return files[path] and { mode = "file", size = #files[path] } or nil
    end,
    mkdir = function() return true end,
}
local fs = Fs.new({ lfs = lfs,
    open = function(path, mode)
        if mode == "rb" then
            local resolved = links[path] or path
            if files[resolved] == nil then return nil, "missing" end
            local value = files[resolved]
            return { read = function() return value end, seek = function() return #value end, close = function() end }
        end
        return handle(path)
    end,
    rename = function(from, to)
        if files[from] == nil then return nil, "missing" end
        files[to], files[from] = files[from], nil
        return true
    end,
    remove = function(path) files[path] = nil; return true end,
    secureTemp = function(target, purpose)
        local candidate = target .. "." .. purpose .. "-nonce-" .. tostring(#secure_names + 1)
        secure_names[#secure_names + 1] = candidate
        if files[candidate] ~= nil then return nil, "collision" end
        return candidate, handle(candidate)
    end,
})

local saved = assert(fs:atomicWrite("root/target", "new", { validate = function(path)
    if path:find("backup%-link", 1) then return nil, { code = "INVALID_INPUT" } end
    return true
end }))
truthy(saved, "secure atomic replacement succeeds")
equal("external-sentinel", files.outside, "pre-positioned .tmp symlink cannot modify its external target")
equal("outside", links["root/target.tmp"], "pre-positioned .tmp symlink itself remains untouched")
truthy(#secure_names >= 2, "separate unpredictable temp and backup files are securely created")
truthy(secure_names[1] ~= "root/target.tmp", "temporary name is not the predictable legacy suffix")

files["root/target"] = "old-again"
local prior_count = #secure_names
fs.secure_temp_fn = function(target, purpose)
    local candidate = purpose == "backup" and target .. ".backup-link" or target .. ".temp-safe"
    secure_names[#secure_names + 1] = candidate
    return candidate, handle(candidate)
end
local rejected, reject_error = fs:atomicWrite("root/target", "attack", { validate = function(path)
    local info = lfs.symlinkattributes(path)
    if info and info.mode == "link" then return nil, { code = "INVALID_INPUT", message = "link" } end
    return true
end })
equal(nil, rejected, "linked backup candidate aborts replacement")
truthy(reject_error, "linked backup rejection is structured")
equal("old-again", files["root/target"], "linked backup attempt leaves old target unchanged")
equal("external-sentinel", files.outside, "linked backup attempt cannot touch pre-positioned tmp link target")
truthy(#secure_names > prior_count, "backup candidate was validated before use")

local ensure_calls = 0
local root_fs = {
    lfs = { symlinkattributes = function(path) return path == "linked-parent" and { mode = "link" } or nil end },
    canonicalize = function(_, path) return path end,
    ensureDirectory = function() ensure_calls = ensure_calls + 1; return true end,
}
local cache = CacheStore.new({ fs = root_fs, root = "linked-parent/cache" })
equal(0, ensure_calls, "CacheStore validates existing root ancestors before directory creation")
local path, path_error = cache:path("source", "book", "catalog")
equal(nil, path, "invalid cache root remains unusable")
equal("INVALID_INPUT", path_error.code, "invalid pre-existing root ancestor is structured")

return count
