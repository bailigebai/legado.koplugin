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
        atomic_backend_fn = options.atomicBackend,
        file_identity_fn = options.fileIdentity,
    }, Fs)
end

function Fs:_identity(path)
    local attributes
    if self.file_identity_fn then attributes = self.file_identity_fn(path)
    elseif self.lfs and type(self.lfs.symlinkattributes) == "function" then attributes = self.lfs.symlinkattributes(path)
    elseif self.lfs and type(self.lfs.attributes) == "function" then attributes = self.lfs.attributes(path) end
    if not attributes or attributes.dev == nil or attributes.ino == nil then return nil end
    return { dev = tostring(attributes.dev), ino = tostring(attributes.ino) }
end

function Fs:identity(path)
    return self:_identity(path)
end

local function same_identity(expected, actual)
    return expected == nil or (actual and expected.dev == actual.dev and expected.ino == actual.ino)
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

local function posix_dirfd_atomic(self, path, data, options)
    if not jit or jit.os == "Windows" then return nil, nil end
    local ok, ffi = pcall(require, "ffi")
    if not ok or not self.lfs or type(self.lfs.attributes) ~= "function" then
        return true, nil, Errors.new(Errors.STORAGE_ERROR, "directory-handle atomic backend unavailable")
    end
    pcall(ffi.cdef, [[
        int open(const char *pathname, int flags, unsigned int mode);
        int openat(int dirfd, const char *pathname, int flags, unsigned int mode);
        int mkdirat(int dirfd, const char *pathname, unsigned int mode);
        int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);
        int unlinkat(int dirfd, const char *pathname, int flags);
        long read(int fd, void *buf, unsigned long count);
        long write(int fd, const void *buf, unsigned long count);
        int fsync(int fd);
        int close(int fd);
    ]])
    local bit = require("bit")
    local O_RDONLY, O_WRONLY, O_CREAT, O_EXCL = 0, 1, 64, 128
    local O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC = 65536, 131072, 524288
    local directory_flags = bit.bor(O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_CLOEXEC)
    local read_flags = bit.bor(O_RDONLY, O_NOFOLLOW, O_CLOEXEC)
    local create_flags = bit.bor(O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_CLOEXEC)
    local opened, names = {}, {}
    local parent_fd
    local function remember(fd) if fd and fd >= 0 then opened[tonumber(fd)] = true end return fd end
    local function close_fd(fd)
        if not fd or fd < 0 then return end
        ffi.C.close(fd)
        opened[tonumber(fd)] = nil
    end
    local function cleanup()
        if parent_fd then for name in pairs(names) do ffi.C.unlinkat(parent_fd, name, 0) end end
        for fd in pairs(opened) do ffi.C.close(fd) end
        opened, names = {}, {}
    end
    local function failure(message, details) cleanup(); return true, nil, Errors.new(Errors.STORAGE_ERROR, message, details) end
    local function fd_identity(fd)
        local attributes = self.lfs.attributes("/proc/self/fd/" .. tostring(fd))
        if not attributes or attributes.dev == nil or attributes.ino == nil then return nil end
        return { dev = tostring(attributes.dev), ino = tostring(attributes.ino) }
    end
    local function retry(call)
        while true do local result = call(); if result >= 0 or ffi.errno() ~= 4 then return result end end
    end
    local function write_all(fd, value)
        local offset = 0
        while offset < #value do
            local written = tonumber(retry(function() return ffi.C.write(fd, value:sub(offset + 1), #value - offset) end))
            if not written or written <= 0 then return nil end
            offset = offset + written
        end
        return retry(function() return ffi.C.fsync(fd) end) == 0
    end
    local function read_all(fd)
        local chunks, buffer = {}, ffi.new("unsigned char[65536]")
        while true do
            local amount = tonumber(retry(function() return ffi.C.read(fd, buffer, 65536) end))
            if not amount or amount < 0 then return nil end
            if amount == 0 then return table.concat(chunks) end
            chunks[#chunks + 1] = ffi.string(buffer, amount)
        end
    end
    local validate = options.validate
    if validate then local valid, err = validate(path, "before_write"); if not valid then return true, nil, err end end
    local parent = parent_directory(path) or "."
    local root = options.root or parent
    local canonical_root, canonical_parent = self:canonicalize(root), self:canonicalize(parent)
    if type(canonical_root) ~= "string" or type(canonical_parent) ~= "string" then
        return true, nil, Errors.new(Errors.STORAGE_ERROR, "atomic paths cannot be canonicalized")
    end
    canonical_root, canonical_parent = canonical_root:gsub("\\", "/"), canonical_parent:gsub("\\", "/")
    if canonical_root == "" then canonical_root = "." end
    if canonical_parent == "" then canonical_parent = "." end
    if canonical_root ~= "/" then canonical_root = canonical_root:gsub("/+$", "") end
    if canonical_parent ~= "/" then canonical_parent = canonical_parent:gsub("/+$", "") end
    local relative_parent
    if canonical_parent == canonical_root then
        relative_parent = ""
    elseif canonical_root == "/" and canonical_parent:sub(1, 1) == "/" then
        relative_parent = canonical_parent:sub(2)
    elseif canonical_root == "." and canonical_parent:sub(1, 1) ~= "/" then
        relative_parent = canonical_parent
    elseif canonical_parent:sub(1, #canonical_root + 1) == canonical_root .. "/" then
        relative_parent = canonical_parent:sub(#canonical_root + 2)
    else
        return true, nil, Errors.new(Errors.STORAGE_ERROR, "atomic target escapes directory-handle root")
    end
    local function components(value)
        local output = {}
        for component in value:gmatch("[^/]+") do
            if component ~= "." then
                if component == ".." then return nil end
                output[#output + 1] = component
            end
        end
        return output
    end
    local absolute = canonical_root:sub(1, 1) == "/"
    local root_components = components(absolute and canonical_root:sub(2) or canonical_root)
    local parent_components = components(relative_parent)
    if not root_components or not parent_components then
        return true, nil, Errors.new(Errors.STORAGE_ERROR, "unsafe atomic directory component")
    end
    local root_fd = remember(ffi.C.open(absolute and "/" or ".", directory_flags, 0))
    if root_fd < 0 then return failure("cannot open atomic anchor directory") end
    local function descend(fd, component)
        local next_fd = retry(function() return ffi.C.openat(fd, component, directory_flags, 0) end)
        if next_fd < 0 then
            ffi.C.mkdirat(fd, component, 448)
            next_fd = retry(function() return ffi.C.openat(fd, component, directory_flags, 0) end)
        end
        return remember(next_fd)
    end
    for _, component in ipairs(root_components) do
        local next_fd = descend(root_fd, component)
        if next_fd < 0 then return failure("cannot open atomic root component") end
        close_fd(root_fd); root_fd = next_fd
    end
    local root_identity = fd_identity(root_fd)
    if not root_identity or (options.root_identity and not same_identity(options.root_identity, root_identity)) then
        return failure("atomic root directory identity mismatch")
    end
    parent_fd = root_fd
    for _, component in ipairs(parent_components) do
        local next_fd = descend(parent_fd, component)
        if next_fd < 0 then return failure("cannot open atomic parent component") end
        close_fd(parent_fd)
        parent_fd = next_fd
    end
    local target_name = path:gsub("\\", "/"):match("([^/]+)$")
    if not target_name or target_name == "." or target_name == ".." then return failure("invalid atomic target name") end
    local function create_name(purpose)
        for _ = 1, 16 do
            local nonce = random_hex(); if not nonce then return nil end
            local name = "." .. purpose .. "-" .. nonce
            local fd = retry(function() return ffi.C.openat(parent_fd, name, create_flags, 384) end)
            if fd >= 0 then names[name] = true; return name, remember(fd), fd_identity(fd) end
        end
    end
    local temp_name, temp_fd, temp_identity = create_name("temp")
    if not temp_name or not temp_identity or not write_all(temp_fd, data) then return failure("cannot create bound atomic temporary") end
    local target_fd = retry(function() return ffi.C.openat(parent_fd, target_name, read_flags, 0) end)
    local had_old, old_content = target_fd >= 0, nil
    if had_old then
        remember(target_fd); old_content = read_all(target_fd); close_fd(target_fd)
        if not old_content then return failure("cannot read previous atomic target") end
    end
    local backup_name, backup_fd, backup_identity
    if had_old then
        backup_name, backup_fd, backup_identity = create_name("backup")
        if not backup_name or not backup_identity or not write_all(backup_fd, old_content) then return failure("cannot create bound atomic backup") end
    end
    local function restore_previous()
        if not had_old then
            if ffi.C.unlinkat(parent_fd, target_name, 0) ~= 0 then return nil, "cannot remove rejected target" end
            return true
        end
        if backup_name then
            local check_backup = retry(function() return ffi.C.openat(parent_fd, backup_name, read_flags, 0) end)
            if check_backup >= 0 then
                remember(check_backup)
                local matches = same_identity(backup_identity, fd_identity(check_backup))
                close_fd(check_backup)
                if matches and retry(function() return ffi.C.renameat(parent_fd, backup_name, parent_fd, target_name) end) == 0 then
                    names[backup_name] = nil
                    local restored_fd = retry(function() return ffi.C.openat(parent_fd, target_name, read_flags, 0) end)
                    if restored_fd >= 0 then
                        remember(restored_fd)
                        local restored = same_identity(backup_identity, fd_identity(restored_fd))
                        close_fd(restored_fd)
                        if restored then return true end
                    end
                    ffi.C.unlinkat(parent_fd, target_name, 0)
                end
            end
        end
        local recovery_name, recovery_fd, recovery_identity = create_name("recovery")
        if not recovery_name or not recovery_identity or not write_all(recovery_fd, old_content) then return nil, "cannot create bound recovery" end
        local check_recovery = retry(function() return ffi.C.openat(parent_fd, recovery_name, read_flags, 0) end)
        if check_recovery < 0 then return nil, "atomic recovery unavailable before rename" end
        remember(check_recovery)
        local matches = same_identity(recovery_identity, fd_identity(check_recovery))
        close_fd(check_recovery)
        if not matches then return nil, "atomic recovery identity changed" end
        if retry(function() return ffi.C.renameat(parent_fd, recovery_name, parent_fd, target_name) end) ~= 0 then return nil, "atomic recovery rename failed" end
        names[recovery_name] = nil
        local restored_fd = retry(function() return ffi.C.openat(parent_fd, target_name, read_flags, 0) end)
        if restored_fd < 0 then return nil, "restored atomic target unavailable" end
        remember(restored_fd)
        local restored = same_identity(recovery_identity, fd_identity(restored_fd))
        close_fd(restored_fd)
        if not restored then ffi.C.unlinkat(parent_fd, target_name, 0); return nil, "restored atomic target identity mismatch" end
        return true
    end
    if validate then
        local valid, err = validate(path, "before_replace")
        if not valid then cleanup(); return true, nil, err end
    end
    local check_temp = retry(function() return ffi.C.openat(parent_fd, temp_name, read_flags, 0) end)
    if check_temp < 0 then return failure("atomic temporary disappeared before rename") end
    remember(check_temp)
    if not same_identity(temp_identity, fd_identity(check_temp)) then return failure("atomic temporary identity changed") end
    close_fd(check_temp)
    if retry(function() return ffi.C.renameat(parent_fd, temp_name, parent_fd, target_name) end) ~= 0 then return failure("directory-handle rename failed") end
    names[temp_name] = nil
    local published_fd = retry(function() return ffi.C.openat(parent_fd, target_name, read_flags, 0) end)
    if published_fd < 0 then
        local restored, restore_error = restore_previous()
        if not restored then return failure("published target unavailable and recovery failed", { restore_cause = restore_error }) end
        return failure("published atomic target unavailable")
    end
    remember(published_fd)
    if not same_identity(temp_identity, fd_identity(published_fd)) then
        close_fd(published_fd)
        local restored, restore_error = restore_previous()
        if not restored then return failure("published identity mismatch and recovery failed", { restore_cause = restore_error }) end
        return failure("published atomic target identity mismatch")
    end
    close_fd(published_fd)
    retry(function() return ffi.C.fsync(parent_fd) end)
    local valid, validation_error = true
    if validate then valid, validation_error = validate(path, "after_replace") end
    if not valid then
        local restored, restore_error = restore_previous()
        retry(function() return ffi.C.fsync(parent_fd) end)
        if not restored then return failure("validation and recovery failed", { cause = tostring(validation_error), restore_cause = restore_error }) end
        cleanup()
        return true, nil, validation_error
    end
    if backup_name then ffi.C.unlinkat(parent_fd, backup_name, 0); names[backup_name] = nil end
    retry(function() return ffi.C.fsync(parent_fd) end)
    cleanup()
    return true, true
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
    options = options or {}
    if self.atomic_backend_fn then return self.atomic_backend_fn(self, path, data, options) end
    local handled, result, backend_error = posix_dirfd_atomic(self, path, data, options)
    if handled then return result, backend_error end
    local parent = parent_directory(path)
    local ensured, ensure_error = self:ensureDirectory(parent)
    if not ensured then return nil, ensure_error end
    local validate = options.validate
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
    local temporary_identity = self:_identity(temporary)
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
    local backup_identity = backup and self:_identity(backup) or nil
    if validate then
        for _, candidate in ipairs({ path, temporary, backup }) do
            if candidate then local valid, validation_error = validate(candidate, "before_replace"); if not valid then self.remove(temporary); if backup then self.remove(backup) end; return nil, validation_error end end
        end
    end
    if not same_identity(temporary_identity, self:_identity(temporary)) then
        self.remove(temporary); if backup then self.remove(backup) end
        return nil, Errors.new(Errors.STORAGE_ERROR, "secure temporary identity changed")
    end
    if backup and not same_identity(backup_identity, self:_identity(backup)) then
        self.remove(temporary)
        return nil, Errors.new(Errors.STORAGE_ERROR, "secure backup identity changed")
    end
    local renamed, rename_error = self.rename(temporary, path)
    if not renamed and had_old then
        -- Windows does not replace an existing destination.  Move the old
        -- target into our already-secured backup name; if that move fails the
        -- original target has not been touched.
        self.remove(backup)
        local moved_old, move_error = self.rename(path, backup)
        if moved_old then
            backup_identity = self:_identity(backup)
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
    if not same_identity(temporary_identity, self:_identity(path)) then
        self.remove(path)
        if backup and same_identity(backup_identity, self:_identity(backup)) then self.rename(backup, path) end
        return nil, Errors.new(Errors.STORAGE_ERROR, "published target identity mismatch")
    end
    local valid, validation_error = true
    if validate then valid, validation_error = validate(path, "after_replace") end
    if not valid then
        local removed, remove_error = self.remove(path)
        if backup then
            if not same_identity(backup_identity, self:_identity(backup)) then
                self.remove(backup)
                local recovery, recovery_handle, recovery_error = self:_secureTemporary(path, "recovery", validate)
                if recovery then
                    local recovery_written, recovery_write_error = recovery_handle:write(old_content)
                    local recovery_flushed, recovery_flush_error = recovery_handle:flush()
                    local recovery_closed, recovery_close_error = recovery_handle:close()
                    local recovery_identity = self:_identity(recovery)
                    if recovery_written and recovery_flushed ~= false and not (recovery_flushed == nil and recovery_flush_error ~= nil)
                        and recovery_closed ~= false and not (recovery_closed == nil and recovery_close_error ~= nil)
                        and same_identity(recovery_identity, self:_identity(recovery)) then
                        local restored, restore_error = self.rename(recovery, path)
                        if restored and same_identity(recovery_identity, self:_identity(path)) then
                            return nil, Errors.new(Errors.STORAGE_ERROR, "secure backup identity changed before recovery", { cause = tostring(validation_error) })
                        end
                        recovery_error = restore_error or "recovered target identity mismatch"
                    else
                        recovery_error = recovery_write_error or recovery_flush_error or recovery_close_error or "recovery identity mismatch"
                    end
                    self.remove(recovery)
                end
                return nil, Errors.new(Errors.STORAGE_ERROR, "backup replacement and recovery failed", { cause = tostring(validation_error), restore_cause = recovery_error })
            end
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
