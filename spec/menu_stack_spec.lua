require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(a, b, why) count = count + 1; A.equal(a, b, why) end
local stack = {}
local widget = { new = function(_, options) return options end }
local presenter = Presenter.new({ menu = widget, info_message = widget, input_dialog = widget,
    ui_manager = { show = function(_, value) stack[value] = true end,
        close = function(_, value) stack[value] = nil end } })
local destroyed = 0
local view = { kind = "bookshelf", close = function() destroyed = destroyed + 1 end,
    page = function() return { page = 1, page_count = 1, mode = "text",
        items = { { title = "One", book = { name = "One" } } } } end }
presenter.detail_factory = function(book)
    return { kind = "book_detail", book = book, info = { author = "Writer" }, alternatives = {},
        startReading = function(_, callback) callback({}, nil); return {} end }
end
local shelf = presenter:show(view)
shelf.item_table[1].callback()
shelf.close_callback()
eq(nil, stack[shelf], "selecting a book removes the shelf overlay from the native window stack")
eq(0, destroyed, "selection does not invalidate the launched child workflow")
local detail
for item in pairs(stack) do if item.title == "书籍详情" then detail = item end end
for _, item in ipairs(detail.item_table) do
    if item.text == "开始阅读" then item.callback(); detail.close_callback(); break end
end
eq(nil, next(stack), "opening a document leaves no plugin menu over the reader")

local callbacks
local loading = { kind = "book_detail", book = { name = "Loading" }, alternatives = {}, alive = true,
    loadInfo = function(self, callback) self.loading_info = true; callbacks = callback end }
local initial = presenter:show(loading)
loading.info, loading.loading_info = { author = "Writer" }, false
callbacks(loading.info)
eq(nil, stack[initial], "asynchronous detail refresh retires the loading menu")
local menus = 0
for _ in pairs(stack) do menus = menus + 1 end
eq(1, menus, "detail refresh leaves exactly one menu")

local BookDetail = require("legado.ui.book_detail")
local receive_info, finish_reading
local pending = BookDetail.new({ book = { id = "book", name = "Pending", source_id = "source" },
    source_lookup = function() return { id = "source" } end,
    service = { getBookInfo = function(_, _, _, callback)
        receive_info = callback
        return { cancel = function() end }
    end },
    reading_hook = function(_, _, _, callback)
        finish_reading = callback
        return { cancel = function() error("opening the reader must not cancel its request") end }
    end,
})
local pending_menu = presenter:show(pending)
for _, item in ipairs(pending_menu.item_table) do
    if item.text == "开始阅读" then item.callback(); pending_menu.close_callback(); break end
end
local function stack_size() local size = 0; for _ in pairs(stack) do size = size + 1 end; return size end
local before = stack_size()
receive_info({ id = "book", name = "Pending", source_id = "source", author = "Writer" })
eq(before, stack_size(), "late detail response does not reopen the menu over the reader")
eq(true, pending.alive, "detail dismissal leaves the downstream reading intent alive")
eq("Writer", pending.info.author, "late response can still update the model")
local result = {}
eq(result, finish_reading(result, nil), "downstream reading completion remains current")
return count
