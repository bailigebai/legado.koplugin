local assertx = require("assertions")
local Fs = require("legado.lib.fs")
local CacheStore = require("legado.lib.cache_store")
local Cleaner = require("legado.lib.content_cleaner")
local ReaderSession = require("legado.lib.reader_session")
local BookDetail = require("legado.ui.book_detail")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local files = {}
local lfs = {
    attributes = function(path) return files[path] and { mode = "file", size = #files[path] } or nil end,
    mkdir = function() return true end,
}
local fs = Fs.new({ lfs = lfs, open = function(path, mode)
    if mode == "rb" then
        if not files[path] then return nil, "missing" end
        local value = files[path]
        return { read = function() return value end, close = function() end, seek = function() return #value end }
    end
    local buffer = ""
    return { write = function(_, value) buffer = buffer .. value; files[path] = buffer; return true end, flush = function() end, close = function() end }
end, rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end, remove = function(path) files[path] = nil; return true end })

do
    local cache = CacheStore.new({ fs = fs, root = "cache-root" })
    local source, book, chapter = "source-abc", "book-def", { uid = "chapter-ghi", index = 1, title = "One", url = "https://example.test/one", source_id = "source-abc", book_id = "book-def" }
    local body_path = assert(cache:writeBody(source, book, chapter, "<p>Hello</p>"))
    truthy(body_path:match("source%-abc"), "opaque source id remains visible only as a path segment")
    equal("<p>Hello</p>", assert(cache:readBody(source, book, chapter)), "body cache round trips through an atomic file")
    local escaped, err = cache:writeBody("../evil", book, chapter, "x")
    equal(nil, escaped, "path traversal source ids are rejected")
    equal("INVALID_INPUT", err.code, "traversal rejection is structured")
    assert(cache:writeCatalog(source, book, { chapters = { chapter } }))
    equal(1, #assert(cache:readCatalog(source, book)).chapters, "catalog cache round trips")
    local corrupt_path = assert(cache:path(source, book, "chapters", chapter, ".body"))
    files[corrupt_path] = "bad"
    local corrupt, corrupt_error = cache:readBody(source, book, chapter)
    equal(nil, corrupt, "one corrupt chapter is rejected without touching the catalog")
    equal("STORAGE_ERROR", corrupt_error.code, "corrupt cache has structured diagnostics")
    truthy(cache:readCatalog(source, book), "catalog survives isolated chapter corruption")
    assert(cache:writeBody(source, book, chapter, "<p>fixed</p>"))
    files[corrupt_path] = "{bad"
    local invalid_manifest, manifest_error = cache:readBody(source, book, chapter)
    equal(nil, invalid_manifest, "malformed cache manifests are rejected rather than thrown")
    equal("STORAGE_ERROR", manifest_error.code, "malformed manifests return structured errors")
    assert(cache:writeCover(source, book, "\137PNG\r\n\26\n\255"))
    equal("\137PNG\r\n\26\n\255", assert(cache:readCover(source, book)), "binary cover bytes remain cacheable")
end

do
    local cache = CacheStore.new({ fs = fs, root = "lifecycle-order" })
    local source, book = { id = "s" }, { id = "life-book", source_id = "source-s" }
    local chapters = { { uid = "life-1", index = 1, title = "One", url = "https://s/1", source_id = "source-s", book_id = book.id }, { uid = "life-2", index = 2, title = "Two", url = "https://s/2", source_id = "source-s", book_id = book.id } }
    assert(cache:writeBody("source-s", book.id, chapters[1], "<p>1</p>")); assert(cache:writeBody("source-s", book.id, chapters[2], "<p>2</p>"))
    local saved, previous = {}, nil
    local ui = { openDocument = function(_, _, callbacks)
        if previous then callbacks.close(previous) end
        local doc = { getProgressFraction = function() return 0.4 end }; previous = doc; return doc
    end }
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function(_, p) saved[#saved + 1] = p end }, ui = ui })
    assert(session:open(source, book, chapters, 1)); assert(session:_open_cached(session.active, 2, nil))
    equal("life-1", saved[1].chapter_uid, "synchronous ShowingReader close saves the immutable old chapter")
end

do
    -- A cached catalog must never turn an offline open into a network request,
    -- even when its chapter body disappears between selection and open.
    local cache = CacheStore.new({ fs = fs, root = "strict-offline" })
    local source, book = { id = "s" }, { id = "offline-book", source_id = "source-s" }
    local chapter = { uid = "offline-chapter", index = 1, title = "Only", url = "https://s.test/1", source_id = "source-s", book_id = book.id }
    assert(cache:writeCatalog("source-s", book.id, { chapters = { chapter } }))
    local calls = 0
    local session = ReaderSession.new({ cache = cache, storage = { putProgress = function() end }, ui = { openDocument = function() return {} end }, service = { getContent = function() calls = calls + 1 end } })
    local opened, err = session:openOffline(source, book, 1)
    equal(nil, opened, "offline open rejects a catalog whose body vanished")
    equal("STORAGE_ERROR", err.code, "offline miss is structured")
    equal(0, calls, "offline open makes zero network calls")
end

do
    local unsafe = Cleaner.normalize('<a href="jav&#x61;\nscript:alert(1)">x</a><img src="data:image/svg+xml;base64,PHN2Zz4=">')
    equal("<a>x</a><img>", unsafe, "decoded and whitespace-obfuscated unsafe schemes are removed")
    local invalid, err = Cleaner.normalize("<p>x</p>", { replaceRegex = { "@js:evil" } })
    equal(nil, invalid, "executable replaceRegex is rejected")
    equal("UNSUPPORTED_RULE", err.code, "invalid replaceRegex is structured")
end

do
    local received
    local detail = BookDetail.new({ book = { id = "book", source_id = "source" }, reading_hook = function(_, chapters) received = chapters end })
    detail.catalog = { items = { { chapter = { uid = "chapter", index = 1 } } } }
    detail:startReading()
    equal("chapter", received[1].uid, "detail forwards its loaded catalog to the reader hook")
end

do
    local cache = CacheStore.new({ fs = fs, root = "priority-cache" })
    local source, book = { id = "s", bookSourceUrl = "https://s.test" }, { id = "priority-book", source_id = "source-s" }
    local chapters = {
        { uid = "priority-1", index = 1, title = "One", url = "https://s.test/1", source_id = "source-s", book_id = book.id },
        { uid = "priority-2", index = 2, title = "Two", url = "https://s.test/2", source_id = "source-s", book_id = book.id },
    }
    assert(cache:writeBody("source-s", book.id, chapters[1], "<p>One</p>"))
    local pending, cancelled, opened = {}, 0, {}
    local service = { getContent = function(_, _, _, chapter, callback)
        pending[#pending + 1] = callback
        return { cancel = function() cancelled = cancelled + 1; return true end }
    end }
    local ui = { openDocument = function(_, path, callbacks)
        local document = { getProgressFraction = function() return 0 end }
        opened[#opened + 1] = { callbacks = callbacks, document = document, path = path }
        return document
    end }
    local storage = { putProgress = function(_, value) return value end }
    local session = ReaderSession.new({ cache = cache, storage = storage, ui = ui, service = service, settings = { get = function() return 1 end } })
    assert(session:open(source, book, chapters, 1))
    equal(1, #pending, "opening schedules one low-priority prefetch")
    opened[1].callbacks.end_of_book(opened[1].document)
    equal(1, cancelled, "user next chapter cancels competing low-priority prefetch")
    equal(2, #pending, "user navigation starts its own fetch after cancellation")
    pending[2]({ content = "<p>Two</p>" }, nil)
    equal(2, #opened, "next chapter opens when the user-priority request completes")
    session:close()
    pending[2]({ content = "<p>late</p>" }, nil)
    equal(2, #opened, "late callbacks after session close cannot reopen a document")
end

do
    local normalized = assert(Cleaner.normalize('<style>x</style><h1>Title</h1><h1>Title</h1><p onclick="bad">Text <a href="javascript:bad()">bad</a><img src="https://a.test/x.png"></p><script>bad()</script>', { title = "Title" }))
    equal(nil, normalized:find("<script", 1, true), "scripts are removed")
    equal(nil, normalized:find("onclick", 1, true), "event attributes are removed")
    equal(nil, normalized:find("javascript:", 1, true), "unsafe link schemes are removed")
    equal(1, select(2, normalized:gsub("<h1>", "")), "duplicate headings are removed")
    equal(1, select(2, normalized:gsub("Title", "")), "removed duplicate headings leave no orphan heading text")
    truthy(normalized:find("<p>Text", 1, true), "semantic paragraphs remain")
    equal(nil, normalized:find("font%-", 1), "cleaned content never specifies fonts")
    local entities = assert(Cleaner.normalize("<p>A &amp; B & C</p>"))
    truthy(entities:find("A &amp; B &amp; C", 1, true), "valid entities remain valid while raw ampersands are escaped")
end

do
    local cache = CacheStore.new({ fs = fs, root = "session-cache" })
    local saved, opened, restored, regular_end = {}, {}, nil, 0
    local storage = { putProgress = function(_, value) saved[#saved + 1] = value; return value end, getProgress = function() return { chapter_uid = "chapter-2", chapter_index = 2, fraction = 0.6 } end }
    local ui = {
        openDocument = function(_, path, callbacks)
            local document = { is_legado_document = true, setProgressFraction = function(_, value) restored = value end, getProgressFraction = function() return 0.25 end }
            opened[#opened + 1] = { path = path, callbacks = callbacks, document = document }
            return document
        end,
        endOfBook = function() regular_end = regular_end + 1 end,
    }
    local source, book = { id = "s", bookSourceUrl = "https://s.test" }, { id = "b", source_id = "source-s", name = "Book" }
    local chapters = {
        { uid = "chapter-1", index = 1, title = "One", url = "https://s.test/1", source_id = "source-s", book_id = "b" },
        { uid = "chapter-2", index = 2, title = "Two", url = "https://s.test/2", source_id = "source-s", book_id = "b" },
    }
    assert(cache:writeBody("source-s", "b", chapters[1], "<p>One</p>"))
    assert(cache:writeBody("source-s", "b", chapters[2], "<p>Two</p>"))
    local session = ReaderSession.new({ cache = cache, storage = storage, ui = ui, settings = { get = function(_, key) return key == "prefetch" and 99 or nil end } })
    assert(session:open(source, book, chapters, 1))
    opened[1].callbacks.ready(opened[1].document)
    equal(nil, restored, "fresh explicitly selected chapter does not restore a different saved location")
    opened[1].callbacks.flush(opened[1].document)
    equal("chapter-1", saved[1].chapter_uid, "only plugin document flush persists chapter progress")
    opened[1].callbacks.end_of_book(opened[1].document)
    opened[1].callbacks.end_of_book(opened[1].document)
    equal(2, #opened, "duplicate end event advances only once")
    equal(0, regular_end, "non-final chapter uses plugin navigation")
    local saved_before_foreign = #saved
    local foreign = { is_legado_document = false, getProgressFraction = function() return 0.9 end }
    opened[1].callbacks.flush(foreign)
    equal(saved_before_foreign, #saved, "foreign documents never alter plugin progress")
    opened[2].callbacks.end_of_book(opened[2].document)
    equal(1, regular_end, "last chapter delegates ordinary KOReader completion")

    local inserted = { chapters[1], { uid = "new", index = 2, title = "Interlude", url = "https://s.test/x" }, chapters[2] }
    equal(3, session:recoverIndex(inserted, { chapter_uid = "missing", chapter_title = "Two", chapter_index = 2 }), "title recovery selects nearest catalog insertion")
    equal(3, session:recoverIndex(inserted, { chapter_uid = "chapter-2", chapter_index = 2 }), "stable UID recovery wins over changed index")
end

return count
