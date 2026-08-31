local assertx = require("assertions")
local Settings = require("legado.lib.settings")
local SettingsView = require("legado.ui.settings")
local Presenter = require("legado.ui.presenter")
local BookDetail = require("legado.ui.book_detail")
local App = require("legado.ui.app")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

-- Failed settings writes are atomic and recoverable, including adapter panics.
local persisted = { prefetch = 3 }
local write_mode = "ok"
local adapter = {
    read = function() return persisted end,
    write = function(value)
        if write_mode == "fail" then return false, "disk full" end
        if write_mode == "throw" then error("backend panic") end
        persisted = value
        return true
    end,
}
local settings = Settings.new(adapter)
write_mode = "fail"
local saved, save_error = settings:set("prefetch", 10)
equal(nil, saved, "failed write returns no new value")
equal("STORAGE_ERROR", save_error and save_error.code, "failed write is structured")
equal(3, settings:get("prefetch"), "failed write leaves in-memory settings unchanged")
write_mode = "throw"
saved, save_error = settings:set("prefetch", 0)
equal(nil, saved, "throwing adapter is contained")
equal("STORAGE_ERROR", save_error and save_error.code, "adapter panic is structured")
equal(3, settings:get("prefetch"), "adapter panic leaves the prior value intact")
write_mode = "ok"
equal(10, settings:set("prefetch", 10), "a later healthy write can recover")
equal(10, settings:get("prefetch"), "successful recovery commits the candidate")

write_mode = "throw"
local initialized, init_error = Settings.new(adapter)
equal("table", type(initialized), "constructor remains callable when initial persistence fails")
equal("STORAGE_ERROR", init_error and init_error.code, "constructor exposes its initialization error")
equal(init_error, initialized.init_error, "initialization error remains inspectable on the object")

-- The settings UI shows failure while retaining the old value after refresh.
write_mode = "ok"
settings = Settings.new(adapter)
local shown, closed = {}, {}
local function widget(kind) return { new = function(_, value) value.kind = kind; return value end } end
local presenter = Presenter.new({
    ui_manager = { show = function(_, value) shown[#shown + 1] = value end,
        close = function(_, value) closed[#closed + 1] = value end },
    menu = widget("menu"), input_dialog = widget("input"), info_message = widget("info"),
})
local settings_view = SettingsView.new({ settings = settings })
local settings_menu = presenter:show(settings_view)
settings_menu.item_table[3].callback()
local dialog = shown[#shown]
write_mode = "fail"
dialog.buttons[1][2].callback("0")
equal("info", shown[#shown].kind, "settings write failure is visible")
equal(10, settings_view:refresh().prefetch, "settings UI refresh retains the old value")

-- An immediate terminal return seals the Presenter completion gate.
local late_callback
local terminal_view = {
    kind = "book_detail", book = { name = "Book" }, alternatives = {}, info = {},
    addToShelf = function() end, removeFromShelf = function() end, startDownload = function() end,
    startReading = function(_, callback)
        late_callback = callback
        return nil, { code = "NETWORK_ERROR" }
    end,
}
local detail_menu = presenter:show(terminal_view)
local read_action
for _, item in ipairs(detail_menu.item_table) do if item.text == "开始阅读" then read_action = item end end
local shown_before = #shown
read_action.callback()
equal(shown_before + 1, #shown, "immediate structured reading failure is shown once")
late_callback(nil, { code = "NETWORK_ERROR" })
equal(shown_before + 1, #shown, "late callback after terminal structured error is dropped")

terminal_view.startReading = function(_, callback)
    late_callback = callback
    return "阅读功能尚未初始化"
end
detail_menu = presenter:show(terminal_view)
for _, item in ipairs(detail_menu.item_table) do if item.text == "开始阅读" then read_action = item end end
shown_before = #shown
read_action.callback()
late_callback(nil, { code = "NETWORK_ERROR" })
equal(shown_before + 1, #shown, "late callback after terminal error string is dropped")

-- BookDetail preserves every return value from its hook.
local sentinel = { code = "NETWORK_ERROR" }
local multi = BookDetail.new({ book = { id = "multi" }, reading_hook = function()
    return nil, sentinel, "tail"
end })
local first, second, third = multi:startReading()
equal(nil, first, "BookDetail preserves a nil first return")
equal(sentinel, second, "BookDetail preserves a structured second return")
equal("tail", third, "BookDetail preserves subsequent return values")

-- Catalog fetches belong to the detail's current reading intent.
local source = { id = "source" }
local source_id = Models.sourceId(source)
local pending, cancel_count, resume_calls, resume_callbacks = {}, 0, {}, {}
local service = { getChapters = function(_, _, book, callback)
    local handle = { cancel = function() cancel_count = cancel_count + 1; return true end }
    pending[#pending + 1] = { book = book, callback = callback, handle = handle }
    return handle
end }
local reader_session = {
    cache = { writeCatalog = function() return true end },
    resume = function(_, _, book, chapters, callback)
        resume_calls[#resume_calls + 1] = book.id
        resume_callbacks[#resume_callbacks + 1] = callback
        return { cancel = function() end }
    end,
    openOffline = function() return nil, { code = "STORAGE_ERROR" } end,
}
local storage = {
    listSources = function() return { source } end,
    replaceChapters = function() return true end,
}
local app = App.new({ storage = storage, book_service = service, reader_session = reader_session })
local book1 = { id = "book-1", source_id = source_id }
local book2 = { id = "book-2", source_id = source_id }

local closed_detail = app:createBookDetail(book1, { book1 })
closed_detail:startReading(function() error("closed completion must not run") end)
closed_detail:close()
equal(1, cancel_count, "closing detail cancels its pending catalog request")
pending[1].callback({ { uid = "late" } }, nil)
equal(0, #resume_calls, "catalog callback after close cannot open the reader")

local current_detail = app:createBookDetail(book1, { book1, book2 })
local delivered = 0
current_detail:startReading(function() delivered = delivered + 1 end)
current_detail:startReading(function() delivered = delivered + 1 end)
equal(2, cancel_count, "repeated reading cancels the prior request")
pending[2].callback({ { uid = "old" } }, nil)
equal(0, #resume_calls, "out-of-order old catalog response is dropped")
pending[3].callback({ { uid = "current" } }, nil)
equal(1, #resume_calls, "only the newest catalog response starts reading")
equal("book-1", resume_calls[1], "newest intent retains its book snapshot")
equal(nil, current_detail.reading_request, "completed catalog request handle is cleared")
pending[3].callback({ { uid = "duplicate" } }, nil)
equal(1, #resume_calls, "duplicate completion from one catalog request cannot resume twice")

current_detail:startReading(function() delivered = delivered + 1 end)
resume_callbacks[1]({}, nil)
equal(0, delivered, "completion from an older reading intent is dropped")
pending[4].callback({ { uid = "newest" } }, nil)
resume_callbacks[2]({}, nil)
equal(1, delivered, "completion from the newest reading intent is delivered")

local switching = app:createBookDetail(book1, { book1, book2 })
switching:startReading(function() end)
switching:switchSource(2)
equal(3, cancel_count, "source switch cancels the prior reading intent")
pending[5].callback({ { uid = "switched-late" } }, nil)
equal(2, #resume_calls, "source-switch stale callback cannot open the reader")

local synchronous_resumes = 0
local synchronous_app = App.new({ storage = storage,
    book_service = { getChapters = function(_, _, _, callback)
        callback({ { uid = "sync" } }, nil)
        return { cancel = function() error("completed handle must not be retained") end }
    end },
    reader_session = {
        cache = { writeCatalog = function() return true end },
        resume = function()
            synchronous_resumes = synchronous_resumes + 1
            return { cancel = function() end }
        end,
    },
})
local synchronous_detail = synchronous_app:createBookDetail(book1, { book1 })
synchronous_detail:startReading(function() end)
equal(1, synchronous_resumes, "synchronous catalog callback starts the current reading intent")
equal(nil, synchronous_detail.reading_request, "synchronous callback before handle assignment cannot retain a completed handle")

local throwing_callback, throwing_resumes = nil, 0
local throwing_app = App.new({ storage = storage,
    book_service = { getChapters = function(_, _, _, callback)
        throwing_callback = callback
        return { cancel = function() error("cancel panic") end }
    end },
    reader_session = {
        cache = { writeCatalog = function() return true end },
        resume = function() throwing_resumes = throwing_resumes + 1 end,
    },
})
local throwing_detail = throwing_app:createBookDetail(book1, { book1 })
throwing_detail:startReading(function() end)
local close_ok = pcall(throwing_detail.close, throwing_detail)
equal(true, close_ok, "throwing request cancellation cannot escape detail close")
throwing_callback({ { uid = "cancel-ignored" } }, nil)
equal(0, throwing_resumes, "late callback is dropped even when request cancellation throws or is ineffective")

return count
