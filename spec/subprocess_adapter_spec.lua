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

return 17
