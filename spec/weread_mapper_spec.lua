local A = require("assertions")
local Mapper = require("legado.lib.weread_mapper")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local wire = {
    books = { { bookId = "a", title = "第一本", author = "作者", cover = "https://cover.test/a", intro = "简介" } },
    recentBooks = { { book = { bookId = "a", title = "第一本" } },
        { bookInfo = { bookId = "b", title = "第二本" } } },
    bookProgress = { { bookId = "a", progress = 34, updateTime = 300 },
        { bookId = "b", progress = 5, updateTime = 100 } },
}
local books = Mapper.shelf(wire)
eq(2, #books, "overlapping remote shelf lists are deduplicated")
eq("weread", books[1].source_id, "remote books keep an isolated source identity")
eq("a", books[1].remote_id, "stable remote id remains available")
eq("第一本", books[1].name, "remote title is mapped")
eq(34, books[1].progress_percent, "remote historical progress is mapped")
eq(300, books[1].read_at, "remote reading time is mapped")
eq(120, Mapper.book({bookId = "read-time", readUpdateTime = 120, updateTime = 900}).read_at,
    "a book update must not replace its last reading time")
eq(0, Mapper.book({bookId = "unread", updateTime = 900}).read_at,
    "a book update alone is not a reading event")
eq(200, Mapper.book({book = {bookId = "wrapped", readTime = 100}, readUpdateTime = 200}).read_at,
    "a newer outer reading event supersedes an older nested reading time")
eq(200, Mapper.book({book = {bookId = "wrapped-zero", readUpdateTime = 0}, readUpdateTime = 200}).read_at,
    "a zero nested reading time does not hide the outer reading event")
local timestamp_books = Mapper.shelf({books = {
    {bookId = "seconds", readUpdateTime = 1700000100},
    {bookId = "milliseconds", readUpdateTime = 1700000200000},
}})
eq("milliseconds", timestamp_books[1].remote_id,
    "second and millisecond reading times share one chronological order")
eq(1700000200, timestamp_books[1].read_at,
    "remote millisecond reading time is stored in seconds")
local progress_time = Mapper.shelf({
    books = {{bookId = "progress-time", readUpdateTime = 400}},
    bookProgress = {{bookId = "progress-time", readUpdateTime = 300, updateTime = 900}},
})
eq(400, progress_time[1].read_at,
    "older progress time and unrelated update time cannot hide newer book reading")
local conflicting_recent = Mapper.shelf({
    recentBooks = {
        {bookId = "older", readUpdateTime = 1700000100},
        {bookId = "newer", readUpdateTime = 1700000200},
    },
})
eq("newer", conflicting_recent[1].remote_id,
    "actual reading time takes priority over recent-list position")
eq("b", books[2].remote_id, "nested bookInfo is mapped")
eq(false, books[1].id == Mapper.book({ bookId = "a", title = "另一本" }, "other-account").id,
    "different accounts cannot share local reading identity")
eq("c", Mapper.shelf({ recentBooks = {{ bookId = "c", title = "第三本" }} })[1].remote_id,
    "a shelf with only recentBooks still loads")
local embedded = Mapper.book({ book = { bookId = "embedded", title = "行内进度", progress = 41 } })
eq(41, embedded.progress_percent, "a book row retains its embedded reading progress")
eq(100, Mapper.book({bookId = "finished", finishReading = 1}).progress_percent,
    "a completed reading state shows full progress")
local recent = Mapper.shelf({
    books = {{ bookId = "old", title = "旧书" }, { bookId = "new", title = "新书" }},
    recentBooks = {{ book = { bookId = "new", title = "新书" }, progress = 62 }},
})
eq("new", recent[1].remote_id, "recently read books lead even when the general shelf list comes first")
eq(62, recent[1].progress_percent, "duplicate recent rows supplement missing progress")
local reread = Mapper.shelf({books = {{bookId = "again", progress = 70}},
    recentBooks = {{book = {bookId = "again"}, progress = 20}}})
eq(20, reread[1].progress_percent, "a newer recent position may move backward within the book")
local chapters = {{remote_uid = "chapter-a"}, {remote_uid = "chapter-b"}}
eq(nil, Mapper.progress({}, chapters), "empty cloud progress does not invent a first-chapter position")
eq(nil, Mapper.progress({book = {chapterUid = "missing"}}, chapters),
    "unknown cloud chapter is not stored as a false first-chapter position")
local index, fraction = Mapper.progress({book = {chapterUid = "chapter-b", chapterOffset = 2500}}, chapters)
eq(2, index, "known cloud chapter maps to the local catalog")
eq(0.25, fraction, "known cloud position retains its chapter offset")
return count
