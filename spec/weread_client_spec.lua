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
eq(true, requests[3].spec.url:find("reviewListType=0", 1, true) ~= nil, "book reviews include public comments")
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
local review_page
client:bookReviews("b1", function(value) review_page = value end)
requests[14].callback({status = 200, body = Json.encode({reviewsHasMore = 1, synckey = 123,
    reviews = {
        {idx = 20, review = {review = {book = {bookId = "b1"}, content = "本书评论"}}},
        {idx = 21, review = {review = {book = {bookId = "b2"}, content = "其他书评论"}}},
        {idx = 22, review = {review = {book = {bookId = "b1"}, content = "本书另一条"}}},
    }})})
eq(2, #review_page.reviews, "nested book identity filters reviews for other books")
eq(true, review_page.has_more, "review response keeps the server's next-page state")
eq(22, review_page.next_cursor.max_idx, "next review cursor uses the last wire row")
eq(123, review_page.next_cursor.synckey, "next review cursor carries the server sync key")
client:bookReviews("b1", function(value) review_page = value end, review_page.next_cursor)
eq(true, requests[15].spec.url:find("maxIdx=22", 1, true) ~= nil,
    "later review pages use the last review index")
eq(true, requests[15].spec.url:find("synckey=123", 1, true) ~= nil,
    "later review pages preserve the sync key")
requests[15].callback({status = 200, body = Json.encode({reviewsHasMore = 1, synckey = 123,
    reviews = {{idx = 22, review = {review = {book = {bookId = "b1"}, content = "重复页"}}}}})})
eq(false, review_page.has_more, "a repeated review cursor stops further requests")

token = "a+b/c=="
client:shelfSync(function() end)
eq("wr_vid=123; wr_skey=a+b/c==; wr_ql=0", requests[16].spec.headers.Cookie,
    "WeRead cookie preserves token punctuation exactly")
token = "bad;\r\nInjected: value"
local invalid_session_error
client:shelfSync(function(_, err) invalid_session_error = err end)
eq(16, #requests, "unsafe cookie token never reaches the network layer")
eq("微信读书会话无效，请重新扫码登录", invalid_session_error,
    "invalid session reports a clear login action")

local function auth_expiry_case(refresh_error)
    local sent, token_value, refreshes = {}, "expired", 0
    local local_client = Client.new{
        requests = { execute = function(_, spec, callback)
            sent[#sent + 1] = { spec = spec, callback = callback }
            return { cancel = function() end }
        end },
        auth = {
            session = function() return { vid = "123", access_token = token_value } end,
            refresh = function(_, callback)
                refreshes = refreshes + 1
                if refresh_error then return callback(nil, refresh_error) end
                token_value = "renewed"
                callback({ vid = "123", access_token = token_value })
            end,
        },
    }
    return local_client, sent, function() return refreshes end
end

for _, expired in ipairs({
    { status = 401, body = "{}" },
    { status = 200, body = Json.encode({ errCode = -2012 }) },
}) do
    local local_client, sent, refresh_count = auth_expiry_case()
    local value, error_message
    local_client:addToShelf("b3", function(result, err) value, error_message = result, err end)
    sent[1].callback(expired)
    eq(1, refresh_count(), "expired shelf write refreshes the login once")
    eq(1, #sent, "expired shelf write is not sent twice")
    eq(nil, value, "unknown shelf write result is not reported as success")
    eq("微信读书登录已续期，请同步书架确认写入结果", error_message,
        "unknown shelf write result gives a safe next step")
end

do
    local local_client, sent = auth_expiry_case()
    local chapters
    local_client:chapterInfos("b3", function(value) chapters = value end)
    sent[1].callback({ status = 200, body = Json.encode({ errCode = -2012 }) })
    eq(2, #sent, "read-only chapter catalog POST retries after login renewal")
    eq("renewed", sent[2].spec.headers["X-Skey"], "catalog retry uses the renewed token")
    sent[2].callback({ status = 200, body = Json.encode({ chapterInfos = {} }) })
    eq(true, type(chapters) == "table", "catalog retry reaches the caller")
end

do
    local local_client, sent = auth_expiry_case("续期失败")
    local result, error_message
    local_client:addToShelf("b3", function(value, err) result, error_message = value, err end)
    sent[1].callback({ status = 401, body = "{}" })
    eq(1, #sent, "failed login renewal cannot replay a shelf write")
    eq(nil, result, "failed login renewal cannot report a successful shelf write")
    eq("续期失败", error_message, "failed login renewal reaches the caller")
end

do
    local local_client, sent = auth_expiry_case()
    local error_message
    local_client:chapterInfos("b3", function(_, err) error_message = err end)
    sent[1].callback({ status = 401, body = "{}" })
    sent[2].callback({ status = 401, body = "{}" })
    eq(2, #sent, "a second catalog authentication failure is not retried again")
    eq("微信读书请求失败", error_message, "a second catalog authentication failure reaches the caller")
end

do
    local local_client, sent = auth_expiry_case()
    local handle = local_client:chapterContent("b3", "c1", function() end)
    sent[1].callback({ status = 401, body = "{}" })
    eq(2, #sent, "read-only chapter shard POST retries after login renewal")
    eq("renewed", sent[2].spec.headers["X-Skey"], "shard retry uses the renewed token")
    handle:cancel()
end

do
    local sent, finish_refresh, outcome = {}, nil, nil
    local local_client = Client.new{
        requests = { execute = function(_, spec, callback)
            sent[#sent + 1] = { spec = spec, callback = callback }
            return { cancel = function() end }
        end },
        auth = {
            session = function() return { vid = "123", access_token = "expired" } end,
            refresh = function(_, callback)
                finish_refresh = callback
                return { cancel = function() end }
            end,
        },
    }
    local handle = local_client:addToShelf("b3", function(value, err) outcome = value or err end)
    sent[1].callback({ status = 401, body = "{}" })
    handle:cancel()
    finish_refresh({ vid = "123", access_token = "renewed" })
    eq(1, #sent, "cancelled shelf write is never replayed")
    eq(nil, outcome, "cancelled shelf write does not update a closed page")
end
return count
