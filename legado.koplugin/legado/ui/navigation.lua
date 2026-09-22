local Navigation = {}
Navigation.__index = Navigation

function Navigation.new(options)
    options = options or {}
    return setmetatable({
        position = math.max(1, tonumber(options.index) or 1),
        count = math.max(0, tonumber(options.count) or 0),
        columns = math.max(1, tonumber(options.columns) or 1),
    }, Navigation)
end

function Navigation:index() return self.position end

function Navigation:setCount(count)
    self.count = math.max(0, tonumber(count) or 0)
    self.position = self.count == 0 and 1 or math.min(self.position, self.count)
end

function Navigation:onKey(key)
    local delta = ({
        Left = -1, Right = 1, Up = -self.columns, Down = self.columns,
        LPgBack = -1, RPgBack = -1, LPgFwd = 1, RPgFwd = 1,
        PageUp = -1, PageDown = 1,
    })[key]
    if not delta then return false end
    if self.count > 0 then self.position = math.max(1, math.min(self.count, self.position + delta)) end
    return true
end

return Navigation
