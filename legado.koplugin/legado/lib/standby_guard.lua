local StandbyGuard = {}
StandbyGuard.__index = StandbyGuard

function StandbyGuard.new(options)
    options = options or {}
    local ui = options.ui_manager
    local supported = type(ui) == "table" and type(ui.preventStandby) == "function" and type(ui.allowStandby) == "function"
    return setmetatable({ ui = ui, supported = supported, references = 0 }, StandbyGuard)
end

function StandbyGuard:acquire()
    if not self.supported then return false end
    if self.references == 0 then
        local ok = pcall(self.ui.preventStandby, self.ui)
        if not ok then return false end
    end
    self.references = self.references + 1
    return true
end

function StandbyGuard:release()
    if not self.supported or self.references == 0 then return self.supported end
    self.references = self.references - 1
    if self.references == 0 then return pcall(self.ui.allowStandby, self.ui) end
    return true
end

function StandbyGuard:releaseAll()
    if not self.supported then self.references = 0; return false end
    if self.references > 0 then
        self.references = 0
        return pcall(self.ui.allowStandby, self.ui)
    end
    return true
end

function StandbyGuard:count() return self.references end

return StandbyGuard
