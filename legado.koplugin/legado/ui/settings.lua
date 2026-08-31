local SettingsView = {}
SettingsView.__index = SettingsView

function SettingsView.new(options)
    options = options or {}
    local values = options.settings and options.settings:all() or {}
    return setmetatable({
        kind = "settings",
        settings = options.settings,
        values = values,
        actions = { { text = "阅读外观（由 KOReader 管理）", callback = options.appearance or function() return false end } },
    }, SettingsView)
end

function SettingsView:refresh()
    self.values = self.settings and self.settings:all() or self.values or {}
    return self.values
end

function SettingsView:set(key, value)
    if not self.settings or type(self.settings.set) ~= "function" then return nil, { code = "STORAGE_ERROR" } end
    local saved, err = self.settings:set(key, value)
    self:refresh()
    return saved, err
end

return SettingsView
