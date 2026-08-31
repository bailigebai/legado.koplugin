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

function Fs.new(options)
    options = options or {}
    return setmetatable({
        lfs = options.lfs or default_lfs(),
        rename = options.rename or os.rename,
        remove = options.remove or os.remove,
        open = options.open or io.open,
    }, Fs)
end

function Fs:join(root, ...)
    if type(root) ~= "string" or root == "" then
        return nil, Errors.new(Errors.INVALID_INPUT, "missing storage root")
    end
    local pieces = { root:gsub("[/\\]+$", "") }
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

function Fs:atomicWrite(path, data)
    if type(data) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "atomic write accepts strings") end
    local parent = parent_directory(path)
    local ensured, ensure_error = self:ensureDirectory(parent)
    if not ensured then return nil, ensure_error end
    local temporary = path .. ".tmp"
    local handle, open_error = self.open(temporary, "wb")
    if not handle then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot create temporary file", { path = temporary, cause = open_error }) end
    local written, write_error = handle:write(data)
    handle:flush()
    handle:close()
    if not written then
        self.remove(temporary)
        return nil, Errors.new(Errors.STORAGE_ERROR, "cannot write temporary file", { path = temporary, cause = write_error })
    end
    local renamed, rename_error = self.rename(temporary, path)
    if not renamed then
        -- Windows Lua runtimes may refuse to overwrite an existing path. Move
        -- the old sibling aside first and restore it if the final rename fails.
        local backup = path .. ".bak"
        local existing = self.open(path, "rb")
        if existing then
            existing:close()
            local backup_handle = self.open(backup, "rb")
            if backup_handle then
                backup_handle:close()
                self.remove(temporary)
                return nil, Errors.new(Errors.STORAGE_ERROR, "cannot replace file", { path = path, cause = "backup path exists" })
            end
            local moved_old, move_error = self.rename(path, backup)
            if moved_old then
                renamed, rename_error = self.rename(temporary, path)
                if renamed then
                    self.remove(backup)
                    return true
                end
                local restored, restore_error = self.rename(backup, path)
                if not restored then
                    self.remove(temporary)
                    return nil, Errors.new(Errors.STORAGE_ERROR, "cannot restore original file", {
                        path = path,
                        cause = rename_error,
                        restore_cause = restore_error,
                        recovery_path = backup,
                    })
                end
            else
                rename_error = move_error or rename_error
            end
        end
        self.remove(temporary)
        return nil, Errors.new(Errors.STORAGE_ERROR, "cannot replace file", { path = path, cause = rename_error })
    end
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
