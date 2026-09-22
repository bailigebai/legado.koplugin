local Identity = {}

local function koreader_hasher()
    local loaded, sha2 = pcall(require, "ffi/sha2")
    if not loaded or not sha2 then return nil end
    if type(sha2.sha256) == "function" then return sha2.sha256 end
    if type(sha2.digest) == "function" then return function(value) return sha2.digest("sha256", value) end end
    return nil
end

local native_hash = koreader_hasher()

local function normalize(value)
    value = tostring(value or "")
    value = value:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1")
    return value
end

local function fallback_hash(value)
    local total = 5381
    for index = 1, #value do
        total = (total * 33 + value:byte(index)) % 4294967296
    end
    return string.format("%08x", total)
end

local function hash(value)
    if native_hash then
        local ok, digest = pcall(native_hash, value)
        if ok and type(digest) == "string" and digest ~= "" then return digest end
    end
    return fallback_hash(value)
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
