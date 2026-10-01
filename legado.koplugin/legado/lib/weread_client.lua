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

local function cookie_value(value)
    if type(value) ~= "string" or value == "" or value:find("[%c%s;,]")
        or value:find('"', 1, true) or value:find("\\", 1, true) then return nil end
    return value
end

local function session_headers(session, eink)
    local vid, access_token = cookie_value(session.vid), cookie_value(session.access_token)
    if not vid or not access_token then return nil end
    if eink then return { ["User-Agent"] = EINK_AGENT, baseapi = "30", appver = "2.1.2.10245900",
        basever = "2.1.2.10245900", osver = "11", channelId = "900",
        vid = vid, accessToken = access_token } end
    return { ["User-Agent"] = BROWSER_AGENT, ["Accept-Language"] = "zh-CN,zh;q=0.9",
        Referer = WEB .. "/", Origin = WEB,
        Cookie = "wr_vid=" .. vid .. "; wr_skey=" .. access_token .. '; wr_ql=0',
        ["X-Vid"] = vid, ["X-Skey"] = access_token }
end

function Client.new(options)
    options = options or {}
    assert(options.requests and options.auth, "WeRead client requires requests and auth")
    return setmetatable({ requests = options.requests, auth = options.auth }, Client)
end

function Client:_call(method, path, body, eink, callback, options)
    options=options or {}
    local replayable = method == "GET" or options.idempotent == true
    local cancelled, active = false, nil
    local function attempt(number)
        if cancelled then return end
        local session = self.auth:session()
        if not session then return callback(nil, "请先扫码登录微信读书") end
        local delivered = false
        local headers=session_headers(session, eink)
        if not headers then return callback(nil, "微信读书会话无效，请重新扫码登录") end
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
                local latest = self.auth:session()
                if not latest then return callback(nil, "请先扫码登录微信读书") end
                if latest.vid ~= session.vid then return callback(nil, "微信读书账号已切换") end
                local function after_refresh(new_session, refresh_error)
                    if cancelled then return end
                    local current_session = self.auth:session()
                    if not current_session then return callback(nil, "请先扫码登录微信读书") end
                    if current_session.vid ~= session.vid
                        or (new_session and new_session.vid ~= session.vid) then
                        return callback(nil, "微信读书账号已切换")
                    end
                    if new_session and replayable then attempt(2)
                    elseif new_session then callback(nil, "微信读书登录已续期，请同步书架确认写入结果")
                    else callback(nil, refresh_error or "微信读书登录已失效") end
                end
                if latest.access_token ~= session.access_token then return after_refresh(latest) end
                local refreshed = false
                local refresh_handle = self.auth:refresh(function(new_session, refresh_error)
                    refreshed = true
                    after_refresh(new_session, refresh_error)
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
            end,{raw=true,idempotent=true,timeout=90,max_bytes=8*1024*1024,
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
    return self:_call("POST", "/web/book/chapterInfos", { bookIds = { tostring(book_id or "") } }, false, callback,
        { idempotent = true })
end

function Client:fetchResource(url,callback,max_bytes)
    url=tostring(url or '')
    local host=url:match('^https://([^/%?#]+)')
    if not host or not ({['res.weread.qq.com']=true,['cdn.weread.qq.com']=true,
        ['weread.qq.com']=true})[host:lower()] or url:find('[%c%s]') then
        callback(nil,'微信图片地址无效')
        return nil
    end
    local session=self.auth:session()
    local vid=session and cookie_value(session.vid)
    local token=session and cookie_value(session.access_token)
    if not vid or not token then callback(nil,'微信读书会话无效，请重新扫码登录');return nil end
    local cancelled,finished=false,false
    local request=self.requests:execute({url=url,method='GET',source_id='weread-image',binary=true,
        https_only=true,
        max_bytes=math.min(16*1024*1024,math.max(1,tonumber(max_bytes) or 4*1024*1024)),timeout=90,
        headers={Cookie='wr_vid='..vid..'; wr_skey='..token..'; wr_ql=0',
            Referer=WEB..'/', ['User-Agent']=BROWSER_AGENT}},function(response,err)
        if cancelled or finished then return end
        finished=true
        local current=self.auth:session()
        if not current or current.vid~=session.vid then return callback(nil,'微信读书账号已切换') end
        if err or not response or type(response.body)~='string' then
            return callback(nil,'微信图片获取失败，请重试')
        end
        callback(response.body)
    end)
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if request and request.cancel then request:cancel() end
        return true
    end}
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

local function comment_range(value)
    if type(value)~='string' or #value>32 then return nil end
    local first,last=value:match('^(%d+)%-(%d+)$')
    first,last=tonumber(first),tonumber(last)
    if first and last and first<last and last<=8*1024*1024 then return value end
end

local function comment_owner_matches(value,book_id,chapter_uid)
    if type(value)~='table' then return false end
    return not wrong_review_book(value,book_id)
        and (value.chapterUid==nil or tostring(value.chapterUid)==chapter_uid)
end

-- The Web reader uses GET underlines then a read-only POST readReviews.
-- A cursor owns its book/chapter and per-range positions; one call loads at
-- most ten ranges, with twenty comments per range. No eager whole-book fetch.
function Client:chapterComments(book_id,chapter_uid,callback,cursor)
    book_id,chapter_uid=tostring(book_id or ''),tostring(chapter_uid or '')
    if book_id=='' or chapter_uid=='' then callback(nil,'书籍或章节标识无效');return nil end
    local session=self.auth:session()
    if not session then callback(nil,'请先扫码登录微信读书');return nil end
    local account=session.vid
    local cancelled,finished,active=false,false,nil
    local function finish(value,err)
        if cancelled or finished then return end
        finished=true
        callback(value,err)
    end
    local function current()
        if cancelled or finished then return false end
        local latest=self.auth:session()
        if not latest or latest.vid~=account then finish(nil,'微信读书账号已切换');return false end
        return true
    end
    local function stage(method,path,body,done)
        if not current() then return end
        local delivered=false
        local handle=self:_call(method,path,body,false,function(value,err)
            delivered=true;active=nil
            if current() then done(value,err) end
        end,{idempotent=true,max_bytes=2*1024*1024})
        if not delivered then active=handle end
    end
    local function load_ranges(ranges)
        if #ranges==0 then return finish({reviews={},has_more=false}) end
        local batch,remaining,requested={},{},{}
        for i,row in ipairs(ranges) do
            if i<=10 then batch[#batch+1]=row;requested[row.range]=row
            else remaining[#remaining+1]=row end
        end
        stage('POST','/web/book/readReviews',{bookId=book_id,chapterUid=tonumber(chapter_uid) or chapter_uid,
            reviews=batch},function(data,err)
            if not data then return finish(nil,err) end
            if not comment_owner_matches(data,book_id,chapter_uid) or type(data.reviews)~='table' then
                return finish(nil,'微信本章评论返回的书籍或章节不匹配')
            end
            local reviews={}
            for _,group in ipairs(data.reviews) do
                local request=type(group)=='table' and requested[group.range]
                if request and comment_owner_matches(group,book_id,chapter_uid) then
                    local pages=type(group.pageReviews)=='table' and group.pageReviews or {}
                    for i,row in ipairs(pages) do
                        if i>20 then break end
                        local review=type(row)=='table' and (row.review or row)
                        if type(review)=='table' and type(review.review)=='table' then review=review.review end
                        if type(review)=='table' and comment_owner_matches(row,book_id,chapter_uid)
                            and comment_owner_matches(review,book_id,chapter_uid)
                            and (review.range==nil or review.range==group.range) then
                            reviews[#reviews+1]={id=tostring(review.reviewId or row.reviewId or (group.range..':'..(request.maxIdx+i))),
                                range=group.range,abstract=review.abstract,content=review.content,
                                htmlContent=review.htmlContent,author=review.author,createTime=review.createTime,
                                book_id=book_id,chapter_uid=chapter_uid}
                        end
                    end
                    local next_idx=review_cursor_number(group.maxIdx)
                    if next_idx and next_idx<=request.maxIdx then next_idx=nil end
                    if not next_idx and #pages>0 then
                        next_idx=review_cursor_number(pages[#pages].idx) or (request.maxIdx+#pages)
                    end
                    if (group.hasMore==1 or group.hasMore==true) and next_idx and next_idx>request.maxIdx then
                        remaining[#remaining+1]={range=group.range,maxIdx=next_idx,count=20,
                            synckey=review_cursor_number(group.synckey) or 0}
                    end
                end
            end
            local next_cursor=#remaining>0 and {book_id=book_id,chapter_uid=chapter_uid,ranges=remaining} or nil
            finish({reviews=reviews,next_cursor=next_cursor,has_more=next_cursor~=nil})
        end)
    end
    if cursor then
        if type(cursor)~='table' or cursor.book_id~=book_id or cursor.chapter_uid~=chapter_uid
            or type(cursor.ranges)~='table' or #cursor.ranges>1000 then
            finish(nil,'本章评论续页参数无效')
        else
            local ranges={}
            for _,row in ipairs(cursor.ranges) do
                if type(row)~='table' or not comment_range(row.range)
                    or not review_cursor_number(row.maxIdx) or not review_cursor_number(row.synckey) then
                    finish(nil,'本章评论续页范围无效');break
                end
                ranges[#ranges+1]={range=row.range,maxIdx=row.maxIdx,count=20,synckey=row.synckey}
            end
            if not finished then load_ranges(ranges) end
        end
    else
        stage('GET','/web/book/underlines?bookId='..Url(book_id)..'&chapterUid='..Url(chapter_uid),nil,
            function(data,err)
                if not data then return finish(nil,err) end
                if not comment_owner_matches(data,book_id,chapter_uid) or type(data.underlines)~='table' then
                    return finish(nil,'微信本章划线返回的书籍或章节不匹配')
                end
                if #data.underlines>1000 then return finish(nil,'本章划线过多，暂不能加载评论') end
                local ranges,seen={},{}
                for _,row in ipairs(data.underlines) do
                    local range=type(row)=='table' and comment_range(row.range)
                    if range and not seen[range] and comment_owner_matches(row,book_id,chapter_uid) then
                        seen[range]=true;ranges[#ranges+1]={range=range,maxIdx=0,count=20,synckey=0}
                    end
                end
                load_ranges(ranges)
            end)
    end
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if active and active.cancel then active:cancel() end
        return true
    end}
end

return Client
