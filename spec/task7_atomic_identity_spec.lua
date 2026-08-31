local assertx = require("assertions")
local Fs = require("legado.lib.fs")
local CacheStore = require("legado.lib.cache_store")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function identity_fs(hook)
    local files, identities, serial = { ["root/target"] = "old", outside = "external" }, {}, 0
    local function set(path, value)
        serial = serial + 1; files[path], identities[path] = value, serial
    end
    identities["root/target"], identities.outside = 1, 2; serial = 2
    local fs = Fs.new({
        lfs = { attributes = function(path) return files[path] and { mode = "file", size = #files[path], dev = 1, ino = identities[path] } or nil end, mkdir = function() return true end },
        fileIdentity = function(path) return files[path] and { dev = 1, ino = identities[path] } or nil end,
        secureTemp = function(target, purpose)
            local path, buffer = target .. "." .. purpose .. "-identity", ""
            set(path, "")
            return path, { write = function(_, data) buffer = buffer .. data; files[path] = buffer; return true end, flush = function() return true end, close = function() return true end }
        end,
        open = function(path, mode)
            if mode ~= "rb" or files[path] == nil then return nil, "missing" end
            local value = files[path]
            return { read = function() return value end, close = function() end }
        end,
        rename = function(from, to)
            if hook then local handled, ok, err = hook("rename", from, to, files, identities, set); if handled then return ok, err end end
            files[to], identities[to], files[from], identities[from] = files[from], identities[from], nil, nil
            return true
        end,
        remove = function(path) files[path], identities[path] = nil, nil; return true end,
    })
    return fs, files, identities, set
end

-- An attacker swaps the exclusive temp for an ordinary file after path
-- validation.  The replacement must be rejected by recorded identity.
do
    local fs, files, _, set = identity_fs()
    local swapped = false
    local ok, err = fs:atomicWrite("root/target", "new", { validate = function(path, phase)
        if phase == "before_replace" and path:find("temp%-identity", 1) and not swapped then
            swapped = true; set(path, "attacker")
        end
        return true
    end })
    equal(nil, ok, "ordinary-file replacement of temp is rejected")
    truthy(err and err.code == "STORAGE_ERROR", "temp identity mismatch is structured")
    equal("old", files["root/target"], "temp identity attack leaves original target unchanged")
end

-- Cache writes bind the trusted cache root identity into the POSIX transaction;
-- a later string-path lookup cannot silently select a replacement root.
do
    local captured
    local fake = {
        lfs = { attributes = function() return { mode = "directory" } end },
        canonicalize = function(_, path) return path end,
        ensureDirectory = function() return true end,
        join = function(_, root, ...) return root .. "/" .. table.concat({ ... }, "/") end,
        identity = function(_, path) return path == "cache" and { dev = "7", ino = "9" } or nil end,
        atomicWrite = function(_, _, _, options) captured = options; return true end,
    }
    local cache = CacheStore.new({ fs = fake, root = "cache" })
    local chapter = { uid = "chapter", source_id = "source", book_id = "book", index = 1, url = "https://example/chapter", title = "Chapter" }
    truthy(cache:writeBody("source", "book", chapter, "body"), "cache write reaches atomic backend")
    equal("cache", captured and captured.root, "cache passes its trusted root")
    equal("7", captured and captured.root_identity and captured.root_identity.dev, "cache passes recorded root device")
    equal("9", captured and captured.root_identity and captured.root_identity.ino, "cache passes recorded root inode")
end

-- A directory-handle backend stays anchored when the string ancestor is
-- replaced.  This also proves the backend is actually selected when injected.
do
    local external = "external"
    local called = 0
    local fs = Fs.new({ atomicBackend = function(_, path, data, options)
        called = called + 1
        options.validate(path, "before_replace") -- swaps the visible ancestor in the simulated race
        -- Simulated open dirfd remains bound to the original directory.
        return true, "anchored:" .. data
    end })
    local visible = "original"
    local ok, marker = fs:atomicWrite("root/target", "new", { validate = function()
        visible = external
        return true
    end })
    truthy(ok, "injected directory-handle backend completes")
    equal("anchored:new", marker, "directory-handle backend result is preserved")
    equal(1, called, "atomic backend is invoked exactly once")
    equal("external", visible, "simulated visible ancestor changed without redirecting anchored backend")
end

-- Backup identity is checked again immediately before recovery.  A swapped
-- backup may never be restored over the original target.
do
    local backup_swapped = false
    local fs, files, _, set = identity_fs()
    local ok, err = fs:atomicWrite("root/target", "new", { validate = function(path, phase)
        if phase == "after_replace" then
            local backup = "root/target.backup-identity"
            set(backup, "attacker-backup")
            backup_swapped = true
            return nil, { code = "INVALID_INPUT", message = "force recovery" }
        end
        return true
    end })
    equal(nil, ok, "swapped backup prevents recovery success")
    truthy(err and err.code == "STORAGE_ERROR", "backup identity mismatch is structured")
    truthy(backup_swapped, "backup replacement race was exercised")
    equal("old", files["root/target"], "original content is rebuilt without publishing the swapped backup")
    equal("external", files.outside, "external sentinel is unchanged by backup recovery")
end

return count
