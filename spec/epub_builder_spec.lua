local assertx = require("assertions")
local EpubBuilder = require("legado.lib.epub_builder")
local ArchiveWriter = require("legado.lib.archive_writer")
local Fs = require("legado.lib.fs")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local book = {
    id = "book-safe-id", source_id = "source-safe-id", source_name = "测试 & 书源",
    name = "甲 & <乙>", author = "作者 > 人", intro = "简介 & <说明>",
    url = "https://user:pass@example.test/book?token=secret-token",
}
local chapters = {
    { uid = "chapter-safe-one", index = 1, title = "第一章 & 起", vip = false,
      url = "https://example.test/1?cookie=secret-cookie" },
    { uid = "chapter-safe-two", index = 2, title = "第二章 <续>", vip = false,
      url = "https://example.test/2?Authorization=secret-auth" },
    { uid = "chapter-vip", index = 3, title = "付费章", vip = true },
}
local bodies = {
    ["chapter-safe-one"] = "<p>合成正文一 &amp; 安全</p>",
    ["chapter-safe-two"] = "<p>合成正文二</p>",
}

local entries = assert(EpubBuilder.buildEntries(book, chapters, bodies, {
    modified = "2026-08-31T00:00:00Z",
    cover = { data = "\255\216\255\224jpeg-bytes", media_type = "image/jpeg" },
    source = { id = "raw-id", bookSourceName = "测试 & 书源", header = "Cookie: secret-cookie",
        loginUrl = "https://user:pass@example.test/login?token=secret-token" },
}))

equal("mimetype", entries[1].path, "EPUB mimetype is the first archive entry")
equal("application/epub+zip", entries[1].data, "EPUB mimetype has the required bytes")
equal("store", entries[1].compression, "EPUB mimetype requests store compression")

local by_path = {}
local all_data = {}
for index, entry in ipairs(entries) do
    equal(index, entry.order, "archive entries carry deterministic order")
    by_path[entry.path] = entry
    all_data[#all_data + 1] = entry.path .. "\n" .. entry.data
end
truthy(by_path["META-INF/container.xml"], "container.xml is present")
truthy(by_path["OEBPS/content.opf"], "EPUB package document is present")
truthy(by_path["OEBPS/nav.xhtml"], "EPUB navigation document is present")
truthy(by_path["OEBPS/intro.xhtml"], "introduction document is present")
truthy(by_path["OEBPS/styles/structure.css"], "minimal structure stylesheet is present")
truthy(by_path["OEBPS/images/cover.jpg"], "optional JPEG cover is present")
truthy(by_path["OEBPS/text/chapter-0001.xhtml"], "first chapter has a deterministic safe filename")
truthy(by_path["OEBPS/text/chapter-0002.xhtml"], "second chapter has a deterministic safe filename")
equal(nil, by_path["OEBPS/text/chapter-0003.xhtml"], "VIP chapters are omitted")
truthy(by_path["META-INF/legado-source.json"], "redacted source manifest is present")

local opf = by_path["OEBPS/content.opf"].data
truthy(opf:find("urn:legado:book%-safe%-id"), "package identifier is deterministic")
truthy(opf:find("甲 &amp; &lt;乙&gt;", 1, true), "metadata title is XML escaped")
truthy(opf:find("作者 &gt; 人", 1, true), "metadata author is XML escaped")
truthy(opf:find("zh%-CN"), "metadata language is zh-CN")
truthy(opf:find("2026%-08%-31T00:00:00Z"), "metadata modified timestamp is deterministic")
truthy(opf:find("简介 &amp; &lt;说明&gt;", 1, true), "metadata description is XML escaped")
local nav = by_path["OEBPS/nav.xhtml"].data
truthy(nav:find("第一章 &amp; 起", 1, true), "navigation title is escaped")
truthy(nav:find("第二章 &lt;续&gt;", 1, true), "navigation preserves chapter order")
truthy(by_path["OEBPS/text/chapter-0001.xhtml"].data:find(bodies["chapter-safe-one"], 1, true),
    "sanitized semantic chapter body is embedded without destructive re-escaping")
local css = by_path["OEBPS/styles/structure.css"].data:lower()
equal(nil, css:find("font", 1, true), "stylesheet never hard-codes fonts")
equal(nil, css:find("color", 1, true), "stylesheet never hard-codes colors")
equal(nil, css:find("background", 1, true), "stylesheet never hard-codes backgrounds")
local archive_text = table.concat(all_data, "\n")
equal(nil, archive_text:find("secret-token", 1, true), "source manifest omits URL tokens")
equal(nil, archive_text:find("secret-cookie", 1, true), "source manifest omits cookies")
equal(nil, archive_text:find("secret-auth", 1, true), "source manifest omits chapter credentials")
equal(nil, archive_text:find("user:pass", 1, true), "source manifest omits URL userinfo")

do
    local credential_book = {}
    for key, value in pairs(book) do credential_book[key] = value end
    credential_book.source_name = "Authorization: Bearer secret-source-name"
    local credential_entries = assert(EpubBuilder.buildEntries(credential_book, chapters, bodies, {}))
    local text = {}; for _, entry in ipairs(credential_entries) do text[#text + 1] = entry.data end
    equal(nil, table.concat(text, "\n"):find("secret-source-name", 1, true),
        "source display names cannot smuggle credentials into the source manifest")
end

local without_cover = assert(EpubBuilder.buildEntries(book, chapters, bodies, { modified = "2026-08-31T00:00:00Z" }))
local cover_found = false
for _, entry in ipairs(without_cover) do if entry.path:find("cover", 1, true) then cover_found = true end end
equal(false, cover_found, "cover entries and metadata are absent when no cover is available")

for _, unsafe_cover in ipairs({
    { data = "<svg xmlns='http://www.w3.org/2000/svg'/>", media_type = "image/svg+xml" },
    { data = "\137PNG\13\10\26\10payload", media_type = "image/jpeg" },
    { url = "https://example.invalid/cover.jpg", media_type = "image/jpeg" },
}) do
    local unsafe_entries = assert(EpubBuilder.buildEntries(book, chapters, bodies, { cover = unsafe_cover }))
    local found = false
    for _, entry in ipairs(unsafe_entries) do if entry.path:find("cover", 1, true) then found = true end end
    equal(false, found, "unsafe, mismatched, or external covers are omitted")
end

do
    local multibyte = EpubBuilder.exportFilename({ id = "utf8-book", name = string.rep("书", 27) })
    truthy(multibyte:find(string.rep("书", 26) .. "-", 1, true) == 1,
        "export filename truncates only at a complete UTF-8 codepoint boundary")
    local shared = string.rep("same-prefix-", 12)
    local first_name = EpubBuilder.exportFilename({ id = shared .. "A", name = "同名" })
    local second_name = EpubBuilder.exportFilename({ id = shared .. "B", name = "同名" })
    truthy(first_name ~= second_name, "sanitized/truncated identifiers retain a deterministic uniqueness hash")
    equal(first_name, EpubBuilder.exportFilename({ id = shared .. "A", name = "同名" }), "export filenames are deterministic")
end

local missing, missing_error = EpubBuilder.buildEntries(book, chapters, { ["chapter-safe-one"] = bodies["chapter-safe-one"] }, {})
equal(nil, missing, "complete EPUB refuses a missing non-VIP chapter")
equal("INVALID_INPUT", missing_error and missing_error.code, "missing chapter failure is structured")

-- KOReader v2026.07.1 ships ffi/archiver.Writer with per-entry ZIP compression.
local function fake_archiver(behavior)
    behavior = behavior or {}
    local capture = { entries = {}, compressions = {} }
    local Writer = {}
    function Writer:new()
        local writer = { err = nil }
        function writer:open(path, format)
            capture.path, capture.format = path, format
            if behavior.open_failure then self.err = "open failed"; return nil end
            return true
        end
        function writer:setZipCompression(method)
            capture.compressions[#capture.compressions + 1] = method
            return true
        end
        function writer:addFileFromMemory(path, data, mtime)
            if behavior.write_failure and #capture.entries + 1 == behavior.write_failure then self.err = "write failed"; return nil end
            capture.entries[#capture.entries + 1] = { path = path, data = data, mtime = mtime,
                compression = capture.compressions[#capture.compressions] }
            return true
        end
        function writer:close()
            capture.closed = (capture.closed or 0) + 1
            if behavior.commit_failure then self.err = "commit failed" end
            capture.committed = true
        end
        return writer
    end
    local Reader = {}
    function Reader:new()
        local reader = {}
        function reader:open(path)
            capture.verified_path = path
            if behavior.verify_failure then self.err = "verify failed"; return nil end
            self.index = 0; return true
        end
        function reader:iterate()
            return function(self)
                self.index = self.index + 1
                local entry = capture.entries[self.index]
                return entry and { path = entry.path, mode = "file", size = #entry.data } or nil
            end, self
        end
        function reader:extractToMemory(path)
            if behavior.read_failure then self.err = "read failed"; return nil end
            for _, entry in ipairs(capture.entries) do
                if entry.path == path then
                    if behavior.corrupt_same_size and path == capture.entries[2].path then
                        return (entry.data:sub(1, 1) == "X" and "Y" or "X") .. entry.data:sub(2)
                    end
                    return entry.data
                end
            end
            self.err = "missing"; return nil
        end
        function reader:close()
            capture.reader_closed = true
            if behavior.reader_close_failure then self.err = "reader close failed" end
        end
        return reader
    end
    return { Writer = Writer, Reader = Reader }, capture
end

do
    local module, capture = fake_archiver()
    local writer = ArchiveWriter.new({ archiver = module })
    truthy(writer:write("book.epub.part", entries), "runtime adapter writes and verifies a complete archive")
    equal("book.epub.part", capture.path, "archive writer opens the part path")
    equal("epub", capture.format, "archive writer uses KOReader's EPUB alias")
    equal("store", capture.entries[1].compression, "archive writer stores mimetype")
    equal("deflate", capture.entries[2].compression, "archive writer deflates later entries")
    equal(#entries, #capture.entries, "archive writer writes every entry in order")
    truthy(capture.committed and capture.reader_closed, "archive commit is verified through KOReader Reader")
end

for _, case in ipairs({
    { name = "open", behavior = { open_failure = true } },
    { name = "write", behavior = { write_failure = 3 } },
    { name = "commit", behavior = { commit_failure = true } },
    { name = "verify", behavior = { verify_failure = true } },
    { name = "corrupt", behavior = { corrupt_same_size = true } },
    { name = "read", behavior = { read_failure = true } },
    { name = "reader-close", behavior = { reader_close_failure = true } },
}) do
    local module, capture = fake_archiver(case.behavior)
    local ok, err = ArchiveWriter.new({ archiver = module }):write("failed.epub.part", entries)
    equal(nil, ok, case.name .. " failure is rejected")
    equal("STORAGE_ERROR", err and err.code, case.name .. " failure is structured")
    if case.name ~= "open" then truthy(capture.closed, case.name .. " failure closes the writer") end
end

local function memory_fs(initial, behavior)
    local files = initial or {}
    behavior = behavior or {}
    local fs = {}
    function fs:removeFile(path) files[path] = nil; return true end
    function fs:atomicReplacePreparedFile(part, final)
        if behavior.replace_failure then return nil, { code = "STORAGE_ERROR", message = "replace failed" } end
        if not files[part] then return nil, { code = "STORAGE_ERROR", message = "part missing" } end
        files[final], files[part] = files[part], nil
        return true
    end
    function fs:size(path) return files[path] and #files[path] or nil end
    return fs, files
end

do
    local fs, files = memory_fs({ ["book.epub"] = "old-epub" })
    local adapter = { write = function(_, path, value)
        equal("book.epub.part", path, "builder writes only to the task part path")
        equal("mimetype", value[1].path, "builder passes deterministic entries to archive adapter")
        files[path] = "complete-new-epub"; return true
    end }
    local builder = EpubBuilder.new({ archive_writer = adapter, fs = fs })
    local path = assert(builder:write("book.epub", book, chapters, bodies, { modified = "2026-08-31T00:00:00Z" }))
    equal("book.epub", path, "successful builder returns final EPUB path")
    equal("complete-new-epub", files["book.epub"], "complete EPUB safely replaces the previous version")
    equal(nil, files["book.epub.part"], "successful publish leaves no part file")
end

for _, case in ipairs({ "archive", "replace" }) do
    local fs, files = memory_fs({ ["book.epub"] = "old-epub" }, { replace_failure = case == "replace" })
    local adapter = { write = function(_, path)
        files[path] = "partial"
        if case == "archive" then return nil, { code = "STORAGE_ERROR", message = "archive failed" } end
        return true
    end }
    local ok, err = EpubBuilder.new({ archive_writer = adapter, fs = fs }):write("book.epub", book, chapters, bodies, {})
    equal(nil, ok, case .. " failure rejects EPUB publication")
    equal("STORAGE_ERROR", err and err.code, case .. " failure is structured")
    equal("old-epub", files["book.epub"], case .. " failure preserves old EPUB")
    equal(nil, files["book.epub.part"], case .. " failure removes only this task's part")
end

do
    local prepared = os.tmpname() .. ".epub.part"
    local target = os.tmpname() .. ".epub"
    local function put(path, data)
        local handle = assert(io.open(path, "wb")); assert(handle:write(data)); assert(handle:close())
    end
    put(target, "old-real-epub")
    put(prepared, "new-real-epub")
    local fs = Fs.new()
    fs.read = function() error("prepared EPUB publication must never read archive bytes into Lua") end
    local real_published, real_error = fs:atomicReplacePreparedFile(prepared, target)
    truthy(real_published, "shared Fs atomically publishes a prepared archive: " .. tostring(real_error and real_error.message))
    local handle = assert(io.open(target, "rb"))
    equal("new-real-epub", handle:read("*a"), "shared Fs publishes exact prepared bytes")
    handle:close()
    equal(nil, io.open(prepared, "rb"), "shared Fs removes the prepared part after publication")
    os.remove(target)
end

do
    local ok, invalid, invalid_error = pcall(EpubBuilder.buildEntries, book,
        { { uid = "", index = 1, title = "invalid", vip = false } }, { [1] = "<p>body</p>" }, {})
    truthy(ok, "malformed chapter identifiers return a structured result instead of throwing")
    equal(nil, invalid, "empty chapter UID is rejected")
    equal("INVALID_INPUT", invalid_error and invalid_error.code, "empty chapter UID failure is structured")
end

do
    local malformed_bodies = {
        ["chapter-safe-one"] = "<p>&copy;<strong>broken</p>",
        ["chapter-safe-two"] = "<blockquote>A&nbsp;B &unknown;</blockquote>",
    }
    local repaired = assert(EpubBuilder.buildEntries(book, chapters, malformed_bodies, {}))
    local repaired_by_path = {}; for _, entry in ipairs(repaired) do repaired_by_path[entry.path] = entry.data end
    local first = repaired_by_path["OEBPS/text/chapter-0001.xhtml"]
    truthy(first:find("<p>©<strong>broken</strong></p>", 1, true), "malformed semantic HTML is balanced by the safe XHTML serializer")
    equal(nil, first:find("&copy;", 1, true), "HTML-only named entities never leak into XML")
    local second = repaired_by_path["OEBPS/text/chapter-0002.xhtml"]
    truthy(second:find("A B &amp;unknown;", 1, true), "entities become Unicode/XML5 or safely escaped text")
    local invalid_utf8 = assert(EpubBuilder.buildEntries(book, chapters, {
        ["chapter-safe-one"] = "<p>bad\255text</p>", ["chapter-safe-two"] = "<p>ok</p>",
    }, {}))
    local invalid_text; for _, entry in ipairs(invalid_utf8) do if entry.path:find("chapter%-0001%.xhtml$") then invalid_text = entry.data end end
    equal(nil, invalid_text:find("\255", 1, true), "invalid UTF-8 bytes never enter XHTML")
    truthy(invalid_text:find("�", 1, true), "invalid UTF-8 bytes become a valid replacement character")
end

return count
