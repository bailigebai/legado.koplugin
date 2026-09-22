local assertx = require("assertions")
local Fs = require("legado.lib.fs")
local CacheStore = require("legado.lib.cache_store")
local ReaderAdapter = require("legado.lib.koreader_reader_ui")
local ReaderSession = require("legado.lib.reader_session")
local Cleaner = require("legado.lib.content_cleaner")
local App = require("legado.ui.app")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function memory_fs()
    local files = {}
    local lfs = {
        attributes = function(path) return files[path] and { mode = "file", size = #files[path] } or nil end,
        symlinkattributes = function() return nil end,
        mkdir = function() return true end,
    }
    local fs = Fs.new({ lfs = lfs, secureTemp = function(target, purpose)
        local candidate = target .. "." .. purpose .. "-memory"
        if files[candidate] then return nil, "exists" end
        local buffer = ""
        return candidate, { write = function(_, data) buffer = buffer .. data; files[candidate] = buffer; return true end, flush = function() return true end, close = function() return true end }
    end, open = function(path, mode)
        if mode == "rb" then
            if files[path] == nil then return nil, "missing" end
            local value = files[path]
            return { read = function() return value end, close = function() end, seek = function() return #value end }
        end
        local buffer = ""
        return { write = function(_, data) buffer = buffer .. data; files[path] = buffer; return true end, flush = function() end, close = function() end }
    end, rename = function(from, to) files[to], files[from] = files[from], nil; return true end,
        remove = function(path) files[path] = nil; return true end })
    return fs, files, lfs
end

-- 1. KOReader invokes after_open as reader:after_open_callback(), passing the
-- newly-ready reader even while the class singleton still points elsewhere.
do
    local stale = { rolling = { getLastPercent = function() return 0.1 end } }
    local paging_goto
    local ready_reader = { paging = {
        current_page = 2, number_of_pages = 10,
        getLastPercent = function() return 0.42 end,
        onGotoPercentage = function(_, fraction) paging_goto = fraction; return true end,
    } }
    local reader_ui = { instance = stale }
    function reader_ui:showReader(_, _, _, _, after_open) after_open(ready_reader) end
    local ready_document
    local document = assert(ReaderAdapter.new({ ReaderUI = reader_ui }):openDocument("chapter.html", {
        ready = function(value) ready_document = value end,
    }))
    equal(document, ready_document, "official after_open reader argument becomes the ready document")
    equal(0.42, document:getProgressFraction(), "paging getLastPercent is preferred when available")
    assert(document:setProgressFraction(0.7))
    equal(0.7, paging_goto, "paging restore keeps the official 0..1 API")

    local fallback_reader = { paging = { current_page = 3, number_of_pages = 9, onGotoPercentage = function() return true end } }
    function reader_ui:showReader(_, _, _, _, after_open) after_open(fallback_reader) end
    local fallback = assert(ReaderAdapter.new({ ReaderUI = reader_ui }):openDocument("fallback.html", { ready = function() end }))
    equal(0.25, fallback:getProgressFraction(), "paging current_page/number_of_pages fallback matches KOReader")
end

-- 2. Without BookService, even an explicitly supplied catalog is only a hint:
-- the strict offline cache path remains the sole allowed reader entry.
do
    local source = { id = "source", bookSourceUrl = "https://source.test" }
    local book = { id = "book", source_id = Models.sourceId(source) }
    local offline, resumed = 0, 0
    local session = {
        openOffline = function() offline = offline + 1; return "offline" end,
        resume = function() resumed = resumed + 1; return "resume" end,
    }
    local app = App.new({ storage = { listSources = function() return { source } end }, reader_session = session })
    equal("offline", app:startReading(book, { { uid = "one" } }), "service-less explicit catalog opens strict offline cache")
    equal(1, offline, "service-less reading invokes openOffline exactly once")
    equal(0, resumed, "service-less reading never invokes resume")

    local online = App.new({ storage = { listSources = function() return { source } end }, reader_session = session,
        book_service = { getChapters = function() error("explicit chapters must avoid catalog network") end } })
    equal("resume", online:startReading(book, { { uid = "one" } }), "online explicit catalog may resume directly")
    equal(1, resumed, "online explicit catalog invokes resume once")
end

-- 3. Every foreground start failure follows the same cleanup/diagnostic path
-- and releases the end guard synchronously so the user can retry.
do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "missing-service" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    local opened, diagnostics = {}, {}
    local ui = { openDocument = function(_, _, callbacks) local doc = {}; callbacks.ready(doc); opened[#opened + 1] = { doc = doc, callbacks = callbacks }; return doc end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() return true end }, ui = ui,
        settings = { get = function() return 0 end }, diagnostics = function(kind, err) diagnostics[#diagnostics + 1] = { kind = kind, err = err } end })
    assert(session:open(source, book, chapters, 1))
    opened[1].callbacks.end_of_book(opened[1].doc)
    equal(false, session.active.end_handled, "missing BookService releases the foreground end guard")
    equal("read", diagnostics[1].kind, "missing BookService is diagnosed as foreground read failure")
    equal("STORAGE_ERROR", diagnostics[1].err.code, "missing BookService failure is structured")
    opened[1].callbacks.end_of_book(opened[1].doc)
    equal(2, #diagnostics, "missing BookService path remains retryable")

    session.service = { getContent = function() error("start failed") end }
    opened[1].callbacks.end_of_book(opened[1].doc)
    equal(false, session.active.end_handled, "throwing request start also releases the end guard")
    equal("read", diagnostics[#diagnostics].kind, "throwing request start is diagnosed")
end

-- 4. Explicit false/true are source data, not absence; nil alone selects the
-- alternate key or empty default.
do
    for _, options in ipairs({ { replaceRegex = false }, { replaceRegex = true }, { replace_regex = false } }) do
        local ok, cleaned, err = pcall(Cleaner.normalize, "<p>body</p>", options)
        truthy(ok, "boolean replaceRegex never raises")
        equal(nil, cleaned, "boolean replaceRegex is rejected rather than treated as absent")
        equal("INVALID_INPUT", err.code, "boolean replaceRegex rejection is structured")
    end
    equal("<p>body</p>", assert(Cleaner.normalize("<p>body</p>", { replaceRegex = nil })), "nil replaceRegex keeps the empty default")
end

-- 5. Post-replacement validation is transactional: restore the exact old
-- bytes when present, otherwise remove the rejected new target.
do
    local fs, files = memory_fs()
    files["atomic/target"] = "old"
    local saved, err = fs:atomicWrite("atomic/target", "new", { validate = function(_, phase)
        if phase == "after_replace" then
            equal("old", files["atomic/target.backup-memory"], "old backup remains available through post-validation")
            return nil, { code = "INVALID_INPUT", message = "race" }
        end
        return true
    end })
    equal(nil, saved, "post-validation failure rejects replacement")
    truthy(err, "post-validation failure returns an error")
    equal("old", files["atomic/target"], "direct rename restores previous target bytes")

    local fresh, fresh_files = memory_fs()
    local created, created_error = fresh:atomicWrite("atomic/new-target", "new", { validate = function(_, phase)
        if phase == "after_replace" then return nil, { code = "INVALID_INPUT", message = "race" } end
        return true
    end })
    equal(nil, created, "post-validation failure rejects newly-created target")
    truthy(created_error, "new-target validation failure is returned")
    equal(nil, fresh_files["atomic/new-target"], "rejected new target is removed when no old file existed")
end


do
    local files = {}
    local fs
    fs = Fs.new({
        lfs = { attributes = function(path) return files[path] and { mode = "file", size = #files[path] } or nil end, mkdir = function() return true end },
        secureTemp = function(target, purpose)
            local candidate, buffer = target .. "." .. purpose .. "-secure", ""
            return candidate, { write = function(_, data) buffer = buffer .. data; files[candidate] = buffer; return true end, flush = function() return true end, close = function() return true end }
        end,
        open = function(path, mode)
            if mode == "rb" and files[path] then local value = files[path]; return { read = function() return value end, close = function() end } end
            return nil, "missing"
        end,
        rename = function(from, to) files[to], files[from] = files[from], nil; return true end,
        remove = function(path) if path == "atomic/remove-fails" then return nil, "remove denied" end; files[path] = nil; return true end,
    })
    local saved, err = fs:atomicWrite("atomic/remove-fails", "new", { validate = function(_, phase)
        if phase == "after_replace" then return nil, { code = "INVALID_INPUT", message = "race" } end
        return true
    end })
    equal(nil, saved, "failed cleanup never reports atomic success")
    equal("STORAGE_ERROR", err.code, "new-target cleanup failure is a compound storage error")
    equal("remove denied", err.details.remove_cause, "new-target cleanup failure retains removal cause")
end

return count
