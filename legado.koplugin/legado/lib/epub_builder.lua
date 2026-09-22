local ArchiveWriter = require("legado.lib.archive_writer")
local Cleaner = require("legado.lib.content_cleaner")
local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Identity = require("legado.lib.identity")
local Json = require("legado.lib.json_codec")
local XhtmlSerializer = require("legado.lib.xhtml_serializer")
local XmlText = require("legado.lib.xml_text")

local EpubBuilder = {}
EpubBuilder.__index = EpubBuilder

local function xml(value)
    return XmlText.escape(value)
end

local function safe_token(value, fallback)
    local token = tostring(value or ""):gsub("[^%w_.-]", "-"):gsub("%-+", "-")
        :gsub("^[.-]+", ""):gsub("[.-]+$", "")
    if token == "" then token = fallback end
    if token == nil then return nil end
    return token:sub(1, 96)
end

local function valid_modified(value)
    value = tostring(value or "")
    if value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then return value end
    return "1970-01-01T00:00:00Z"
end

local function utf8_prefix(value, maximum)
    local output, used, index = {}, 0, 1
    while index <= #value do
        local first = value:byte(index)
        local length = first < 0x80 and 1 or (first >= 0xC2 and first <= 0xDF and 2
            or first >= 0xE0 and first <= 0xEF and 3 or first >= 0xF0 and first <= 0xF4 and 4 or 0)
        local valid = length > 0 and index + length - 1 <= #value
        if valid and length > 1 then
            for offset = 1, length - 1 do
                local byte = value:byte(index + offset)
                if not byte or byte < 0x80 or byte > 0xBF then valid = false; break end
            end
        end
        local piece = valid and value:sub(index, index + length - 1) or "-"
        if used + #piece > maximum then break end
        output[#output + 1], used = piece, used + #piece
        index = index + (valid and length or 1)
    end
    return table.concat(output)
end

local function xhtml(title, body, kind)
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        .. '<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">\n'
        .. '<head><meta charset="UTF-8"/><title>' .. xml(title) .. '</title>'
        .. '<link rel="stylesheet" type="text/css" href="styles/structure.css"/></head>\n'
        .. '<body><section class="' .. (kind or "chapter") .. '"><h1>' .. xml(title) .. '</h1>'
        .. body .. '</section></body></html>\n'
end

local function chapter_xhtml(title, body)
    return xhtml(title, body, "chapter"):gsub('href="styles/', 'href="../styles/')
end

local function add(entries, path, data, compression)
    entries[#entries + 1] = { path = path, data = data, compression = compression or "deflate",
        order = #entries + 1, mtime = 315532800 }
end

local function cover_info(cover)
    if type(cover) ~= "table" or type(cover.data) ~= "string" or cover.data == "" then return nil end
    local detected
    if cover.data:sub(1, 3) == "\255\216\255" then detected = { "jpg", "image/jpeg" }
    elseif cover.data:sub(1, 8) == "\137PNG\13\10\26\10" then detected = { "png", "image/png" }
    elseif cover.data:sub(1, 6) == "GIF87a" or cover.data:sub(1, 6) == "GIF89a" then detected = { "gif", "image/gif" } end
    if not detected then return nil end
    local declared = type(cover.media_type) == "string" and cover.media_type:lower() or nil
    if declared and declared ~= detected[2] then return nil end
    return { data = cover.data, extension = detected[1], media_type = detected[2] }
end

function EpubBuilder.buildEntries(book, chapters, bodies, assets)
    assets = assets or {}
    if type(book) ~= "table" or type(chapters) ~= "table" or type(bodies) ~= "table" then
        return nil, Errors.new(Errors.INVALID_INPUT, "book, chapters and bodies are required")
    end
    local included, seen = {}, {}
    for _, chapter in ipairs(chapters) do
        if type(chapter) ~= "table" then return nil, Errors.new(Errors.INVALID_INPUT, "invalid chapter") end
        if chapter.vip ~= true then
            local uid = safe_token(chapter.uid, nil)
            if not uid or seen[uid] then return nil, Errors.new(Errors.INVALID_INPUT, "chapter UID is missing or duplicated") end
            local body = bodies[chapter.uid] or bodies[chapter.index]
            if type(body) ~= "string" or body == "" then
                return nil, Errors.new(Errors.INVALID_INPUT, "non-VIP chapter body is missing", { chapter_uid = chapter.uid })
            end
            local cleaned, clean_error = Cleaner.normalize(body)
            if not cleaned then return nil, clean_error end
            local serialized, serialize_error = XhtmlSerializer.fragment(cleaned)
            if not serialized then return nil, serialize_error end
            seen[uid] = true
            included[#included + 1] = { chapter = chapter, uid = uid, body = serialized,
                filename = string.format("chapter-%04d.xhtml", #included + 1), item_id = "chapter-" .. tostring(#included + 1) }
        end
    end
    if #included == 0 then return nil, Errors.new(Errors.INVALID_INPUT, "complete EPUB requires at least one non-VIP chapter") end

    local identifier = safe_token(book.id, "book-" .. Identity.hash((book.name or "") .. "\n" .. (book.author or "")))
    local title = XmlText.sanitize(book.name or "未命名")
    local author = XmlText.sanitize(book.author or "")
    local description = XmlText.sanitize(book.intro or "")
    local modified = valid_modified(assets.modified or book.modified)
    local cover = cover_info(assets.cover)

    local nav_items, manifest_items, spine_items = {}, {}, {}
    manifest_items[#manifest_items + 1] = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    manifest_items[#manifest_items + 1] = '<item id="style" href="styles/structure.css" media-type="text/css"/>'
    manifest_items[#manifest_items + 1] = '<item id="intro" href="intro.xhtml" media-type="application/xhtml+xml"/>'
    spine_items[#spine_items + 1] = '<itemref idref="intro"/>'
    nav_items[#nav_items + 1] = '<li><a href="intro.xhtml">简介</a></li>'
    if cover then
        manifest_items[#manifest_items + 1] = '<item id="cover-image" href="images/cover.' .. cover.extension
            .. '" media-type="' .. cover.media_type .. '" properties="cover-image"/>'
    end
    for _, value in ipairs(included) do
        manifest_items[#manifest_items + 1] = '<item id="' .. value.item_id .. '" href="text/' .. value.filename
            .. '" media-type="application/xhtml+xml"/>'
        spine_items[#spine_items + 1] = '<itemref idref="' .. value.item_id .. '"/>'
        nav_items[#nav_items + 1] = '<li><a href="text/' .. value.filename .. '">' .. xml(value.chapter.title or "") .. '</a></li>'
    end

    local metadata = '<dc:identifier id="book-id">urn:legado:' .. xml(identifier) .. '</dc:identifier>'
        .. '<dc:title>' .. xml(title) .. '</dc:title><dc:creator>' .. xml(author) .. '</dc:creator>'
        .. '<dc:language>zh-CN</dc:language><meta property="dcterms:modified">' .. modified .. '</meta>'
    if description ~= "" then metadata = metadata .. '<dc:description>' .. xml(description) .. '</dc:description>' end
    local opf = '<?xml version="1.0" encoding="UTF-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">'
        .. '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">' .. metadata .. '</metadata><manifest>'
        .. table.concat(manifest_items) .. '</manifest><spine>' .. table.concat(spine_items) .. '</spine></package>\n'
    local nav = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN"><head><meta charset="UTF-8"/><title>'
        .. xml(title) .. '</title><link rel="stylesheet" type="text/css" href="styles/structure.css"/></head><body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>'
        .. table.concat(nav_items) .. '</ol></nav></body></html>\n'
    local container = '<?xml version="1.0" encoding="UTF-8"?>\n<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>\n'
    local source_id = book.source_id or (type(assets.source) == "table" and assets.source.id) or ""
    local sources = Json.array({ { id = safe_token(source_id, "unknown-source") } })
    local manifest = Json.encode({ version = 1, generated_by = "legado.koplugin", book = {
        id = identifier, name = title, author = author,
    }, chapter_count = #included, sources = sources })

    local entries = {}
    add(entries, "mimetype", "application/epub+zip", "store")
    add(entries, "META-INF/container.xml", container)
    add(entries, "OEBPS/content.opf", opf)
    add(entries, "OEBPS/nav.xhtml", nav)
    add(entries, "OEBPS/styles/structure.css", ".chapter { break-before: page; }\n")
    add(entries, "OEBPS/intro.xhtml", xhtml("简介", description ~= "" and "<p>" .. xml(description) .. "</p>" or "<p></p>", "introduction"))
    if cover then add(entries, "OEBPS/images/cover." .. cover.extension, cover.data) end
    for _, value in ipairs(included) do
        add(entries, "OEBPS/text/" .. value.filename, chapter_xhtml(value.chapter.title or "", value.body))
    end
    add(entries, "META-INF/legado-source.json", manifest)
    return entries
end

function EpubBuilder.new(options)
    options = options or {}
    return setmetatable({ fs = options.fs or Fs.new(), archive_writer = options.archive_writer or ArchiveWriter.new() }, EpubBuilder)
end

function EpubBuilder.exportFilename(book)
    local name = tostring(type(book) == "table" and book.name or "book")
        :gsub("[%z\1-\31<>:\"/\\|?*]", "-"):gsub("%s+", " "):match("^%s*(.-)%s*$")
        :gsub("[. ]+$", "")
    if name == "" then name = "book" end
    name = utf8_prefix(name, 80)
    local raw_id = tostring(type(book) == "table" and book.id or "book")
    local readable_id = safe_token(raw_id, "book"):sub(1, 48)
    return name .. "-" .. readable_id .. "-" .. Identity.hash(raw_id) .. ".epub"
end

function EpubBuilder:write(path, book, chapters, bodies, assets)
    if type(path) ~= "string" or path == "" then return nil, Errors.new(Errors.INVALID_INPUT, "EPUB path is required") end
    local entries, build_error = EpubBuilder.buildEntries(book, chapters, bodies, assets)
    if not entries then return nil, build_error end
    local part = path .. ".part"
    pcall(self.fs.removeFile, self.fs, part)
    local written, write_error = self.archive_writer:write(part, entries)
    if not written then self.fs:removeFile(part); return nil, write_error end
    local size, size_error = self.fs:size(part)
    if not size or size <= 0 then
        self.fs:removeFile(part)
        return nil, size_error or Errors.new(Errors.STORAGE_ERROR, "EPUB archive part is empty")
    end
    if type(self.fs.atomicReplacePreparedFile) ~= "function" then
        self.fs:removeFile(part)
        return nil, Errors.new(Errors.STORAGE_ERROR, "atomic EPUB publication is unavailable")
    end
    local published, publish_error = self.fs:atomicReplacePreparedFile(part, path, { expected_size = size })
    if not published then self.fs:removeFile(part); return nil, publish_error end
    return path, publish_error
end

return EpubBuilder
