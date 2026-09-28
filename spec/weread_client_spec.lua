local A = require("assertions")
local Json = require("legado.lib.json_codec")
local Client = require("legado.lib.weread_client")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local requests = {}
local transport = { execute = function(_, spec, callback)
    local row = { spec = spec, callback = callback }
    requests[#requests + 1] = row
    return { cancel = function() row.cancelled = true end }
end }
local token = "access"
local renews = 0
local auth = { session = function() return { vid = "123", access_token = token } end,
    refresh = function(_, callback) renews = renews + 1; token = "renewed"; callback({ vid = "123", access_token = token }) end }
local client = Client.new{ requests = transport, auth = auth }
local shelf
client:shelfSync(function(value) shelf = value end)
eq("https://weread.qq.com/web/shelf/sync?synckey=0&teenmode=0", requests[1].spec.url,
    "shelf sync requests a full remote shelf")
eq("wr_vid=123; wr_skey=access; wr_ql=0", requests[1].spec.headers.Cookie, "shelf request uses the local session")
requests[1].callback({ status = 200, body = Json.encode({ books = {{ bookId = "b1" }} }) })
eq("b1", shelf.books[1].bookId, "shelf response reaches the caller")
local found
client:search("三体", 1, function(value) found = value end)
eq(true, requests[2].spec.url:find("keyword=", 1, true) ~= nil, "store search URL contains a keyword")
requests[2].callback({ status = 200, body = Json.encode({ books = {{ bookId = "b2" }} }) })
eq("b2", found.books[1].bookId, "search results reach the caller")
local reviews
client:bookReviews("b1", function(value) reviews = value end)
eq(true, requests[3].spec.url:find("/review/list", 1, true) ~= nil, "review list uses the Eink endpoint")
eq(true, requests[3].spec.url:find("listType=0", 1, true) ~= nil, "book reviews include public comments")
requests[3].callback({ status = 200, body = Json.encode({ reviews = {
    { review = { review = { bookId = "b1", content = "公开评论" } } },
    { review = { bookId = "b2", content = "其他书评论" } },
} }) })
eq(1, #reviews.reviews, "other books' reviews are filtered out")
local refreshed
client:bookInfo("b1", function(value) refreshed = value end)
requests[4].callback({ status = 200, body = Json.encode({ errCode = -2012 }) })
eq(1, renews, "expired read-only request refreshes the session once")
eq("renewed", requests[5].spec.headers["X-Skey"], "retried request uses the new token")
requests[5].callback({ status = 200, body = Json.encode({ book = { bookId = "b1" } }) })
eq("b1", refreshed.book.bookId, "read-only request succeeds after refresh")
local cancelled = false
local handle = client:getProgress("b1", function() cancelled = true end)
handle:cancel()
eq(true, requests[6].cancelled, "cancel propagates to transport")
requests[6].callback({ status = 200, body = "{}" })
eq(false, cancelled, "cancelled response cannot update the page")
local added
client:addToShelf("b3", function(value) added = value end)
eq("POST", requests[7].spec.method, "adding a store book writes to the WeRead shelf")
eq("https://weread.qq.com/web/shelf/add", requests[7].spec.url, "shelf addition uses the official Web endpoint")
eq("b3", requests[7].spec.body.bookIds[1], "shelf addition sends the selected remote book ID")
requests[7].callback({ status = 200, body = Json.encode({ errCode = 0 }) })
eq(0, added.errCode, "successful shelf addition reaches the caller")
client:search("科幻", 19, function() end, "session-1")
eq(true, requests[8].spec.url:find("maxIdx=19", 1, true) ~= nil,
    "later store pages use the last search index")
eq(true, requests[8].spec.url:find("sid=session%-1") ~= nil,
    "later store pages preserve the search session")
client:search("科幻", 1, function() end, "session-1")
eq(true, requests[9].spec.url:find("maxIdx=1", 1, true) ~= nil,
    "a valid first search index is not reset to page zero")
local ranked
client:category("rising", 20, function(value) ranked = value end)
eq("https://weread.qq.com/web/bookListInCategory/rising?rank=1&maxIndex=20",
    requests[10].spec.url, "store ranking uses the live category JSON endpoint and cursor")
requests[10].callback({status = 200, body = Json.encode({books = {{searchIdx = 21,
    bookInfo = {bookId = "ranked-1", title = "榜单书"}}}, hasMore = 1})})
eq("ranked-1", ranked.books[1].bookInfo.bookId, "ranked books retain the nested bookInfo data")
client:category("../shelf", 0, function(value, err) ranked = value; eq("榜单标识无效", err,
    "invalid category IDs are rejected before creating a request") end)
eq(10, #requests, "invalid category ID cannot change the request path")

local original_decode = Json.decode
local decode_count = 0
Json.decode = function(...)
    decode_count = decode_count + 1
    return original_decode(...)
end
local raw_body = '{"bookId":"b1","chapterUid":"c1","content":"正文"}'
local raw_result
client:_call("POST", "/web/book/chapter/e_0", {}, false, function(value) raw_result = value end,
    { raw = true })
requests[11].callback({ status = 200, body = raw_body })
Json.decode = original_decode
eq(raw_body, raw_result, "raw chapter data reaches the caller unchanged")
eq(0, decode_count, "successful raw chapter data is not JSON-decoded before shard assembly")

local raw_auth_result
client:_call("GET", "/web/book/reader", nil, false, function(value) raw_auth_result = value end,
    { raw = true })
requests[12].callback({ status = 200, body = '{"errCode":-2012}' })
eq(2, renews, "raw authentication errors still refresh the WeRead session")
requests[13].callback({ status = 200, body = "<html>reader</html>" })
eq("<html>reader</html>", raw_auth_result, "refreshed raw request returns the reader page")
return count
