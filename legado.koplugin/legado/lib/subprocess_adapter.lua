local Wire = require("legado.lib.wire_codec")

local Adapter = {}
Adapter.__index = Adapter

local function optional_require(name)
    local ok, value = pcall(require, name)
    if ok then return value end
    return nil
end

function Adapter.new(options)
    options = options or {}
    return setmetatable({
        util = options.ffi_util or optional_require("ffi/util"),
        ffi = options.ffi or optional_require("ffi"),
    }, Adapter)
end

function Adapter:available()
    local util = self.util
    return type(util) == "table"
        and type(util.runInSubProcess) == "function"
        and type(util.isSubProcessDone) == "function"
        and type(util.terminateSubProcess) == "function"
        and type(util.getNonBlockingReadSize) == "function"
        and type(util.writeToFD) == "function"
        and type(util.readAllFromFD) == "function"
end

function Adapter:start(job)
    if not self:available() then return nil, "subprocess pipe API is unavailable" end
    local util = self.util
    local pid, read_fd = util.runInSubProcess(function(_, write_fd)
        local ok, result = pcall(job)
        if not ok then result = { panic = tostring(result) } end
        local payload, encode_error = Wire.encode(result)
        if not payload then payload = assert(Wire.encode({ panic = encode_error })) end
        util.writeToFD(write_fd, payload, true)
    end, true)
    if pid == false or pid == nil then return nil, tostring(read_fd or "subprocess start failed") end
    return {
        pid = pid,
        fd = read_fd,
        chunks = {},
        reaped = false,
        closed = false,
        terminated = false,
    }, nil
end

function Adapter:_read_available(child)
    if child.fd == nil then return true end
    local available = self.util.getNonBlockingReadSize(child.fd)
    if not available or available <= 0 then return true end
    if not self.ffi then return false, "FFI pipe reader is unavailable" end
    local buffer = self.ffi.new("char[?]", available)
    local bytes = tonumber(self.ffi.C.read(child.fd, buffer, available))
    if not bytes or bytes < 0 then return false, "pipe read failed" end
    if bytes > 0 then child.chunks[#child.chunks + 1] = self.ffi.string(buffer, bytes) end
    return true
end

function Adapter:poll(child)
    if child.reaped then return true, table.concat(child.chunks) end
    local read_ok, read_error = self:_read_available(child)
    if not read_ok then return true, nil, read_error end
    if not self.util.isSubProcessDone(child.pid, false) then return false end
    child.reaped = true
    if child.fd ~= nil then
        child.chunks[#child.chunks + 1] = self.util.readAllFromFD(child.fd) or ""
        child.fd = nil
        child.closed = true
    end
    return true, table.concat(child.chunks), nil
end

function Adapter:terminate(child)
    if child.terminated or child.reaped then return false end
    child.terminated = true
    self.util.terminateSubProcess(child.pid)
    return true
end

function Adapter:reap(child)
    if child.reaped then return true end
    if self.util.isSubProcessDone(child.pid, false) then child.reaped = true; return true end
    return false
end

function Adapter:close(child)
    if child.closed then return false end
    child.closed = true
    if child.fd ~= nil then
        if type(self.util.closeFD) == "function" then self.util.closeFD(child.fd)
        elseif self.ffi and self.ffi.C then self.ffi.C.close(child.fd) end
        child.fd = nil
    end
    return true
end

return Adapter
