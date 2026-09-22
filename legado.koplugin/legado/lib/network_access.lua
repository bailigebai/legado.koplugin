-- Only explicit online operations call this; never change Wi-Fi power preferences.
local Access = {}

function Access.run(manager, callback)
    local stopped = false
    local handle = {}
    function handle:cancel()
        if stopped then return false end
        stopped = true
        return true
    end
    local function finish(ok, reason)
        if stopped then return end
        stopped = true
        callback(ok, reason)
    end
    if not manager or type(manager.runWhenConnected) ~= 'function' or type(manager.isConnected) ~= 'function' then
        finish(nil, 'network_unavailable')
        return handle
    end
    local called = pcall(manager.runWhenConnected, manager, function()
        if stopped then return end
        local ok, connected = pcall(manager.isConnected, manager)
        if ok and connected then return finish(true) end
        local checked, wifi = pcall(function() return manager:isWifiOn() end)
        finish(nil, checked and wifi == false and 'wifi_off' or 'offline')
    end)
    if not called then finish(nil, 'offline') end
    return handle
end

return Access
