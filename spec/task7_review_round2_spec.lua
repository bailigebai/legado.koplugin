local assertx = require("assertions")
local Fs = require("legado.lib.fs")
local CacheStore = require("legado.lib.cache_store")
local Cleaner = require("legado.lib.content_cleaner")
local Json = require("legado.lib.json_codec")
local ReaderAdapter = require("legado.lib.koreader_reader_ui")
local ReaderSession = require("legado.lib.reader_session")
local App = require("legado.ui.app")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function memory_fs()
    local files = {}
    local lfs = {
        attributes = function(path)
            if files[path] ~= nil then return { mode = "file", size = #files[path] } end
            return nil
        end,
        symlinkattributes = function(path) return nil end,
        mkdir = function() return true end,
    }
    local fs = Fs.new({
        lfs = lfs,
        open = function(path, mode)
            if mode == "rb" then
                if files[path] == nil then return nil, "missing" end
                local value = files[path]
                return { read = function() return value end, close = function() end, seek = function() return #value end }
            end
            local buffer = ""
            return { write = function(_, value) buffer = buffer .. value; files[path] = buffer; return true end, flush = function() end, close = function() end }
        end,
        rename = function(from, to) files[to], files[from] = files[from], nil; return true end,
        remove = function(path) files[path] = nil; return true end,
    })
    return fs, files, lfs
end

-- 1. The adapter must use the actual v2026.07.1 rolling and paging percentage
-- APIs and convert every show/ready/restore exception to a structured failure.
do
    local rolling_goto, paging_goto
    local rolling_reader = { rolling = {
        getLastPercent = function() return 0.375 end,
        onGotoPercent = function(_, value) rolling_goto = value end,
    } }
    local paging_reader = { paging = {
        current_page = 3, number_of_pages = 9,
        onGotoPercentage = function(_, value) paging_goto = value end,
    } }
    local reader_ui = { instance = rolling_reader }
    function reader_ui:showReader(_, _, _, _, ready) ready() end
    local adapter = ReaderAdapter.new({ ReaderUI = reader_ui })
    local rolling = assert(adapter:openDocument("rolling.html", { ready = function() end }))
    equal(0.375, rolling:getProgressFraction(), "rolling progress uses getLastPercent")
    assert(rolling:setProgressFraction(0.625))
    equal(62.5, rolling_goto, "rolling restore uses onGotoPercent with 0..100")

    reader_ui.instance = paging_reader
    local paging = assert(adapter:openDocument("paging.html", { ready = function() end }))
    equal(0.25, paging:getProgressFraction(), "paging progress uses current_page and number_of_pages")
    assert(paging:setProgressFraction(0.75))
    equal(0.75, paging_goto, "paging restore uses onGotoPercentage with 0..1")

    local broken = ReaderAdapter.new({ ReaderUI = { showReader = function() error("show failed") end } })
    local opened, open_error = broken:openDocument("broken.html", {})
    equal(nil, opened, "showReader exceptions do not escape the plugin")
    equal("STORAGE_ERROR", open_error.code, "showReader exception is structured")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "ready-rollback" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    assert(cache:writeBody("source-id", "book", chapters[2], "<p>two</p>"))
    local fail_restore = false
    local ui = { openDocument = function(_, _, callbacks)
        local document = {
            getProgressFraction = function() return 0.2 end,
            setProgressFraction = function() if fail_restore then error("restore failed") end return true end,
        }
        callbacks.ready(document)
        return document
    end }
    local diagnostics = {}
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui,
        diagnostics = function(kind, err) diagnostics[#diagnostics + 1] = { kind = kind, err = err } end })
    assert(session:open(source, book, chapters, 1))
    local old = session.active
    fail_restore = true
    local changed, restore_error = session:_open_cached(old, 2, 0.7)
    equal(nil, changed, "failed ready/restore does not report a successful open")
    equal("STORAGE_ERROR", restore_error.code, "restore exception is structured")
    equal(old, session.active, "failed candidate keeps the immutable old active snapshot")
    equal(1, session.active.index, "failed candidate never commits its chapter index")
    equal("reader", diagnostics[#diagnostics].kind, "ready failure is diagnosed")
    local public_changed, public_error = session:open(source, book, chapters, 2, { restore_fraction = 0.7 })
    equal(nil, public_changed, "public open also reports failed ready/restore")
    equal("STORAGE_ERROR", public_error.code, "public open restore failure is structured")
    equal(old, session.active, "public open preserves the old active snapshot on failure")
end

-- 2. Catalog refresh failures enter the strict offline path, including when
-- BookService is absent.  A disappearing body is skipped without networking.
do
    local offline_calls, resume_calls, network_calls = 0, 0, 0
    local session = {
        openOffline = function(_, source, book) offline_calls = offline_calls + 1; return "offline-document" end,
        resume = function() resume_calls = resume_calls + 1 end,
        cache = { writeCatalog = function() end },
    }
    local source = { id = "source", bookSourceUrl = "https://source.test" }
    local storage = {
        listSources = function() return { source } end,
        replaceChapters = function() end,
    }
    local book = { id = "book", source_id = Models.sourceId(source) }
    local without_service = App.new({ storage = storage, reader_session = session })
    equal("offline-document", without_service:startReading(book), "no-service reading opens strict offline cache")
    equal(1, offline_calls, "offline is attempted when BookService is absent")

    local with_failure = App.new({ storage = storage, reader_session = session, book_service = {
        getChapters = function(_, _, _, callback) network_calls = network_calls + 1; callback(nil, { code = "NETWORK_ERROR" }); return {} end,
    } })
    with_failure:startReading(book)
    equal(1, network_calls, "online catalog refresh is attempted once")
    equal(2, offline_calls, "catalog failure calls strict openOffline")
    equal(0, resume_calls, "catalog failure never resumes a cached list through the network-capable path")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "offline-fallback" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeCatalog("source-id", "book", { chapters = chapters }))
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    assert(cache:writeBody("source-id", "book", chapters[2], "<p>two</p>"))
    local original, reads_two = cache.readBody, 0
    cache.readBody = function(self, sid, bid, chapter)
        if chapter.uid == "two" then
            reads_two = reads_two + 1
            return nil, { code = "STORAGE_ERROR" }
        end
        return original(self, sid, bid, chapter)
    end
    local network_calls = 0
    local ui = { openDocument = function(_, _, callbacks) local doc = {}; callbacks.ready(doc); return doc end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui,
        service = { getContent = function() network_calls = network_calls + 1 end } })
    local document = assert(session:openOffline(source, book, 2))
    truthy(document, "offline search continues to an earlier readable body after a TOCTOU miss")
    equal(1, reads_two, "offline candidate body is read only once")
    equal(1, session.last_offline_chapter.index, "last readable marker is set only after successful open")
    equal(0, network_calls, "strict offline fallback performs zero BookService calls")
end

-- 3. Foreground navigation and speculative prefetch have independent
-- generations.  Cancellation invalidates callbacks before invoking handles.
do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "generation-cache" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
        { uid = "three", index = 3, title = "Three", url = "https://x/3", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    local calls, cancelled, opened = {}, 0, {}
    local service = { getContent = function(_, _, _, chapter, callback)
        local call = { chapter = chapter, callback = callback }
        calls[#calls + 1] = call
        call.handle = { cancel = function() cancelled = cancelled + 1; return true end }
        return call.handle
    end }
    local ui = { openDocument = function(_, path, callbacks)
        local document = { getProgressFraction = function() return 0 end }
        callbacks.ready(document)
        opened[#opened + 1] = { path = path, callbacks = callbacks, document = document }
        return document
    end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui,
        service = service, settings = { get = function() return 1 end } })
    assert(session:open(source, book, chapters, 1))
    equal(1, #calls, "initial open starts one prefetch generation")
    opened[1].callbacks.end_of_book(opened[1].document)
    equal(2, #calls, "foreground navigation starts a separate request")
    truthy(cancelled >= 1, "foreground navigation cancels the old prefetch handle")
    calls[1].callback({ content = "<p>stale-prefetch</p>" })
    equal(nil, cache:readBody("source-id", "book", chapters[2]), "cancelled prefetch callback cannot write cache")
    equal(2, #calls, "cancelled prefetch callback cannot continue its chain")
    session:close()
    local cancelled_at_close = cancelled
    calls[2].callback({ content = "<p>stale-foreground</p>" })
    equal(nil, cache:readBody("source-id", "book", chapters[2]), "closed foreground callback cannot write or open")
    truthy(cancelled_at_close >= 2, "session close cancels foreground and prefetch handles")
    equal(1, #opened, "late callbacks after close never open a document")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "retry-cache" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    local callbacks, opened, diagnostics = {}, {}, {}
    local service = { getContent = function(_, _, _, _, callback) callbacks[#callbacks + 1] = callback; return { cancel = function() end } end }
    local fail_open = false
    local ui = { openDocument = function(_, _, ready)
        if fail_open then return nil, { code = "STORAGE_ERROR", message = "open failed" } end
        local document = {}; ready.ready(document); opened[#opened + 1] = { callbacks = ready, document = document }; return document
    end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui,
        service = service, settings = { get = function() return 0 end }, diagnostics = function(kind, err) diagnostics[#diagnostics + 1] = { kind = kind, err = err } end })
    assert(session:open(source, book, chapters, 1))
    opened[1].callbacks.end_of_book(opened[1].document)
    callbacks[1](nil, { code = "NETWORK_ERROR" })
    equal(false, session.active.end_handled, "foreground fetch failure releases the end guard")
    opened[1].callbacks.end_of_book(opened[1].document)
    equal(2, #callbacks, "released end guard permits a retry")
    fail_open = true
    callbacks[2]({ content = "<p>two</p>" })
    equal(false, session.active.end_handled, "generated HTML open failure also releases the end guard")
    equal("read", diagnostics[#diagnostics].kind, "foreground open failure is diagnosed")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "synchronous-callbacks" })
    local source, book = { id = "source" }, { id = "book", source_id = "source-id" }
    local chapters = { { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" } }
    local ui = { openDocument = function(_, _, callbacks) local document = {}; callbacks.ready(document); return document end }
    local service = { getContent = function(_, _, _, _, callback)
        callback({ content = "<p>inline</p>" })
        return { cancel = function() error("completed handle must not be retained") end }
    end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui, service = service,
        settings = { get = function() return 0 end } })
    assert(session:open(source, book, chapters, 1))
    equal(1, session.active.index, "synchronous foreground callback opens the requested chapter")
    equal(0, #session.foreground_handles, "completed synchronous foreground handle is never retained")
    session:close()
end

-- 4. replaceRegex accepts only a bounded dense array of safe Lua patterns;
-- malformed source JSON must be an ordinary structured rule error.
do
    local bad_values = {
        7,
        { [1] = "ad", [3] = "gap" },
        { [1] = "ad", extra = "mixed" },
        { "%f[%a]" },
        { "(" },
    }
    for _, value in ipairs(bad_values) do
        local ok, cleaned, err = pcall(Cleaner.normalize, "<p>ad text</p>", { replaceRegex = value })
        truthy(ok, "invalid replaceRegex shape never raises a Lua exception")
        equal(nil, cleaned, "invalid replaceRegex is rejected")
        truthy(err and (err.code == "INVALID_INPUT" or err.code == "UNSUPPORTED_RULE" or err.code == "PARSE_ERROR"), "replaceRegex failure is structured")
    end
    equal("<p> text</p>", assert(Cleaner.normalize("<p>ad text</p>", { replaceRegex = { "ad" } })), "dense safe replaceRegex remains supported")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "regex-flow" })
    local source, book = { id = "source", replaceRegex = 9 }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    local pending, opened, diagnostics = {}, {}, {}
    local service = { getContent = function(_, _, _, _, callback) pending[#pending + 1] = callback; return { cancel = function() end } end }
    local ui = { openDocument = function(_, _, callbacks) local doc = {}; callbacks.ready(doc); opened[#opened + 1] = { callbacks = callbacks, document = doc }; return doc end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui, service = service,
        settings = { get = function() return 0 end }, diagnostics = function(kind, err) diagnostics[#diagnostics + 1] = { kind = kind, err = err } end })
    assert(session:open(source, book, chapters, 1))
    opened[1].callbacks.end_of_book(opened[1].document)
    pending[1]({ content = "<p>two</p>" })
    equal(false, session.active.end_handled, "foreground replaceRegex failure releases navigation guard")
    equal("read", diagnostics[#diagnostics].kind, "foreground replaceRegex failure is returned through diagnostics")
    equal("INVALID_INPUT", diagnostics[#diagnostics].err.code, "foreground replaceRegex diagnostic is structured")
end

do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "prefetch-regex" })
    local source, book = { id = "source", replaceRegex = { [1] = "ad", [3] = "gap" } }, { id = "book", source_id = "source-id" }
    local chapters = {
        { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" },
        { uid = "two", index = 2, title = "Two", url = "https://x/2", source_id = "source-id", book_id = "book" },
    }
    assert(cache:writeBody("source-id", "book", chapters[1], "<p>one</p>"))
    local pending, diagnostics = {}, {}
    local service = { getContent = function(_, _, _, _, callback) pending[#pending + 1] = callback; return { cancel = function() end } end }
    local ui = { openDocument = function(_, _, callbacks) local document = {}; callbacks.ready(document); return document end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = ui, service = service,
        settings = { get = function() return 1 end }, diagnostics = function(kind, err) diagnostics[#diagnostics + 1] = { kind = kind, err = err } end })
    assert(session:open(source, book, chapters, 1))
    pending[1]({ content = "<p>two</p>" })
    equal("prefetch", diagnostics[#diagnostics].kind, "prefetch replaceRegex failure is recorded silently")
    equal("INVALID_INPUT", diagnostics[#diagnostics].err.code, "prefetch replaceRegex diagnostic is structured")
end

-- 5. Cache envelopes use standards-compliant JSON for every C0 control and
-- validate the completed envelope before replacing a known-good cache file.
do
    local encoded = Json.encode({ value = "a\0\b\f\n\r\tb" })
    truthy(encoded:find("\\u0000", 1, true), "JSON encoder escapes NUL")
    truthy(encoded:find("\\b", 1, true), "JSON encoder escapes backspace")
    truthy(encoded:find("\\f", 1, true), "JSON encoder escapes form feed")
    equal("a\0\b\f\n\r\tb", Json.decode(encoded).value, "all escaped controls round trip")

    local fs, files = memory_fs()
    local chapter = { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" }
    local cache = CacheStore.new({ fs = fs, root = "validated-envelope" })
    local path = assert(cache:writeBody("source-id", "book", chapter, "<p>old</p>"))
    local old_envelope = files[path]
    local broken = CacheStore.new({ fs = fs, root = "validated-envelope", encoder = function() return '{"content":"bad\0json"}' end })
    local saved, save_error = broken:writeBody("source-id", "book", chapter, "<p>new</p>")
    equal(nil, saved, "invalid generated envelope is rejected before replacement")
    equal("STORAGE_ERROR", save_error.code, "envelope self-validation failure is structured")
    equal(old_envelope, files[path], "failed self-validation preserves the previous cache file")
    equal("<p>old</p>", assert(cache:readBody("source-id", "book", chapter)), "preserved previous cache remains readable")
end

-- 6. A cached catalog is a bounded JSON array with ordered, uniquely-owned
-- chapters.  Schema corruption is quarantined without touching body entries.
do
    local fs = memory_fs()
    local cache = CacheStore.new({ fs = fs, root = "catalog-schema", max_catalog_chapters = 2 })
    local function chapter(uid, index)
        return { uid = uid, index = index, title = "Chapter " .. uid, url = "https://x/" .. uid, source_id = "source-id", book_id = "book" }
    end
    local body_chapter = chapter("body", 1)
    assert(cache:writeBody("source-id", "book", body_chapter, "<p>body</p>"))
    local invalid_catalogs = {
        { chapters = { ["1"] = chapter("one", 1) } },
        { chapters = { chapter("one", 1), chapter("one", 2) } },
        { chapters = { chapter("one", 2) } },
        { chapters = { chapter("one", 1), chapter("two", 2), chapter("three", 3) } },
        { chapters = { (function() local value = chapter("one", 1); value.source_id = "other"; return value end)() } },
        { chapters = { (function() local value = chapter("one", 1); value.title = string.rep("x", 1025); return value end)() } },
    }
    for index, catalog in ipairs(invalid_catalogs) do
        assert(cache:_write("source-id", "book", "catalog", nil, Json.encode(catalog)))
        local loaded, err = cache:readCatalog("source-id", "book")
        equal(nil, loaded, "invalid catalog schema is rejected (case " .. index .. ")")
        equal("STORAGE_ERROR", err.code, "invalid catalog schema is structured (case " .. index .. ")")
        equal("<p>body</p>", assert(cache:readBody("source-id", "book", body_chapter)), "catalog quarantine leaves chapter body isolated")
    end
    local valid = { chapters = { chapter("one", 1), chapter("two", 2) } }
    assert(cache:writeCatalog("source-id", "book", valid))
    equal(2, #assert(cache:readCatalog("source-id", "book")).chapters, "valid dense ordered catalog survives validation")
end

-- 7. Path validation covers every existing root ancestor, the final leaf,
-- Windows reparse points, canonical containment, and both replace boundaries.
do
    local function rejected(root, dangerous)
        local fs, _, lfs = memory_fs()
        lfs.symlinkattributes = function(path)
            if path == dangerous then return { mode = "link" } end
            return nil
        end
        local cache = CacheStore.new({ fs = fs, root = root })
        local path, err = cache:path("source-id", "book", "chapters", { uid = "one" })
        equal(nil, path, "linked cache component is rejected: " .. dangerous)
        equal("INVALID_INPUT", err.code, "linked cache component rejection is structured")
    end
    rejected("parent/cache", "parent")
    rejected("leaf-root", "leaf-root/source-id/book/chapters/one.body")

    local fs, _, lfs = memory_fs()
    lfs.symlinkattributes = function(path)
        if path == "junction-root/source-id" then return { mode = "directory", reparse_tag = 0xA0000003 } end
        return nil
    end
    local junction = CacheStore.new({ fs = fs, root = "junction-root" })
    local escaped, junction_error = junction:path("source-id", "book", "chapters", { uid = "one" })
    equal(nil, escaped, "Windows junction/reparse components are rejected")
    equal("INVALID_INPUT", junction_error.code, "Windows reparse rejection is structured")

    local canonical_fs = memory_fs()
    canonical_fs.canonicalize = function(_, path)
        if path:find("source%-id", 1) then return "D:/outside/one.body" end
        return path:gsub("\\", "/")
    end
    local canonical = CacheStore.new({ fs = canonical_fs, root = "C:\\cache" })
    local outside, outside_error = canonical:path("source-id", "book", "chapters", { uid = "one" })
    equal(nil, outside, "canonical target outside canonical root is rejected")
    equal("INVALID_INPUT", outside_error.code, "canonical containment rejection is structured")

    local normal_fs = memory_fs()
    local windows = CacheStore.new({ fs = normal_fs, root = "C:\\plugin\\cache" })
    truthy(assert(windows:path("source-id", "book", "chapters", { uid = "one" })):gsub("\\", "/"):find("C:/plugin/cache", 1, true), "ordinary Windows plugin root remains usable")
    local unc = CacheStore.new({ fs = normal_fs, root = "\\\\server\\share\\plugin-cache" })
    truthy(unc:path("source-id", "book", "chapters", { uid = "one" }), "ordinary UNC plugin root remains usable")
end

do
    local fs = memory_fs()
    local validations = {}
    local original_atomic = fs.atomicWrite
    fs.atomicWrite = function(self, path, data, options)
        truthy(type(options) == "table" and type(options.validate) == "function", "cache write supplies an atomic path validator")
        local ok, err = options.validate(path, "before_replace")
        if not ok then return nil, err end
        local written, write_error = original_atomic(self, path, data)
        if not written then return nil, write_error end
        ok, err = options.validate(path, "after_replace")
        if not ok then return nil, err end
        validations[#validations + 1] = path
        return true
    end
    local cache = CacheStore.new({ fs = fs, root = "toctou-root" })
    local chapter = { uid = "one", index = 1, title = "One", url = "https://x/1", source_id = "source-id", book_id = "book" }
    assert(cache:writeBody("source-id", "book", chapter, "<p>body</p>"))
    equal(1, #validations, "cache path is revalidated immediately before and after atomic replacement")
end

return count
