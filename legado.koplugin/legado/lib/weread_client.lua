local Json = require("legado.lib.json_codec")
local Url = require("legado.lib.safe_functions").functions.urlencode

local Client = {}
Client.__index = Client

local WEB = "https://weread.qq.com"
local EINK = "https://i.weread.qq.com"
local BROWSER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
local EINK_AGENT = "WeRead/2.1.2 WRBrand/Onyx wr_eink Dalvik/2.1.0 (Linux; U; Android 11; BOOX Build/onyx)"

local function decode(response)
    if type(response) ~= "table" or type(response.body) ~= "string" then return nil end
    local ok, data = pcall(Json.decode, response.body)
    if ok and type(data) == "table" then return data end
end

local function decode_raw_error(response)
    local body = response and response.body
    if type(body) ~= "string" or not body:match("^%s*{") then return nil end
    if not body:find('"errCode"', 1, true) and not body:find('"errcode"', 1, true) then
        return nil
    end
    return decode(response)
end

local function session_headers(session, eink)
    if eink then return { ["User-Agent"] = EINK_AGENT, baseapi = "30", appver = "2.1.2.10245900",
        basever = "2.1.2.10245900", osver = "11", channelId = "900",
        vid = session.vid, accessToken = session.access_token } end
    return { ["User-Agent"] = BROWSER_AGENT, ["Accept-Language"] = "zh-CN,zh;q=0.9",
        Referer = WEB .. "/", Origin = WEB,
        Cookie = "wr_vid=" .. Url(session.vid) .. "; wr_skey=" .. Url(session.access_token) .. '; wr_ql=0',
        ["X-Vid"] = session.vid, ["X-Skey"] = session.access_token }
end

function Client.new(options)
    options = options or {}
    assert(options.requests and options.auth, "WeRead client requires requests and auth")
    return setmetatable({ requests = options.requests, auth = options.auth }, Client)
end

function Client:_call(method, path, body, eink, callback, options)
    options=options or {}
    local cancelled, active = false, nil
    local function attempt(number)
        if cancelled then return end
        local session = self.auth:session()
        if not session then return callback(nil, "请先扫码登录微信读书") end
        local delivered = false
        local headers=session_headers(session, eink)
        for key,value in pairs(options.headers or {}) do headers[key]=value end
        local handle = self.requests:execute({
            url = (eink and EINK or WEB) .. path, method = method,
            source_id = "weread", headers = headers,
            body = body, body_type = body and "json" or nil, priority = "foreground",
            timeout=options.timeout,max_bytes=options.max_bytes,
        }, function(response, err)
            delivered = true
            if cancelled then return end
            active = nil
            local data
            if options.raw then data = decode_raw_error(response)
            else data = decode(response) end
            local status = response and tonumber(response.status or response.code)
                or err and type(err.details) == "table" and tonumber(err.details.status)
            local code = data and tonumber(data.errCode or data.errcode)
            if number == 1 and (status == 401 or code == -2012) then
                local refreshed = false
                local refresh_handle = self.auth:refresh(function(new_session, refresh_error)
                    refreshed = true
                    if cancelled then return end
                    if new_session then attempt(2)
                    else callback(nil, refresh_error or "微信读书登录已失效") end
                end)
                if not refreshed then active = refresh_handle end
                return
            end
            if code == -2041 then return callback(nil, "请在微信读书官方客户端完成人机验证") end
            if err or not status or status < 200 or status >= 300
                or (not options.raw and not data) or (code and code ~= 0) then
                return callback(nil, "微信读书请求失败")
            end
            callback(options.raw and response.body or data)
        end)
        if not delivered then active = handle end
    end
    attempt(1)
    return { cancel = function()
        if cancelled then return false end
        cancelled = true
        if active and type(active.cancel) == "function" then active:cancel() end
        return true
    end }
end

function Client:chapterContent(book_id, chapter_uid, callback)
    local Protocol=require('legado.lib.weread_protocol')
    book_id,chapter_uid=tostring(book_id or ''),tostring(chapter_uid or '')
    if book_id=='' or chapter_uid=='' then callback(nil,'章节标识无效');return nil end
    local cancelled,active,finished=false,nil,false
    local reader_url=Protocol.readerUrl(book_id,chapter_uid)
    local function finish(body,err)
        if cancelled or finished then return end
        finished=true
        callback(body,err)
    end
    local function shard(endpoint,psvts,done)
        if cancelled then return end
        local delivered=false
        local handle=self:_call('POST','/web/book/chapter/'..endpoint,
            Protocol.contentParams(book_id,chapter_uid,os.time(),psvts),false,function(raw,err)
                delivered=true
                active=nil
                if cancelled then return end
                if not raw or raw=='{}' then return done(nil,err or '章节接口返回空内容',raw=='{}') end
                done(raw)
            end,{raw=true,timeout=90,max_bytes=8*1024*1024,
                headers={Referer=reader_url,Accept='application/json, text/plain, */*'}})
        if not delivered then active=handle end
    end
    local fetch_shards
    local function fetch_reader_state()
        local delivered=false
        local handle=self:_call('GET',reader_url:sub(#WEB+1),nil,false,function(html,reader_err)
            delivered=true
            active=nil
            if not html then return finish(nil,reader_err) end
            local psvts=html:match('"psvts"%s*:%s*"([%w_-]+)"')
            if not psvts or #psvts>256 then return finish(nil,'微信读书阅读页缺少章节验证参数') end
            fetch_shards(psvts,false)
        end,{raw=true,timeout=90,max_bytes=8*1024*1024,
            headers={Accept='text/html,application/xhtml+xml'}})
        if not delivered then active=handle end
    end
    fetch_shards=function(psvts,allow_fallback)
        shard('e_0',psvts,function(first,err)
            if not first then
                if allow_fallback and err=='章节接口返回空内容' then return fetch_reader_state() end
                return finish(nil,err)
            end
            local text_chapter=first:sub(1,1)=='{' and first:find('"bookId"',1,true)~=nil
            local second,third=text_chapter and 't_0' or 'e_1',text_chapter and 't_1' or 'e_3'
            shard(second,psvts,function(part,part_err)
                if not part then return finish(nil,part_err) end
                shard(third,psvts,function(last,last_err)
                    if not last and not text_chapter then return finish(nil,last_err) end
                    local decoded,decode_err=Protocol.decodeShards(part,last or '')
                    if not text_chapter then decoded,decode_err=Protocol.decodeShards(first,part,last) end
                    if not decoded then return finish(nil,decode_err) end
                    if #decoded>4*1024*1024 then return finish(nil,'章节正文过大') end
                    if text_chapter then return finish(decoded) end
                    return finish(decoded:match('<[bB][oO][dD][yY][^>]*>(.-)</[bB][oO][dD][yY]>') or decoded)
                end)
            end)
        end)
    end
    fetch_shards(Protocol.encode(os.time()-1),true)
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if active and active.cancel then active:cancel() end
        return true
    end}
end

function Client:shelfSync(callback)
    return self:_call("GET", "/web/shelf/sync?synckey=0&teenmode=0", nil, false, callback)
end

function Client:addToShelf(book_id, callback)
    book_id = tostring(book_id or "")
    if book_id == "" then callback(nil, "书籍标识无效"); return nil end
    return self:_call("POST", "/web/shelf/add", { bookIds = { book_id } }, false, callback)
end

function Client:search(keyword, cursor, callback, sid)
    keyword = tostring(keyword or "")
    if keyword == "" then callback({ books = {} }); return nil end
    local max_idx = tonumber(cursor) or 0
    if max_idx < 0 then max_idx = 0 end
    return self:_call("GET", "/web/search/global?keyword=" .. Url(keyword)
        .. "&maxIdx=" .. tostring(math.floor(max_idx)) .. "&fragmentSize=120&count=20&sid=" .. Url(tostring(sid or "")), nil, false, callback)
end

function Client:category(category_id, cursor, callback)
    category_id = tostring(category_id or "")
    if #category_id > 64 or not category_id:match("^[a-z_]+$") then
        callback(nil, "榜单标识无效")
        return nil
    end
    local max_index = math.floor(math.max(0, tonumber(cursor) or 0))
    return self:_call("GET", "/web/bookListInCategory/" .. category_id
        .. "?rank=1&maxIndex=" .. tostring(max_index), nil, false, callback)
end

function Client:bookInfo(book_id, callback)
    return self:_call("GET", "/web/book/info?bookId=" .. Url(tostring(book_id or "")), nil, false, callback)
end

function Client:chapterInfos(book_id, callback)
    return self:_call("POST", "/web/book/chapterInfos", { bookIds = { tostring(book_id or "") } }, false, callback)
end

function Client:getProgress(book_id, callback)
    return self:_call("GET", "/web/book/getProgress?bookId=" .. Url(tostring(book_id or "")), nil, false, callback)
end

local function review_cursor_number(value)
    local number = tonumber(value)
    if not number or number ~= number or number < 0 or number > 1000000000000 then return nil end
    return math.floor(number)
end

local function wrong_review_book(candidate, book_id)
    if type(candidate) ~= "table" then return false end
    if candidate.bookId ~= nil and tostring(candidate.bookId) ~= book_id then return true end
    local nested = candidate.book
    return type(nested) == "table" and nested.bookId ~= nil and tostring(nested.bookId) ~= book_id
end

function Client:bookReviews(book_id, callback, cursor)
    book_id = tostring(book_id or "")
    if book_id == "" then callback(nil, "书籍标识无效"); return nil end
    local max_idx = review_cursor_number(cursor and cursor.max_idx) or 0
    local synckey = review_cursor_number(cursor and cursor.synckey) or 0
    return self:_call("GET", "/review/list?bookId=" .. Url(book_id)
        .. "&reviewListType=0&listMode=0&synckey=" .. synckey
        .. "&maxIdx=" .. max_idx .. "&count=20", nil, true, function(data, err)
        if not data then return callback(nil, err) end
        local wire_rows = type(data.reviews) == "table" and data.reviews or {}
        local selected = {}
        for _, row in ipairs(wire_rows) do
            local outer = type(row) == "table" and (row.review or row) or nil
            local review = type(outer) == "table" and (outer.review or outer) or nil
            if type(review) == "table" and not wrong_review_book(row, book_id)
                and not wrong_review_book(outer, book_id)
                and not wrong_review_book(review, book_id) then
                selected[#selected + 1] = row
            end
        end
        data.reviews = selected
        local last = wire_rows[#wire_rows]
        local next_idx = type(last) == "table" and review_cursor_number(last.idx)
        local next_key = review_cursor_number(data.synckey)
        if (data.reviewsHasMore == 1 or data.reviewsHasMore == true)
            and next_idx and next_idx > max_idx and next_key then
            data.next_cursor = {max_idx = next_idx, synckey = next_key}
        end
        data.has_more = data.next_cursor ~= nil
        callback(data)
    end)
end

return Client
