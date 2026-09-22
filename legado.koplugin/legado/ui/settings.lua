local SettingsView = {}
SettingsView.__index = SettingsView

function SettingsView.new(options)
    options = options or {}
    local values = options.settings and options.settings:all() or {}
    return setmetatable({
        kind = "settings",
        settings = options.settings,
        settings_error = options.settings_error,
        temporary_reader_mode = options.temporary_reader_mode,
        values = values,
        clear_cache = options.clear_cache, cache_usage = options.cache_usage, cache_cleanup = options.cache_cleanup, local_library = options.local_library,
        on_sources = options.on_sources, on_progress_change = options.on_progress_change,
        on_close = options.on_close,
        chrome_only = options.chrome_only, on_chrome_change = options.on_chrome_change,
        on_background_change = options.on_background_change,
        on_margins = options.on_margins,
        on_layout = options.on_layout, document = options.document,
        on_toggle_reader = options.on_toggle_reader,
        actions = options.on_layout and {} or {{ text = "阅读外观（由 KOReader 管理）", callback = options.appearance or function() return false end }},
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
    if saved ~= nil and (key == 'progress_bar' or key:match('^progress_bar_')) and self.on_progress_change then
        self.footer_unavailable=self.on_progress_change(saved)==false
    end
    if saved ~= nil and (key:match('^reader_corner_') or key=='reader_header_font_size' or key=='reader_footer_font_size')
        and self.on_chrome_change then self.on_chrome_change() end
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
