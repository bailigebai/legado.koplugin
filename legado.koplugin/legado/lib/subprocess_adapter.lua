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
    local max_wire_bytes = tonumber(options.max_wire_bytes) or Wire.MAX_BYTES
    max_wire_bytes = math.max(1, math.min(max_wire_bytes, Wire.MAX_BYTES))
    return setmetatable({
        util = options.ffi_util or optional_require("ffi/util"),
        ffi = options.ffi or optional_require("ffi"),
        read_fd = options.read_fd,
        max_wire_bytes = max_wire_bytes,
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
        local framed = tostring(#payload) .. ":" .. payload
        util.writeToFD(write_fd, framed, true)
    end, true)
    if pid == false or pid == nil then return nil, tostring(read_fd or "subprocess start failed") end
    return {
        pid = pid,
        fd = read_fd,
        chunks = {},
        reaped = false,
        closed = false,
        terminated = false,
        bytes = 0,
    }, nil
end

function Adapter:_read_available(child)
    if child.fd == nil then return true, nil, 0 end
    local available = self.util.getNonBlockingReadSize(child.fd)
    if not available or available <= 0 then return true, nil, 0 end
    local remaining = self.max_wire_bytes + 64 - child.bytes
    local wanted = math.min(available, math.max(1, remaining + 1))
    local data
    if self.read_fd then
        data = self.read_fd(child.fd, wanted)
        if type(data) ~= "string" then return false, "pipe read failed" end
    else
        if not self.ffi then return false, "FFI pipe reader is unavailable" end
        local buffer = self.ffi.new("char[?]", wanted)
        local bytes = tonumber(self.ffi.C.read(child.fd, buffer, wanted))
        if not bytes or bytes < 0 then return false, "pipe read failed" end
        data = bytes > 0 and self.ffi.string(buffer, bytes) or ""
    end
    child.bytes = child.bytes + #data
    if child.bytes > self.max_wire_bytes + 64 then return false, "child wire payload exceeds limit" end
    if #data > 0 then child.chunks[#child.chunks + 1] = data end
    return true, nil, #data
end

local function unframe(payload, maximum)
    if #payload > maximum + 64 then return nil, "child wire payload exceeds limit" end
    local colon = payload:find(":", 1, true)
    if not colon then
        if #payload > maximum then return nil, "child wire payload exceeds limit" end
        return nil, "child pipe write incomplete"
    end
    local digits = payload:sub(1, colon - 1)
    if not digits:match("^%d+$") then return nil, "child pipe frame is malformed" end
    local expected = tonumber(digits)
    if not expected or expected > maximum then return nil, "child wire payload exceeds limit" end
    local body = payload:sub(colon + 1)
    if #body ~= expected then return nil, "child pipe write incomplete" end
    return body, nil
end

function Adapter:poll(child)
    if child.reaped then
        local payload, frame_error = unframe(table.concat(child.chunks), self.max_wire_bytes)
        return true, payload, frame_error
    end
    while true do
        local read_ok, read_error, bytes = self:_read_available(child)
        if not read_ok then return true, nil, read_error end
        if not bytes or bytes == 0 then break end
    end
    if not self.util.isSubProcessDone(child.pid, false) then return false end
    child.reaped = true
    if child.fd ~= nil then
        local tail = self.util.readAllFromFD(child.fd) or ""
        child.bytes = child.bytes + #tail
        if child.bytes > self.max_wire_bytes + 64 then
            child.fd = nil
            child.closed = true
            return true, nil, "child wire payload exceeds limit"
        end
        child.chunks[#child.chunks + 1] = tail
        child.fd = nil
        child.closed = true
    end
    local payload, frame_error = unframe(table.concat(child.chunks), self.max_wire_bytes)
    return true, payload, frame_error
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
