local A = require("assertions")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local saved, callback = nil, nil
local auth = { hasSession = function() return true end, session = function() return { vid = "account-1" } end }
local client = { shelfSync = function(_, done) callback = done; return { cancel = function() end } end }
local fs = { readBounded = function() return saved end,
    atomicWrite = function(_, _, value) saved = value; return true end }
local function make_view()
    return View.new{ auth = auth, client = client, fs = fs, path = "weread-shelf.json" }
end
local view = make_view()
eq(0, #view.books, "first login begins with an empty local shelf")
view:sync()
local rows, progress = {}, {}
for index = 1, 19 do
    rows[index] = { bookId = "b" .. index, title = "书" .. index,
        intro = "简介" .. index, cover = "https://cover.test/" .. index }
end
progress[1] = { bookId = "b19", progress = 50, updateTime = 500 }
callback({ books = rows, bookProgress = progress })
eq(19, #view.books, "all remote books are held in the WeRead shelf")
eq("b19", view.books[1].remote_id, "most recently read remote book leads")
eq(5, #view:page(1).items, "WeRead first page has a hero and four covers")
eq(12, #view:page(2).items, "WeRead second page has a three-by-four grid")
eq(2, #view:page(3).items, "remaining covers stay reachable")
eq(true, type(saved) == "string" and #saved > 0, "remote shelf is saved locally")
local restarted = make_view()
eq(19, #restarted.books, "offline restart restores the last synced shelf")
restarted:sync()
callback(nil, "network offline")
eq(19, #restarted.books, "network failure keeps the cached WeRead shelf")
return count
