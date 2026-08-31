local assertx = require("assertions")
local Models = require("legado.lib.models")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local source = { id = "https://reader:password@source.test/?token=source-secret" }
local first = Models.book(source, {
    name = "  Example Book  ", author = " Alice ",
    url = "https://user:pass@books.test/book/1?token=book-secret",
    cover_url = "/covers/1.jpg", intro = " Intro ", kind = " Fiction ",
    last_chapter = " Chapter 9 ", word_count = "12345",
}, "https://books.test/search/page")
local again = Models.book(source, {
    name = "Example Book", author = "Alice",
    url = "https://user:pass@books.test/book/1?token=book-secret",
}, "https://books.test/search/page")

equal(first.id, again.id, "book identity is deterministic")
equal("Example Book", first.name, "book name is trimmed")
equal("Alice", first.author, "author is trimmed")
equal("https://books.test/covers/1.jpg", first.cover_url, "relative cover resolves from final URL")
equal(12345, first.word_count, "word count is normalized")
equal(nil, first.id:find("password", 1, true), "book id excludes password")
equal(nil, first.id:find("book-secret", 1, true), "book id excludes query credentials")

local chapter = Models.chapter(first, source, {
    index = 4, title = "  Chapter Four ", url = "../chapter/4", vip = "true",
}, "https://books.test/toc/list")
local same_chapter = Models.chapter(first, source, {
    index = 4, title = "Chapter Four", url = "https://books.test/chapter/4", vip = true,
}, "https://books.test/toc/list")
equal(same_chapter.uid, chapter.uid, "chapter identity is deterministic after URL resolution")
equal(first.id, chapter.book_id, "chapter belongs to normalized book")
equal("https://books.test/chapter/4", chapter.url, "relative chapter URL resolves from final URL")
equal(true, chapter.vip, "VIP flag is normalized")
equal(nil, chapter.uid:find("password", 1, true), "chapter uid excludes credentials")
truthy(first.source_id ~= source.id, "model source id is opaque instead of a credential-bearing URL")

equal("example book\nalice", Models.groupKey({ name = " Example Book ", author = "Alice" }), "group key lowercases both identity fields")

return count
