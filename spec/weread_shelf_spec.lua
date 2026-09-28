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
local account, add_response, new_sync, add_error = "account-1", nil, nil, nil
local switched = View.new{auth={session=function() return {vid=account} end,hasSession=function() return true end},
    client={addToShelf=function(_, _, done) add_response=done;return {cancel=function() end} end,
        shelfSync=function(_, done) new_sync=done;return {cancel=function() end} end}}
switched:addToShelf({remote_id="old-book",name="旧账号书籍"},function(_,err) add_error=err end)
account="account-2"
add_response({errCode=0})
eq(nil,new_sync,"an account switch does not refresh the new account with an old addition")
eq(0,#switched.books,"an old account's book is not inserted into the new account shelf")
eq("微信读书账号已切换",add_error,"account switch is reported to the caller")
local pending_sync, sync_error
local switching = View.new{auth={session=function() return {vid=account} end,hasSession=function() return true end},
    client={shelfSync=function(_,done) pending_sync=done;return {cancel=function() end} end}}
switching:sync(function(_,err) sync_error=err end)
account="account-3"
pending_sync({books={{bookId="old-book",title="旧账号书籍"}}})
eq(0,#switching.books,"a late response cannot show books from a previous account")
eq("微信读书账号已切换",sync_error,"late shelf response reports the account change")
local recent_view = make_view()
recent_view:sync()
callback({books={{bookId="older",title="旧书"},{bookId="latest",title="最近读"}},
    recentBooks={{book={bookId="latest",title="最近读"},progress=48}}})
eq("latest",recent_view:page(1).items[1].remote_id,"the WeRead hero follows recent reading without a separate progress list")
eq(48,recent_view:page(1).items[1].progress_percent,"the hero retains embedded reading progress")
return count
