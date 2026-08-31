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
        items = {}, alive = true, generation = 0, navigation = Navigation.new({ count = 0, columns = 1 }) }, Downloads)
    self:refresh()
    return self
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
    return true
end

return Downloads
