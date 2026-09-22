local Home = {}
Home.__index = Home

function Home.new(options)
    options = options or {}
    assert(options.storage, "Home requires storage")
    return setmetatable({ kind = "home", storage = options.storage, actions = options.actions or {}, page_size = options.page_size or 6,
        cover_loader = options.cover_loader, generation = 0, handles = {}, alive = true }, Home)
end

function Home:_cancelCovers()
    for _, handle in ipairs(self.handles) do if handle and type(handle.cancel) == "function" then handle:cancel() end end
    self.handles = {}
end

function Home:page()
    self:_cancelCovers()
    self.generation = self.generation + 1
    local generation = self.generation
    local books, times = {}, {}
    for _, book in ipairs(self.storage:listShelf() or {}) do
        local progress = type(self.storage.getProgress) == "function" and self.storage:getProgress(book.id)
        if progress then
            books[#books + 1] = book
            times[book.id] = tonumber(progress.updated_at or progress.updatedAt or progress.timestamp) or 0
        end
    end
    table.sort(books, function(left, right)
        local lt, rt = times[left.id], times[right.id]
        if lt ~= rt then return lt > rt end
        return tostring(left.name or "") < tostring(right.name or "")
    end)
    local recent = {}
    for index = 1, math.min(#books, self.page_size) do
        local item = books[index]
        recent[index] = item
        local has_cover = type(item.cover_url) == "string" and item.cover_url:match("%S")
        item.cover_text = has_cover and "封面不可用" or "无封面"
        if has_cover and type(self.cover_loader) == "function" then
            item.cover_text = "封面加载中"
            local handle = self.cover_loader(item, function(image)
                if not self.alive or generation ~= self.generation then return end
                item.cover = image
                if not image then item.cover_text = "封面不可用" end
                if type(item.on_update) == "function" then item.on_update(item) end
            end)
            self.handles[#self.handles + 1] = handle
        end
    end
    local actions = {}
    local labels = {
        { key = "bookshelf", text = "书架" }, { key = "search", text = "搜索" },
        { key = "sources", text = "书源管理" }, { key = "discovery", text = "发现" },
        { key = "downloads", text = "下载管理" }, { key = "settings", text = "设置" },
    }
    for _, item in ipairs(labels) do
        if type(self.actions[item.key]) == "function" then actions[#actions + 1] = { text = item.text, callback = self.actions[item.key] } end
    end
    return {
        kind = "home", recent = recent, actions = actions,
        empty_text = #recent == 0 and "暂无最近阅读" or nil,
        empty_actions = #recent == 0 and {
            { text = "去书架添加", callback = self.actions.bookshelf },
        } or nil,
    }
end

function Home:close()
    if not self.alive then return false end
    self.alive = false
    self.generation = self.generation + 1
    self:_cancelCovers()
    return true
end

return Home
