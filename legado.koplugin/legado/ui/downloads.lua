local Navigation = require("legado.ui.navigation")

local Downloads = {}
Downloads.__index = Downloads

local labels = {
    queued = "等待中", running = "下载中", cancelling = "正在取消", cancelled = "已取消",
    failed = "失败", completed = "完成", interrupted = "已中断",
}

function Downloads.new(options)
    options = options or {}
    assert(options.manager, "Downloads view requires manager")
    local self = setmetatable({ kind = "downloads", title = "下载管理", manager = options.manager,
        scheduler = options.scheduler, refresh_interval = tonumber(options.refresh_interval) or 3,
        on_refresh = options.on_refresh, refresh_token = nil,
        items = {}, alive = true, generation = 0, navigation = Navigation.new({ count = 0, columns = 1 }) }, Downloads)
    self:refresh()
    self:_scheduleRefresh()
    return self
end

function Downloads:_hasActive()
    for _, item in ipairs(self.items or {}) do
        local status = item.task and item.task.status
        if status == "queued" or status == "running" or status == "cancelling" then return true end
    end
    return false
end

function Downloads:_scheduleRefresh()
    if not self.alive or self.refresh_token or not self:_hasActive()
        or not self.scheduler or type(self.scheduler.scheduleIn) ~= "function" then return false end
    local generation = self.generation
    local token
    token = self.scheduler:scheduleIn(self.refresh_interval, function()
        if not self.alive or generation ~= self.generation or self.refresh_token ~= token then return end
        self.refresh_token = nil
        local items = self:refresh()
        if type(self.on_refresh) == "function" then pcall(self.on_refresh, self, items) end
        self:_scheduleRefresh()
    end)
    self.refresh_token = token
    return token ~= nil
end

function Downloads:refresh()
    if not self.alive then return false end
    local items = {}
    for _, task in ipairs(self.manager:list() or {}) do
        local completed, total = tonumber(task.completed) or 0, tonumber(task.total) or 0
        local progress = total > 0 and (" · " .. completed .. "/" .. total) or ""
        local failures = (tonumber(task.failed) or 0) > 0 and (" · 失败 " .. tostring(task.failed)) or ""
        items[#items + 1] = { task = task, text = tostring(task.book and task.book.name or task.book_id or "未命名")
            .. " · " .. (labels[task.status] or tostring(task.status or "未知")) .. progress .. failures }
    end
    self.items = items
    self.navigation:setCount(#items)
    return items
end

function Downloads:onKey(key) if not self.alive then return false end return self.navigation:onKey(key) end
function Downloads:focused() return self.items[self.navigation:index()] end

local function action(self, method, id)
    if not self.alive or type(self.manager[method]) ~= "function" then return false end
    local result, err = self.manager[method](self.manager, id)
    if result then self:refresh() end
    return result, err
end

function Downloads:cancel(id) return action(self, "cancel", id) end
function Downloads:retry(id) return action(self, "retry", id) end
function Downloads:resume(id) return action(self, "resume", id) end
function Downloads:open(id) return action(self, "open", id) end

function Downloads:close()
    if not self.alive then return false end
    self.alive = false; self.generation = self.generation + 1
    if self.refresh_token and self.scheduler and type(self.scheduler.unschedule) == "function" then
        pcall(self.scheduler.unschedule, self.scheduler, self.refresh_token)
    end
    self.refresh_token, self.on_refresh = nil, nil
    return true
end

return Downloads
