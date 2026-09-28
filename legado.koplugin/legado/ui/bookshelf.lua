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
        is_cached = options.is_cached,
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

function Shelf:_booksInMode()
    local books, load_error = {}, nil
    if self.source_mode ~= "local" then
        local saved, err = self.storage:listShelf()
        if type(saved) ~= "table" then load_error = err or { code = "STORAGE_ERROR" }
        else
            for _, book in ipairs(saved) do
                if not book.is_local then books[#books + 1] = book end
            end
        end
    end
    if self.source_mode == "local" or self.source_mode == "mixed" then
        for _, book in ipairs(self:_localBooks()) do books[#books + 1] = book end
    end
    return books, load_error
end

function Shelf:selectedBooks()
    local books, err = self:_booksInMode()
    if err then return nil, err end
    local copies = {}
    for _, book in ipairs(books) do
        if self.selected_books and self.selected_books[book.id] then
            local copy = {}
            for key, value in pairs(book) do
                if key == "custom_categories" and type(value) == "table" then
                    local categories = {}
                    for index, name in ipairs(value) do categories[index] = name end
                    copy[key] = categories
                else copy[key] = value end
            end
            copies[#copies + 1] = copy
        end
    end
    return copies
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
    local read_at, read_state, original_order = {}, {}, {}
    local counts = { all = 0, reading = 0, unread = 0, unknown = 0 }
    local all_books, load_error = self:_booksInMode()
    local eligible = {}
    for index, book in ipairs(all_books) do
        local included = self.category == nil
        for _, name in ipairs(book_categories(book, self.settings == nil)) do
            category_counts[name] = (category_counts[name] or 0) + 1
            if name == self.category then included = true end
        end
        if included then eligible[#eligible + 1] = { book = book, index = index } end
    end
    local progress_by_id, progress_error = {}, nil
    if #eligible > 0 and type(self.storage.listProgress) == "function" then
        local values, err = self.storage:listProgress()
        if type(values) ~= "table" then progress_error = err or { code = "STORAGE_ERROR" }
        else
            for _, progress in ipairs(values) do
                if type(progress) == "table" and progress.book_id ~= nil then
                    progress_by_id[tostring(progress.book_id)] = progress
                end
            end
        end
    elseif type(self.storage.getProgress) == "function" then
        for _, entry in ipairs(eligible) do
            local progress, err = self.storage:getProgress(entry.book.id)
            if err then progress_error = err; break end
            progress_by_id[entry.book.id] = progress
        end
    end
    for _, entry in ipairs(eligible) do
        local book = entry.book
        local progress = not progress_error and progress_by_id[book.id] or nil
        local state = progress_error and "unknown" or type(progress) == "table" and "reading" or "unread"
        counts.all, counts[state] = counts.all + 1, counts[state] + 1
        if self.reading_state == "all" or progress_error or self.reading_state == state then
            books[#books+1] = book
            read_at[book] = type(progress) == "table" and (tonumber(progress.updated_at or progress.updatedAt or progress.timestamp) or 0) or 0
            read_state[book] = state
            original_order[book] = entry.index
        end
    end
    if not progress_error then
        table.sort(books, function(a, b)
            if read_at[a] == read_at[b] then return original_order[a] < original_order[b] end
            return read_at[a] > read_at[b]
        end)
    end
    local categories = {}
    for _, name in ipairs(self.settings and self.settings:get("shelf_categories") or {}) do
        if trim(name) ~= "" and category_counts[name] == nil then category_counts[name] = 0 end
    end
    for name, amount in pairs(category_counts) do categories[#categories+1] = { name = name, count = amount } end
    table.sort(categories, function(a,b) return a.name < b.name end)
    page = math.max(1, math.floor(tonumber(page) or 1))
    mode = mode == "hero" and self.covers_enabled and "hero"
        or mode == "cover" and self.covers_enabled and "cover" or "text"
    local page_size = math.max(1, math.floor(tonumber(page_size_override) or (mode == "cover" and 12 or self.page_size)))
    local hero = mode == "hero"
    local page_count = hero and (1 + math.ceil(math.max(0, #books - 5) / 12))
        or math.max(1, math.ceil(#books / page_size))
    page = math.min(page, page_count)
    local items = {}
    local first = hero and (page == 1 and 1 or 6 + (page - 2) * 12)
        or (page - 1) * page_size + 1
    local last = math.min(#books, hero and (page == 1 and 5 or first + 11) or first + page_size - 1)
    for index = first, last do
        local book = books[index]
        local cover_url = trim(book.cover_url)
        local item = {
            id = book.id, book = book, title = trim(book.name) ~= "" and trim(book.name) or "未命名书籍",
            subtitle = trim(book.author), cover_url = cover_url,
            cover_text = cover_url == "" and "无封面" or (type(self.cover_loader) == "function" and "封面加载中" or "封面不可用"),
            cover_pending = mode == "cover" and cover_url ~= "" and type(self.cover_loader) == "function",
            downloaded = not book.is_local and type(self.is_cached) == "function" and self.is_cached(book) == true or false,
            reading = read_state[book] == "reading",
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
    self.navigation.columns = (mode == "cover" or mode == "hero") and 4 or 1
    self.navigation:setCount(#items)
    return {
        items = items, page = page, page_count = page_count, mode = mode, total = #books,
        categories = categories, counts = counts, category = self.category, reading_state = self.reading_state,
        source_mode = self.source_mode, warning = self.local_warning,
        load_error = load_error, progress_error = progress_error,
        empty_text = #books == 0 and (load_error and "书架读取失败" or "暂无收藏") or nil,
        empty_actions = #books == 0 and not load_error and {
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
