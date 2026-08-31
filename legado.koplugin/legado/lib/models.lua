local Identity = require("legado.lib.identity")
local SafeFunctions = require("legado.lib.safe_functions")

local Models = {}

local function trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function resolve(base_url, value)
    value = trim(value)
    if value == "" then return "" end
    return SafeFunctions.resolve_url(base_url or "", value)
end

local function boolean(value)
    if value == true or value == 1 then return true end
    if type(value) == "string" then
        local lowered = trim(value):lower()
        return lowered == "true" or lowered == "1" or lowered == "yes" or lowered == "vip"
    end
    return false
end

local function number(value)
    if type(value) == "number" then return value end
    local digits = trim(value):gsub("[,，%s]", ""):match("%-?%d+%.?%d*")
    return digits and tonumber(digits) or nil
end

local function source_reference(source)
    return source and (source.id or source.bookSourceUrl or source.url or source.bookSourceName) or ""
end

local function first_present(value, names)
    for _, name in ipairs(names) do if value[name] ~= nil then return value[name] end end
end

function Models.sourceId(source)
    return Identity.source(source_reference(source))
end

function Models.book(source, value, base_url)
    value = type(value) == "table" and value or {}
    local source_id = Models.sourceId(source)
    local url = resolve(base_url or (source and source.bookSourceUrl), value.url or value.bookUrl)
    local name = trim(value.name or value.bookName)
    local book = {
        source_id = source_id,
        source_name = trim(source and (source.bookSourceName or source.name)),
        name = name,
        author = trim(value.author),
        url = url,
        cover_url = resolve(base_url or url, value.cover_url or value.coverUrl),
        intro = trim(value.intro or value.introduction),
        kind = trim(value.kind or value.category),
        last_chapter = trim(value.last_chapter or value.lastChapter),
        word_count = number(value.word_count or value.wordCount),
    }
    book.id = Identity.book(source_id, url ~= "" and url or (name .. "\n" .. book.author))
    if value.toc_url or value.tocUrl then book.toc_url = resolve(base_url or url, value.toc_url or value.tocUrl) end
    return book
end

function Models.chapter(book, source, value, base_url)
    value = type(value) == "table" and value or {}
    local index = math.max(1, math.floor(tonumber(value.index) or 1))
    local url = resolve(base_url or (book and book.url), value.url or value.chapterUrl)
    local chapter = {
        source_id = Models.sourceId(source),
        book_id = book and book.id or "",
        index = index,
        title = trim(value.title or value.chapterName or value.name),
        url = url,
        vip = boolean(first_present(value, { "vip", "isVip", "pay" })),
    }
    if url ~= "" then
        chapter.uid = Identity.chapter(chapter.book_id, url:gsub("#.*$", ""), nil)
    else
        chapter.uid = Identity.chapter(chapter.book_id, chapter.title, index)
    end
    return chapter
end

function Models.groupKey(book)
    return trim(book and book.name):lower() .. "\n" .. trim(book and book.author):lower()
end

return Models
