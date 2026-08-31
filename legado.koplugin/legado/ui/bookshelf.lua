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
        navigation = Navigation.new({ count = 0, columns = 1 }),
    }, Shelf)
end

function Shelf:add(book) return self.storage:createBook(book) end
function Shelf:remove(book_id) return self.storage:deleteBook(book_id) end

function Shelf:page(page, mode)
    local books = self.storage:listShelf() or {}
    page = math.max(1, math.floor(tonumber(page) or 1))
    mode = mode == "cover" and self.covers_enabled and "cover" or "text"
    local page_count = math.max(1, math.ceil(#books / self.page_size))
    page = math.min(page, page_count)
    local items = {}
    local first = (page - 1) * self.page_size + 1
    local last = math.min(#books, first + self.page_size - 1)
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
            self.cover_loader(book, function(image)
                item.cover = image
                item.cover_pending = false
                if not image then item.cover_text = "封面不可用" end
            end)
        end
    end
    self.navigation.columns = mode == "cover" and 3 or 1
    self.navigation:setCount(#items)
    return {
        items = items, page = page, page_count = page_count, mode = mode,
        empty_text = #books == 0 and "书架为空" or nil,
    }
end

function Shelf:onKey(key) return self.navigation:onKey(key) end
function Shelf:focusedIndex() return self.navigation:index() end

return Shelf
