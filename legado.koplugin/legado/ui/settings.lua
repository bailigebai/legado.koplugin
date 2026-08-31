local SettingsView = {}
SettingsView.__index = SettingsView

function SettingsView.new(options)
    options = options or {}
    local values = options.settings and options.settings:all() or {}
    return setmetatable({
        kind = "settings",
        values = values,
        actions = { { text = "阅读外观", callback = options.appearance or function() return false end } },
    }, SettingsView)
end

return SettingsView
