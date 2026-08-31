local SettingsView = {}
SettingsView.__index = SettingsView

function SettingsView.new(options)
    options = options or {}
    local values = options.settings and options.settings:all() or {}
    return setmetatable({
        kind = "settings",
        settings = options.settings,
        settings_error = options.settings_error,
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

function SettingsView:status()
    if self.settings and type(self.settings.status) == "function" then return self.settings:status() end
    return { error = self.settings_error }
end

function SettingsView:retryRecovery()
    if not self.settings or type(self.settings.retryRecovery) ~= "function" then
        return nil, { code = "RECOVERY_REQUIRED" }
    end
    local retried, err = self.settings:retryRecovery()
    self.settings_error = err
    self:refresh()
    return retried, err
end

function SettingsView:resetCorrupt()
    if not self.settings or type(self.settings.resetCorrupt) ~= "function" then
        return nil, { code = "RECOVERY_REQUIRED" }
    end
    local backup, err = self.settings:resetCorrupt()
    self.settings_error = err
    self:refresh()
    return backup, err
end

return SettingsView
