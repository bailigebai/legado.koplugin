local Navigation = require("legado.ui.navigation")

local Shelf = {}
Shelf.__index = Shelf

local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end

function Shelf.new(options)
    options = options or {}
    assert(options.storage, "Shelf requires storage")
    return setmetatable({
        kind = "bookshelf",
        storage = options.storage,
        page_size = math.max(1, tonumber(options.page_size) or 20),
        covers_enabled = options.covers_enabled ~= false,
        cover_loader = options.cover_loader,
        on_search = options.on_search,
        on_sources = options.on_sources,
        settings = options.settings,
        source_mode = options.source_mode or "sources", local_library = options.local_library,
        reading_state = "all", category = nil,
        alive = true, generation = 0, cover_handles = {},
        navigation = Navigation.new({ count = 0, columns = 1 }),
    }, Shelf)
end

function Shelf:_localBooks()
    if not self.local_books then
        if self.local_library then self.local_books,self.local_warning=self.local_library:scan()
        else self.local_books={} end
    end
    return self.local_books
end

function Shelf:add(book)
    return self.storage:createBook(book)
end
function Shelf:remove(book_id) return self.storage:deleteBook(book_id) end

function Shelf:setFilter(reading_state, category)
    self.reading_state = (reading_state == "reading" or reading_state == "unread") and reading_state or "all"
    self.category = category
end

local function book_categories(book, legacy)
    local names, seen = {}, {}
    local value = book.custom_categories or ""
    if type(value) == "table" then
        for _, name in ipairs(value) do
            name = trim(name)
            if name ~= "" and not seen[name] then names[#names + 1], seen[name] = name, true end
        end
        return names
    end
    if not legacy then return names end
    value = trim(book.kind):gsub("，", ","):gsub("、", ","):gsub("；", ",")
    for part in value:gmatch("[^,;|/\r\n]+") do
        local name = trim(part)
        if name ~= "" and not seen[name] then names[#names+1], seen[name] = name, true end
    end
    return names
end

function Shelf:_cancelCovers()
    for _, handle in ipairs(self.cover_handles) do if handle and type(handle.cancel) == "function" then handle:cancel() end end
    self.cover_handles = {}
end

function Shelf:page(page, mode, page_size_override)
    self:_cancelCovers()
    self.generation = self.generation + 1
    local generation = self.generation
    local books, category_counts = {}, {}
    local counts = { all = 0, reading = 0, unread = 0 }
    local all_books = {}
    if self.source_mode ~= "local" then for _, book in ipairs(self.storage:listShelf() or {}) do if not book.is_local then all_books[#all_books + 1] = book end end end
    if self.source_mode == "local" or self.source_mode == "mixed" then for _, book in ipairs(self:_localBooks()) do all_books[#all_books + 1] = book end end
    for _, book in ipairs(all_books) do
        local included = self.category == nil
        for _, name in ipairs(book_categories(book, self.settings == nil)) do
            category_counts[name] = (category_counts[name] or 0) + 1
            if name == self.category then included = true end
        end
        if included then
            local progress = type(self.storage.getProgress) == "function" and self.storage:getProgress(book.id)
            local state = type(progress) == "table" and "reading" or "unread"
            counts.all, counts[state] = counts.all + 1, counts[state] + 1
            if self.reading_state == "all" or self.reading_state == state then books[#books+1] = book end
        end
    end
    local categories = {}
    for _, name in ipairs(self.settings and self.settings:get("shelf_categories") or {}) do
        if trim(name) ~= "" and category_counts[name] == nil then category_counts[name] = 0 end
    end
    for name, amount in pairs(category_counts) do categories[#categories+1] = { name = name, count = amount } end
    table.sort(categories, function(a,b) return a.name < b.name end)
    page = math.max(1, math.floor(tonumber(page) or 1))
    mode = mode == "cover" and self.covers_enabled and "cover" or "text"
    local page_size = math.max(1, math.floor(tonumber(page_size_override) or (mode == "cover" and 12 or self.page_size)))
    local page_count = math.max(1, math.ceil(#books / page_size))
    page = math.min(page, page_count)
    local items = {}
    local first = (page - 1) * page_size + 1
    local last = math.min(#books, first + page_size - 1)
    for index = first, last do
        local book = books[index]
        local cover_url = trim(book.cover_url)
        local item = {
            id = book.id, book = book, title = trim(book.name) ~= "" and trim(book.name) or "未命名书籍",
            subtitle = trim(book.author), cover_url = cover_url,
            cover_text = cover_url == "" and "无封面" or (type(self.cover_loader) == "function" and "封面加载中" or "封面不可用"),
            cover_pending = mode == "cover" and cover_url ~= "" and type(self.cover_loader) == "function",
        }
        items[#items + 1] = item
        if item.cover_pending then
            local handle = self.cover_loader(book, function(image)
                if not self.alive or generation ~= self.generation then return end
                item.cover = image
                item.cover_pending = false
                if not image then item.cover_text = "封面不可用" end
                if type(item.on_update) == "function" then item.on_update(item) end
            end)
            self.cover_handles[#self.cover_handles + 1] = handle
        end
    end
    self.navigation.columns = mode == "cover" and 4 or 1
    self.navigation:setCount(#items)
    return {
        items = items, page = page, page_count = page_count, mode = mode, total = #books,
        categories = categories, counts = counts, category = self.category, reading_state = self.reading_state,
        source_mode = self.source_mode, warning = self.local_warning,
        empty_text = #books == 0 and "暂无收藏" or nil,
        empty_actions = #books == 0 and {
            { text = "搜索添加", callback = self.on_search },
            { text = "书源管理", callback = self.on_sources },
        } or nil,
    }
end

function Shelf:close()
    if not self.alive then return false end
    self.alive = false
    self.generation = self.generation + 1
    self:_cancelCovers()
    return true
end

function Shelf:onKey(key) return self.navigation:onKey(key) end
function Shelf:focusedIndex() return self.navigation:index() end

return Shelf
