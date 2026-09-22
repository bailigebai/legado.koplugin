local assertx = require("assertions")
local Adapter = require("legado.lib.subprocess_adapter")
local Wire = require("legado.lib.wire_codec")

local calls = { done = 0, closed = 0, terminated = 0 }
local pipe_data = ""
local util = {
    runInSubProcess = function(job, with_pipe)
        assertx.equal(true, with_pipe, "adapter requests a child-to-parent pipe")
        job(321, 9)
        return 321, 8
    end,
    writeToFD = function(fd, data, close_fd)
        assertx.equal(9, fd, "child writes to pipe fd")
        assertx.equal(true, close_fd, "child closes write fd")
        pipe_data = data
        return true
    end,
    getNonBlockingReadSize = function() return 0 end,
    readAllFromFD = function(fd)
        assertx.equal(8, fd, "parent reads pipe fd")
        calls.closed = calls.closed + 1
        return pipe_data
    end,
    isSubProcessDone = function()
        calls.done = calls.done + 1
        return calls.done > 1
    end,
    terminateSubProcess = function(pid)
        assertx.equal(321, pid, "child pid terminated")
        calls.terminated = calls.terminated + 1
    end,
}

local adapter = Adapter.new({ ffi_util = util })
assertx.equal(true, adapter:available(), "complete ffi/util pipe API is available")
local child = adapter:start(function()
    return { response = { status = 200, body = "child payload" } }
end)
assertx.type("table", child, "subprocess start returns child state")
local first_done = adapter:poll(child)
assertx.equal(false, first_done, "running child polls without blocking")
local second_done, payload = adapter:poll(child)
assertx.equal(true, second_done, "completed child is observed")
local decoded, decode_error = Wire.decode(payload)
assertx.equal(nil, decode_error, "wire payload decodes")
assertx.equal("child payload", decoded.response.body, "child result crosses pipe")
assertx.equal(true, adapter:reap(child), "completed child is reaped")
adapter:close(child)
assertx.equal(1, calls.closed, "pipe closes exactly once")

local terminating = adapter:start(function() return { response = { status = 200 } } end)
adapter:terminate(terminating)
adapter:terminate(terminating)
assertx.equal(1, calls.terminated, "termination is idempotent")

local incomplete = Adapter.new({ ffi_util = { runInSubProcess = function() end } })
assertx.equal(false, incomplete:available(), "partial pipe API falls back safely")

local malformed, malformed_error = Wire.decode("T1:S3:key")
assertx.equal(nil, malformed, "truncated wire payload rejected")
assertx.truthy(type(malformed_error) == "string", "malformed wire diagnostic")

local progressive_data = assert(Wire.encode({ response = { status = 200, body = "progressive" } }))
local progressive_offset = 1
local progressive_util = {
    runInSubProcess = function(job) job(22, 23); return 22, 24 end,
    writeToFD = function(_, data) progressive_data = data; return true end,
    getNonBlockingReadSize = function()
        return progressive_offset <= #progressive_data and math.min(3, #progressive_data - progressive_offset + 1) or 0
    end,
    readAllFromFD = function() return "" end,
    isSubProcessDone = function() return progressive_offset > #progressive_data end,
    terminateSubProcess = function() end,
}
local progressive_adapter = Adapter.new({
    ffi_util = progressive_util,
    read_fd = function(_, count)
        local chunk = progressive_data:sub(progressive_offset, progressive_offset + count - 1)
        progressive_offset = progressive_offset + #chunk
        return chunk
    end,
})
local progressive_child = assert(progressive_adapter:start(function()
    return { response = { status = 200, body = "progressive" } }
end))
local progressive_done, progressive_payload
for _ = 1, 100 do
    progressive_done, progressive_payload = progressive_adapter:poll(progressive_child)
    if progressive_done then break end
end
assertx.equal(true, progressive_done, "progressive FFI reads eventually complete")
local progressive_decoded = assert(Wire.decode(progressive_payload))
assertx.equal("progressive", progressive_decoded.response.body, "progressive reads preserve wire payload")

local short_data = ""
local short_util = {
    runInSubProcess = function(job) job(31, 32); return 31, 33 end,
    writeToFD = function(_, data) short_data = data:sub(1, 5); return false end,
    getNonBlockingReadSize = function() return 0 end,
    readAllFromFD = function() return short_data end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
}
local short_adapter = Adapter.new({ ffi_util = short_util })
local short_child = assert(short_adapter:start(function() return { response = { status = 200 } } end))
local short_done, _, short_error = short_adapter:poll(short_child)
assertx.equal(true, short_done, "short child write completes deterministically")
assertx.equal("child pipe write incomplete", short_error, "writeToFD false propagates explicitly")

local oversized_data = string.rep("x", Wire.MAX_BYTES + 1)
local oversized_util = {
    runInSubProcess = function() return 41, 42 end,
    writeToFD = function() return true end,
    getNonBlockingReadSize = function() return 0 end,
    readAllFromFD = function() return oversized_data end,
    isSubProcessDone = function() return true end,
    terminateSubProcess = function() end,
}
local oversized_adapter = Adapter.new({ ffi_util = oversized_util })
local oversized_child = assert(oversized_adapter:start(function() end))
local oversized_done, _, oversized_error = oversized_adapter:poll(oversized_child)
assertx.equal(true, oversized_done, "oversized wire completes with failure")
assertx.equal("child wire payload exceeds limit", oversized_error, "parent bounds child wire accumulation")

return 25
