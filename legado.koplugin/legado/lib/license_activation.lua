local Access = require('legado.lib.network_access')
local Adapter = require('legado.lib.subprocess_adapter')
local Wire = require('legado.lib.wire_codec')
local StandbyGuard = require('legado.lib.standby_guard')
local Transport = require('legado.lib.license_transport')
local Activation = {}
-- KOReader's native connectivity check itself may need up to 45 seconds.
Activation.CONNECT_TIMEOUT = 60

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

function Activation.start(license, key, callback, options)
    options = options or {}
    local payload, reason = license:prepareActivation(key)
    local handle = {}
    function handle:cancel() return false end
    if not payload then callback(nil, reason);return handle end
    local scheduler = options.scheduler or optional('ui/uimanager')
    if not scheduler or type(scheduler.scheduleIn) ~= 'function' then
        callback(nil, 'background_unavailable');return handle
    end
    local adapter = options.subprocess or Adapter.new({ max_wire_bytes = 16384 })
    local guard = options.standby or StandbyGuard.new({ ui_manager = scheduler })
    local request = license.request or Transport.request
    local id = payload.device_id
    local stopped, child, network, held = false, nil, nil, false
    local timers = {}
    license.activating = handle

    local function clear(field)
        local fn = timers[field];timers[field] = nil
        if fn and scheduler.unschedule then pcall(scheduler.unschedule, scheduler, fn) end
    end
    local function cleanup()
        if not child then return end
        local retiring = child;child = nil
        pcall(adapter.close, adapter, retiring)
        local function reap()
            local ok, done = pcall(adapter.reap, adapter, retiring)
            if ok and not done then
                -- SIGKILL may need another UI tick; retain ownership until waitpid collects it.
                pcall(scheduler.scheduleIn, scheduler, 0.1, reap)
            end
        end
        reap()
    end
    local function stop(abort)
        if stopped then return false end
        stopped = true
        clear('poll');clear('deadline');clear('connect');clear('start')
        if network then network:cancel() end
        if abort and child then pcall(adapter.terminate, adapter, child) end
        cleanup()
        payload = nil
        if held then held = false;pcall(guard.release, guard) end
        if license.activating == handle then license.activating = nil end
        return true
    end
    function handle:cancel() return stop(true) end
    local function finish(response, error_code)
        if not stop(error_code ~= nil) then return end
        local ok, accepted, accept_error = pcall(license.acceptActivation, license, response, id, error_code)
        if not ok then callback(nil, 'invalid_response') else callback(accepted, accept_error) end
    end
    local function schedule(field, delay, fn)
        timers[field] = fn
        local ok = pcall(scheduler.scheduleIn, scheduler, delay, fn)
        if not ok then finish(nil, 'background_unavailable') end
        return ok
    end
    local function connected(ok, error_code)
        if stopped then return end
        clear('connect')
        if not ok then finish(nil, error_code);return end
        local child_payload = payload
        local start_ok, started = pcall(adapter.start, adapter, function()
            -- The child only talks to the server. Device identity, signature verification
            -- and durable settings writes stay in the parent process.
            local called, response, request_error = pcall(request, child_payload)
            if not called then return { error = 'network_error' } end
            return { response = response, error = request_error }
        end)
        payload = nil
        if not start_ok or not started then finish(nil, 'background_unavailable');return end
        child = started
        if not schedule('deadline', Transport.TIMEOUT + 1, function() finish(nil, 'timeout') end) then return end
        local poll
        poll = function()
            if stopped then return end
            local polled, done, encoded, poll_error = pcall(adapter.poll, adapter, child)
            if not polled or poll_error then finish(nil, 'network_error');return end
            if not done then schedule('poll', 0.05, poll);return end
            local decoded_ok, decoded = false, nil
            if type(encoded) == 'string' and #encoded <= 16384 then decoded_ok, decoded = pcall(Wire.decode, encoded) end
            if not decoded_ok or type(decoded) ~= 'table' or decoded.panic then finish(nil, 'invalid_response');return end
            finish(decoded.response, decoded.error)
        end
        schedule('poll', 0, poll)
    end
    local acquired, value = pcall(guard.acquire, guard)
    held = acquired and value == true
    schedule('start', 0, function()
        if stopped then return end
        local ok, available = pcall(adapter.available, adapter)
        if not ok or not available then finish(nil, 'background_unavailable');return end
        if not schedule('connect', Activation.CONNECT_TIMEOUT, function() finish(nil, 'offline') end) then return end
        network = Access.run(options.network_manager or optional('ui/network/manager'), connected)
        if stopped then network:cancel() end
    end)
    return handle
end

return Activation
