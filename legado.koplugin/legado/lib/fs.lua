local Errors = require("legado.lib.errors")

local Fs = {}
Fs.__index = Fs

local function parent_directory(path)
    return path:match("^(.*)[/\\][^/\\]+$")
end

local function default_lfs()
    local loaded, lfs = pcall(require, "libs/libkoreader-lfs")
    if loaded then return lfs end
    loaded, lfs = pcall(require, "lfs")
    if loaded then return lfs end
    return nil
end

local function split(path)
    local parts = {}
    for item in path:gmatch("[^/\\]+") do parts[#parts + 1] = item end
    return parts
end

local function normalized_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    local prefix, rest = "", path
    if rest:sub(1, 2) == "//" then
        prefix, rest = "//", rest:sub(3)
    elseif rest:match("^%a:/") then
        prefix, rest = rest:sub(1, 2):lower() .. "/", rest:sub(4)
    elseif rest:sub(1, 1) == "/" then
        prefix, rest = "/", rest:sub(2)
    end
    local parts = {}
    for part in rest:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then table.remove(parts)
            elseif prefix == "" then parts[#parts + 1] = part end
        elseif part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    local joined = table.concat(parts, "/")
    if prefix == "//" then return "//" .. joined end
    if prefix ~= "" then return prefix .. joined end
    return joined
end

function Fs.new(options)
    options = options or {}
    return setmetatable({
        lfs = options.lfs or default_lfs(),
        rename = options.rename or os.rename,
        remove = options.remove or os.remove,
        open = options.open or io.open,
        canonicalize_fn = options.canonicalize,
        secure_temp_fn = options.secureTemp,
    }, Fs)
end

local function random_hex()
    local random = io.open("/dev/urandom", "rb")
    local bytes
    if random then bytes = random:read(16); random:close() end
    if (not bytes or #bytes ~= 16) and jit and jit.os == "Windows" then
        local ok, ffi = pcall(require, "ffi")
        if ok then
            pcall(ffi.cdef, "long BCryptGenRandom(void*, unsigned char*, unsigned long, unsigned long);")
            local loaded, bcrypt = pcall(ffi.load, "bcrypt")
            if loaded then
                local buffer = ffi.new("unsigned char[16]")
                if bcrypt.BCryptGenRandom(nil, buffer, 16, 2) == 0 then bytes = ffi.string(buffer, 16) end
            end
        end
    end
    if not bytes or #bytes ~= 16 then return nil end
    return (bytes:gsub(".", function(character) return string.format("%02x", character:byte()) end))
end

local function posix_exclusive(path)
    if not jit or jit.os == "Windows" then return nil, "not POSIX" end
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil, "LuaJIT FFI unavailable" end
    pcall(ffi.cdef, [[
        int open(const char *pathname, int flags, unsigned int mode);
        long write(int fd, const void *buf, unsigned long count);
        int fsync(int fd);
        int close(int fd);
    ]])
    local bit = require("bit")
    local fd = ffi.C.open(path, bit.bor(1, 64, 128, 131072, 524288), 384)
    if fd < 0 then return nil, "exclusive open failed" end
    local closed = false
    return {
        write = function(_, data)
            local offset = 0
            while offset < #data do
                local written = tonumber(ffi.C.write(fd, data:sub(offset + 1), #data - offset))
                if not written or written <= 0 then return nil, "secure write failed" end
                offset = offset + written
            end
            return true
        end,
        flush = function() return ffi.C.fsync(fd) == 0 or nil, "secure flush failed" end,
        close = function()
            if closed then return true end
            closed = true
            return ffi.C.close(fd) == 0 or nil, "secure close failed"
        end,
    }
end

function Fs:_secureTemporary(target, purpose, validate)
    if self.secure_temp_fn then
        local candidate, handle_or_error = self.secure_temp_fn(target, purpose, validate)
        local handle = handle_or_error
        if type(candidate) == "table" then handle, candidate = candidate.handle, candidate.path end
        if type(candidate) ~= "string" or (type(handle) ~= "table" and type(handle) ~= "userdata") then
            return nil, nil, Errors.new(Errors.STORAGE_ERROR, "secure temporary creation failed", { cause = handle_or_error })
        end
        if validate then
            local valid, validation_error = validate(candidate, "after_secure_" .. purpose)
            if not valid then pcall(handle.close, handle); self.remove(candidate); return nil, nil, validation_error end
        end
        return candidate, handle
    end
    for _ = 1, 16 do
        local nonce = random_hex()
        if not nonce then return nil, nil, Errors.new(Errors.STORAGE_ERROR, "cryptographic temporary naming unavailable") end
        local candidate = target .. "." .. purpose .. "-" .. nonce
        if validate then
            local valid, validation_error = validate(candidate, "before_secure_" .. purpose)
            if not valid then return nil, nil, validation_error end
        end
        local handle, open_error = posix_exclusive(candidate)
        if not handle and jit and jit.os == "Windows" then handle, open_error = self.open(candidate, "wbx") end
        if handle then return candidate, handle end
        if open_error ~= "exclusive open failed" then
            return nil, nil, Errors.new(Errors.STORAGE_ERROR, "exclusive temporary creation unsupported", { cause = open_error })
        end
    end
    return nil, nil, Errors.new(Errors.STORAGE_ERROR, "secure temporary collision limit reached")
end


function Fs:canonicalize(path)
    if self.canonicalize_fn then return self.canonicalize_fn(path) end
    return normalized_path(path)
end

function Fs:join(root, ...)
    if type(root) ~= "string" or root == "" then
        return nil, Errors.new(Errors.INVALID_INPUT, "missing storage root")
    end
    local pieces = { (root:gsub("[/\\]+$", "")) }
    for index = 1, select("#", ...) do
        local piece = select(index, ...)
        if type(piece) ~= "string" or piece == "" or piece:match("^[\\/]") or piece:match("^%a:[\\/]") then
            return nil, Errors.new(Errors.INVALID_INPUT, "unsafe path component")
        end
        for _, part in ipairs(split(piece)) do
            if part == "." or part == ".." then
                return nil, Errors.new(Errors.INVALID_INPUT, "unsafe path component")
            end
            pieces[#pieces + 1] = part
        end
    end
    return table.concat(pieces, "/")
end

function Fs:ensureDirectory(path)
    if not path or path == "" then return true end
    if self.lfs and self.lfs.attributes and self.lfs.attributes(path, "mode") == "directory" then return true end
    if not self.lfs or type(self.lfs.mkdir) ~= "function" then
        return true
    end
    local prefix = path:match("^%a:[/\\]") or path:match("^[/\\]") or ""
    local current
    if prefix == "/" or prefix == "\\" then current = "/" else current = prefix:gsub("[/\\]$", "") end
    for _, part in ipairs(split(path:sub(#prefix + 1))) do
        if current == "" then current = part
        elseif current == "/" then current = current .. part
        else current = current .. "/" .. part end
        if not (self.lfs.attributes and self.lfs.attributes(current, "mode") == "directory") then
            local ok, err = self.lfs.mkdir(current)
            if not ok and not (self.lfs.attributes and self.lfs.attributes(current, "mode") == "directory") then
                return nil, Errors.new(Errors.STORAGE_ERROR, "cannot create directory", { path = current, cause = err })
            end
        end
    end
    return true
end

function Fs:read(path)
    local handle, err = self.open(path, "rb")
    if not handle then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot read file", { path = path, cause = err }) end
    local data = handle:read("*a")
    handle:close()
    return data
end

function Fs:readBounded(path, max_bytes)
    local size, stat_error = self:size(path)
    if not size then return nil, stat_error end
    if size > max_bytes then
        return nil, Errors.new(Errors.RESPONSE_TOO_LARGE, "file exceeds limit", { path = path, max_bytes = max_bytes })
    end
    return self:read(path)
end

function Fs:atomicWrite(path, data, options)
    if type(data) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "atomic write accepts strings") end
    local parent = parent_directory(path)
    local ensured, ensure_error = self:ensureDirectory(parent)
    if not ensured then return nil, ensure_error end
    local validate = options and options.validate
    if validate then local valid, validation_error = validate(path, "before_write"); if not valid then return nil, validation_error end end
    local temporary, handle, open_error = self:_secureTemporary(path, "temp", validate)
    if not temporary then return nil, open_error end
    local written, write_error = handle:write(data)
    local flushed, flush_error = handle:flush()
    local closed, close_error = handle:close()
    if not written then
        self.remove(temporary)
        return nil, Errors.new(Errors.STORAGE_ERROR, "cannot write secure temporary", { cause = write_error })
    end
    if flushed == false or (flushed == nil and flush_error ~= nil) or closed == false or (closed == nil and close_error ~= nil) then
        self.remove(temporary)
        return nil, Errors.new(Errors.STORAGE_ERROR, "cannot finalize secure temporary", { cause = flush_error or close_error })
    end
    local old_content = self:read(path)
    local had_old = old_content ~= nil
    local backup
    if had_old then
        local backup_handle, backup_error
        backup, backup_handle, backup_error = self:_secureTemporary(path, "backup", validate)
        if not backup then self.remove(temporary); return nil, backup_error end
        local backup_written, backup_write_error = backup_handle:write(old_content)
        local backup_flushed, backup_flush_error = backup_handle:flush()
        local backup_closed, backup_close_error = backup_handle:close()
        if not backup_written or backup_flushed == false or (backup_flushed == nil and backup_flush_error ~= nil)
            or backup_closed == false or (backup_closed == nil and backup_close_error ~= nil) then
            self.remove(temporary); self.remove(backup)
            return nil, Errors.new(Errors.STORAGE_ERROR, "cannot preserve previous target", { cause = backup_write_error or backup_flush_error or backup_close_error })
        end
    end
    if validate then
        for _, candidate in ipairs({ path, temporary, backup }) do
            if candidate then local valid, validation_error = validate(candidate, "before_replace"); if not valid then self.remove(temporary); if backup then self.remove(backup) end; return nil, validation_error end end
        end
    end
    local renamed, rename_error = self.rename(temporary, path)
    if not renamed and had_old then
        -- Windows does not replace an existing destination.  Move the old
        -- target into our already-secured backup name; if that move fails the
        -- original target has not been touched.
        self.remove(backup)
        local moved_old, move_error = self.rename(path, backup)
        if moved_old then
            renamed, rename_error = self.rename(temporary, path)
            if not renamed then
                local restored, restore_error = self.rename(backup, path)
                self.remove(temporary)
                if not restored then return nil, Errors.new(Errors.STORAGE_ERROR, "replacement and recovery failed", { cause = rename_error, restore_cause = restore_error }) end
                return nil, Errors.new(Errors.STORAGE_ERROR, "cannot replace file", { cause = rename_error })
            end
        else
            self.remove(temporary)
            return nil, Errors.new(Errors.STORAGE_ERROR, "cannot prepare replacement", { cause = move_error or rename_error })
        end
    end
    if not renamed then
        self.remove(temporary)
        if backup then
            self.remove(path)
            local restored, restore_error = self.rename(backup, path)
            if not restored then return nil, Errors.new(Errors.STORAGE_ERROR, "replacement and recovery failed", { cause = rename_error, restore_cause = restore_error }) end
        end
        return nil, Errors.new(Errors.STORAGE_ERROR, "cannot replace file", { cause = rename_error })
    end
    local valid, validation_error = true
    if validate then valid, validation_error = validate(path, "after_replace") end
    if not valid then
        local removed, remove_error = self.remove(path)
        if backup then
            local restored, restore_error = self.rename(backup, path)
            if not restored then return nil, Errors.new(Errors.STORAGE_ERROR, "validation and recovery failed", { cause = tostring(validation_error), remove_cause = remove_error, restore_cause = restore_error }) end
        elseif not removed then
            return nil, Errors.new(Errors.STORAGE_ERROR, "validation and cleanup failed", { cause = tostring(validation_error), remove_cause = remove_error })
        end
        return nil, validation_error
    end
    if backup then self.remove(backup) end
    return true
end

function Fs:removeFile(path)
    local removed, err = self.remove(path)
    if removed or err == nil then return true end
    return nil, Errors.new(Errors.STORAGE_ERROR, "cannot remove file", { path = path, cause = err })
end

function Fs:size(path)
    if self.lfs and self.lfs.attributes then
        local attributes, err = self.lfs.attributes(path)
        if not attributes then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot stat file", { path = path, cause = err }) end
        return attributes.size
    end
    local handle, err = self.open(path, "rb")
    if not handle then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot stat file", { path = path, cause = err }) end
    local size = handle:seek("end")
    handle:close()
    return size
end

function Fs:stat(path)
    if self.lfs and self.lfs.attributes then
        local attributes, err = self.lfs.attributes(path)
        if not attributes then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot stat file", { path = path, cause = err }) end
        return attributes
    end
    local size, err = self:size(path)
    if not size then return nil, err end
    return { size = size, mode = "file" }
end

return Fs
