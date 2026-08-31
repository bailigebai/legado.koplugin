local Identity = {}

local function normalize(value)
    value = tostring(value or "")
    value = value:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1")
    return value
end

local function hash(value)
    local total = 5381
    for index = 1, #value do
        total = (total * 33 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", total)
end

function Identity.hash(value)
    return hash(normalize(value))
end

function Identity.source(source_url)
    return "source-" .. Identity.hash(source_url)
end

function Identity.book(source_id, book_url)
    return "book-" .. Identity.hash(tostring(source_id or "") .. "\n" .. normalize(book_url))
end

function Identity.chapter(book_id, chapter_url, index)
    return "chapter-" .. Identity.hash(tostring(book_id or "") .. "\n" .. normalize(chapter_url) .. "\n" .. tostring(index or ""))
end

return Identity
