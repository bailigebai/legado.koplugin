local assertx = require("assertions")
local Fs = require("legado.lib.fs")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

-- Linux ARM EABI assigns O_DIRECTORY/O_NOFOLLOW lower bits than asm-generic.
do
    truthy(type(Fs.posixFlags) == "function", "POSIX flag selection is independently testable")
    local arm = Fs.posixFlags("arm")
    equal(16384, arm.O_DIRECTORY, "ARM EABI O_DIRECTORY matches asm/fcntl.h")
    equal(32768, arm.O_NOFOLLOW, "ARM EABI O_NOFOLLOW matches asm/fcntl.h")
    local generic = Fs.posixFlags("x64")
    equal(65536, generic.O_DIRECTORY, "x86 uses asm-generic O_DIRECTORY")
    equal(131072, generic.O_NOFOLLOW, "x86 uses asm-generic O_NOFOLLOW")
end

local bit = require("bit")
local function posix_fake(initial, behavior)
    behavior = behavior or {}
    local state = { files = {}, dirs = { [""] = true, root = true }, fds = {}, next_fd = 9, next_ino = 100,
        errno_value = 0, directory_flags = {}, fsync_dir_calls = 0, backup_unlink_calls = 0, close_calls = 0,
        close_by_fd = {} }
    local function inode(content)
        state.next_ino = state.next_ino + 1
        return { ino = state.next_ino, content = content or "" }
    end
    for path, content in pairs(initial or {}) do state.files[path] = inode(content) end
    local function alloc(value) state.next_fd = state.next_fd + 1; state.fds[state.next_fd] = value; return state.next_fd end
    local function fail(errno) state.errno_value = errno; return -1 end
    local function child(fd, name)
        local directory = state.fds[fd]
        if not directory or directory.kind ~= "dir" then return nil end
        return directory.path == "" and name or directory.path .. "/" .. name
    end
    local sys = { arch = "arm", state = state }
    function sys:errno() return state.errno_value end
    function sys:open(path, flags)
        state.directory_flags[#state.directory_flags + 1] = flags
        if path ~= "." and path ~= "/" then return fail(2) end
        return alloc({ kind = "dir", path = "" })
    end
    function sys:openat(fd, name, flags)
        local path = child(fd, name); if not path then return fail(9) end
        if bit.band(flags, 16384) ~= 0 or bit.band(flags, 65536) ~= 0 then
            state.directory_flags[#state.directory_flags + 1] = flags
            if not state.dirs[path] then return fail(2) end
            return alloc({ kind = "dir", path = path })
        end
        if bit.band(flags, 64) ~= 0 then
            if state.files[path] then return fail(17) end
            state.files[path] = inode("")
        end
        local file = state.files[path]; if not file then return fail(2) end
        return alloc({ kind = "file", file = file, path = path, offset = 1 })
    end
    function sys:mkdirat(fd, name)
        local path = child(fd, name); if not path then return fail(9) end
        if state.dirs[path] then return fail(17) end
        state.dirs[path] = true; return 0
    end
    function sys:write(fd, value)
        local item = state.fds[fd]; if not item or item.kind ~= "file" then return fail(9) end
        item.file.content = item.file.content .. value; return #value
    end
    function sys:read(fd, maximum)
        local item = state.fds[fd]; if not item or item.kind ~= "file" then return fail(9) end
        local value = item.file.content:sub(item.offset, item.offset + maximum - 1)
        item.offset = item.offset + #value
        return value
    end
    function sys:identity(fd)
        local item = state.fds[fd]; if not item then return nil end
        return { dev = "1", ino = tostring(item.kind == "file" and item.file.ino or (item.path == "" and 1 or 2)) }
    end
    function sys:size(fd)
        local item = state.fds[fd]
        return item and item.kind == "file" and #item.file.content or nil
    end
    function sys:renameat(oldfd, oldname, newfd, newname)
        local oldpath, newpath = child(oldfd, oldname), child(newfd, newname)
        if not oldpath or not newpath or not state.files[oldpath] then return fail(2) end
        state.files[newpath], state.files[oldpath] = state.files[oldpath], nil; return 0
    end
    function sys:unlinkat(fd, name)
        local path = child(fd, name); if not path then return fail(9) end
        if name:find("^.backup%-") then
            state.backup_unlink_calls = state.backup_unlink_calls + 1
            if behavior.backup_unlink_eintr_once and state.backup_unlink_calls == 1 then return fail(4) end
            if behavior.backup_unlink_permanent then return fail(5) end
        end
        if not state.files[path] then return fail(2) end
        state.files[path] = nil; return 0
    end
    function sys:fsync(fd)
        local item = state.fds[fd]; if not item then return fail(9) end
        if item.kind == "dir" then
            state.fsync_dir_calls = state.fsync_dir_calls + 1
            if behavior.fsync_dir_eintr_once and state.fsync_dir_calls == 1 then return fail(4) end
            if behavior.fsync_dir_permanent or behavior.fsync_dir_fail_on == state.fsync_dir_calls then return fail(5) end
        end
        return 0
    end
    function sys:close(fd)
        state.close_calls = state.close_calls + 1
        state.close_by_fd[fd] = (state.close_by_fd[fd] or 0) + 1
        local item = state.fds[fd]
        if item and behavior.close_eio_path and item.path == behavior.close_eio_path then
            state.close_eio_matches = (state.close_eio_matches or 0) + 1
            if state.close_eio_matches == (behavior.close_eio_occurrence or 1) then
                state.fds[fd] = nil
                return fail(5)
            end
        end
        if item and behavior.close_eio_pattern and tostring(item.path):find(behavior.close_eio_pattern) then
            state.fds[fd] = nil
            return fail(5)
        end
        if behavior.close_eintr_reuse_once and not state.reused_fd then
            if not state.fds[fd] then return fail(9) end
            state.reused_fd = fd
            state.fds[fd] = { kind = "sentinel", label = "reused-after-close" }
            return fail(4)
        end
        if behavior.close_eintr_once and state.close_calls == 1 then return fail(4) end
        if not state.fds[fd] then return fail(9) end
        state.fds[fd] = nil; return 0
    end
    return sys, state
end

local function injected_fs(sys)
    return Fs.new({
        posixSyscalls = sys,
        posixArch = sys.arch,
        lfs = { attributes = function() return { dev = 1, ino = 1 } end },
    })
end

-- Non-EINTR close failures are transaction failures. Before commit they abort;
-- after commit they roll back while the backup is still retained.
do
    local pre_sys, pre_state = posix_fake({ ["root/target"] = "old" }, { close_eio_pattern = ".temp-" })
    local saved, err = injected_fs(pre_sys):atomicWrite("root/target", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    equal(nil, saved, "pre-commit close EIO aborts publication")
    equal("STORAGE_ERROR", err and err.code, "pre-commit close EIO is structured")
    equal("old", pre_state.files["root/target"] and pre_state.files["root/target"].content, "pre-commit close EIO preserves old bytes")
    equal(nil, next(pre_state.fds), "pre-commit close EIO leaves no tracked descriptors")

    local post_sys, post_state = posix_fake({ ["root/target"] = "old" }, {
        close_eio_path = "root/target", close_eio_occurrence = 2,
    })
    local replaced, replace_error = injected_fs(post_sys):atomicWrite("root/target", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    equal(nil, replaced, "post-commit close EIO is not reported as success")
    equal("STORAGE_ERROR", replace_error and replace_error.code, "post-commit close EIO is structured")
    equal("old", post_state.files["root/target"] and post_state.files["root/target"].content, "post-commit close EIO restores old bytes")
    equal(nil, next(post_state.fds), "post-commit close EIO leaves no tracked descriptors")

    local dir_sys, dir_state = posix_fake({ ["root/target"] = "old" }, { close_eio_path = "root" })
    local committed, diagnostic = injected_fs(dir_sys):atomicWrite("root/target", "new", {
        root = "root", root_identity = { dev = "1", ino = "2" },
    })
    truthy(committed, "final parent close EIO reports the already-published state truthfully")
    equal("STORAGE_ERROR", diagnostic and diagnostic.code, "final parent close EIO returns a structured diagnostic")
    equal("new", dir_state.files["root/target"] and dir_state.files["root/target"].content,
        "final parent close diagnostic retains the published atomic bytes")
end

do
    local sys, state = posix_fake({ ["root/book.epub.part"] = string.rep("N", 1024), ["root/book.epub"] = "old" })
    local fs = injected_fs(sys)
    fs.read = function() error("prepared archive bytes must not be read through Fs:read") end
    local published, err = fs:atomicReplacePreparedFile("root/book.epub.part", "root/book.epub", {
        root = "root", root_identity = { dev = "1", ino = "2" }, expected_size = 1024,
    })
    truthy(published, "prepared dirfd transaction publishes without Lua archive buffering: " .. tostring(err and err.message))
    equal(string.rep("N", 1024), state.files["root/book.epub"] and state.files["root/book.epub"].content,
        "prepared dirfd transaction publishes exact inode bytes")
    equal(nil, state.files["root/book.epub.part"], "prepared rename consumes the part path at commit")
    equal(nil, next(state.fds), "prepared publication closes every descriptor")

    local close_sys, close_state = posix_fake({ ["root/book.epub.part"] = "new", ["root/book.epub"] = "old" }, {
        close_eio_path = "root",
    })
    local committed, diagnostic = injected_fs(close_sys):atomicReplacePreparedFile("root/book.epub.part", "root/book.epub", {
        root = "root", root_identity = { dev = "1", ino = "2" }, expected_size = 3,
    })
    truthy(committed, "post-commit parent close EIO does not lie that the prepared rename was unpublished")
    equal("STORAGE_ERROR", diagnostic and diagnostic.code, "post-commit close EIO is returned as a publication diagnostic")
    equal("new", close_state.files["root/book.epub"] and close_state.files["root/book.epub"].content,
        "post-commit close diagnostic retains the committed final EPUB")
    equal(nil, close_state.files["root/book.epub.part"], "post-commit close diagnostic observes consumed part path")
end

-- The Windows test runtime drives the production dirfd transaction through an
-- injected syscall surface, including ARM flags and EINTR handling.
do
    local sys, state = posix_fake({ ["root/target"] = "old" }, {
        fsync_dir_eintr_once = true, backup_unlink_eintr_once = true, close_eintr_reuse_once = true,
    })
    local saved, err = injected_fs(sys):atomicWrite("root/target", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    truthy(saved, "injected POSIX transaction succeeds after retry-safe EINTR handling: " .. tostring(err and err.message))
    equal("new", state.files["root/target"] and state.files["root/target"].content, "successful transaction publishes new bytes")
    truthy(state.fsync_dir_calls >= 2, "parent fsync retries EINTR")
    equal(2, state.backup_unlink_calls, "backup unlink retries EINTR")
    equal(1, state.close_by_fd[state.reused_fd], "Linux close EINTR is never retried against a reused descriptor number")
    equal("reused-after-close", state.fds[state.reused_fd] and state.fds[state.reused_fd].label,
        "descriptor reused before close returned is not closed by atomic cleanup")
    for _, flags in ipairs(state.directory_flags) do
        truthy(bit.band(flags, 16384) ~= 0 and bit.band(flags, 32768) ~= 0, "ARM open/openat uses ARM directory and nofollow bits")
        equal(0, bit.band(flags, 65536 + 131072), "ARM open/openat excludes asm-generic directory/nofollow bits")
    end
end

-- A permanent post-rename parent fsync failure rejects success and restores
-- the previous target. With no previous target it removes the new file.
do
    local sys, state = posix_fake({ ["root/target"] = "old" }, { fsync_dir_permanent = true })
    local saved, err = injected_fs(sys):atomicWrite("root/target", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    equal(nil, saved, "permanent parent fsync failure rejects replacement")
    equal("STORAGE_ERROR", err and err.code, "fsync failure is structured")
    equal("old", state.files["root/target"] and state.files["root/target"].content, "fsync failure restores old bytes")
    equal(nil, next(state.fds), "fsync failure closes all descriptors")

    local fresh_sys, fresh_state = posix_fake({}, { fsync_dir_permanent = true })
    local created, create_error = injected_fs(fresh_sys):atomicWrite("root/new", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    equal(nil, created, "new target fsync failure rejects creation")
    equal("STORAGE_ERROR", create_error and create_error.code, "new target fsync failure is structured")
    equal(nil, fresh_state.files["root/new"], "new target is removed after fsync failure")
end

-- Backup cleanup failure cannot be forgotten or reported as success.
do
    local sys, state = posix_fake({ ["root/target"] = "old" }, { backup_unlink_permanent = true })
    local saved, err = injected_fs(sys):atomicWrite("root/target", "new", { root = "root", root_identity = { dev = "1", ino = "2" } })
    equal(nil, saved, "permanent backup unlink failure is not success")
    equal("STORAGE_ERROR", err and err.code, "backup unlink failure is structured")
    truthy(state.backup_unlink_calls >= 1, "backup unlink failure is observed")
    equal(nil, next(state.fds), "unlink failure closes all descriptors")
end

-- If validation recovery succeeds but its directory fsync fails, the original
-- validation error is wrapped in a compound durability failure.
do
    local sys, state = posix_fake({ ["root/target"] = "old" }, { fsync_dir_fail_on = 2 })
    local saved, err = injected_fs(sys):atomicWrite("root/target", "new", {
        root = "root", root_identity = { dev = "1", ino = "2" },
        validate = function(_, phase) if phase == "after_replace" then return nil, { code = "INVALID_INPUT", message = "race" } end return true end,
    })
    equal(nil, saved, "restore fsync failure rejects the transaction")
    equal("STORAGE_ERROR", err and err.code, "restore fsync failure is compound storage error")
    equal("old", state.files["root/target"] and state.files["root/target"].content, "restore fsync failure does not lose original bytes")
    equal(nil, next(state.fds), "restore fsync failure closes all descriptors")
end

return count
