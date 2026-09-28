local WeRead = {}
WeRead.__index = WeRead
WeRead.RANKINGS = {
    {id = "rising", label = "飙升榜"},
    {id = "hot_search", label = "热搜榜"},
    {id = "newbook", label = "新书榜"},
    {id = "general_novel_rising", label = "小说榜"},
    {id = "all", label = "总榜"},
}
local Json = require("legado.lib.json_codec")
local Mapper = require("legado.lib.weread_mapper")

local function load_books(fs, path, account_id)
    if not fs or not path or not account_id then return {} end
    local raw = fs:readBounded(path, 2 * 1024 * 1024)
    if type(raw) ~= "string" then return {} end
    local ok, value = pcall(Json.decode, raw)
    if not ok or type(value) ~= "table" or value.account_id ~= account_id
        or type(value.books) ~= "table" or #value.books > 2000 then return {} end
    local books = {}
    for _, book in ipairs(value.books) do
        if type(book) ~= "table" or type(book.id) ~= "string" or type(book.remote_id) ~= "string"
            or book.source_id ~= "weread" or type(book.name) ~= "string" then return {} end
        books[#books + 1] = book
    end
    return books
end

function WeRead.new(options)
    options = options or {}
    local session = options.auth and type(options.auth.session) == "function" and options.auth:session()
    local account_id = session and session.vid
    return setmetatable({ kind = "weread", auth = options.auth, client = options.client,
        fs = options.fs, path = options.path, account_id = account_id,
        books = load_books(options.fs, options.path, account_id), synced = false,
        scheduler = options.scheduler,
        status = options.auth and options.auth:hasSession() and "已登录" or "未登录",
        alive = true, generation = 0 }, WeRead)
end

function WeRead:page(page)
    page = math.max(1, math.floor(tonumber(page) or 1))
    local total = #self.books
    local page_count = 1 + math.ceil(math.max(0, total - 5) / 12)
    page = math.min(page, page_count)
    local first = page == 1 and 1 or 6 + (page - 2) * 12
    local last = math.min(total, page == 1 and 5 or first + 11)
    local items = {}
    for index = first, last do items[#items + 1] = self.books[index] end
    return { items = items, page = page, page_count = page_count, total = total,
        mode = page == 1 and "shelf_hero" or "grid" }
end

function WeRead:sync(callback)
    callback = callback or function() end
    if not self.alive or not self.client or not self.auth or not self.auth:session() then
        self.status = "请先扫码登录微信读书"
        callback(nil, self.status)
        return nil
    end
    local session = self.auth:session()
    if self.account_id ~= session.vid then
        self.account_id, self.books = session.vid, load_books(self.fs, self.path, session.vid)
    end
    self.status, self.synced = "正在同步微信书架…", true
    self.sync_generation = (self.sync_generation or 0) + 1
    local generation, sync_generation, delivered = self.generation, self.sync_generation, false
    local handle = self.client:shelfSync(function(wire, err)
        delivered = true
        if not self.alive or generation ~= self.generation or sync_generation ~= self.sync_generation then return end
        self.request = nil
        local current = self.auth:session()
        if not current or current.vid ~= session.vid then return callback(nil, "微信读书账号已切换") end
        if not wire then
            self.status = "书架同步失败，显示上次记录"
            return callback(nil, err)
        end
        self.books = Mapper.shelf(wire, self.account_id)
        if self.fs and self.path then
            local encoded = Json.encode({ account_id = self.account_id, books = self.books })
            self.fs:atomicWrite(self.path, encoded)
        end
        self.status = "已登录"
        callback(self.books)
    end)
    if not delivered then self.request = handle end
    return handle
end

function WeRead:hasBook(book)
    local remote_id = type(book) == "table" and book.remote_id or book
    for _, saved in ipairs(self.books) do
        if saved.remote_id == remote_id then return true end
    end
    return false
end

function WeRead:addToShelf(book, callback)
    callback = callback or function() end
    if not self.alive or not self.client or type(self.client.addToShelf) ~= "function"
        or type(book) ~= "table" or type(book.remote_id) ~= "string" or book.remote_id == "" then
        callback(nil, "微信书架不可用")
        return nil
    end
    if self:hasBook(book) then callback(true); return nil end
    local generation, delivered = self.generation, false
    local account_id = self.account_id
    local function same_account()
        local session = self.auth and self.auth:session()
        return session and session.vid == account_id and self.account_id == account_id
    end
    local handle = self.client:addToShelf(book.remote_id, function(result, err)
        delivered = true
        if not self.alive or generation ~= self.generation then return end
        self.add_request = nil
        if not same_account() then return callback(nil, "微信读书账号已切换") end
        if not result then return callback(nil, err or "加入微信书架失败") end
        self:sync(function()
            if not self.alive or generation ~= self.generation then return end
            if not same_account() then return callback(nil, "微信读书账号已切换") end
            if not self:hasBook(book) then
                self.books[#self.books + 1] = book
                if self.fs and self.path then
                    self.fs:atomicWrite(self.path, Json.encode({ account_id = self.account_id, books = self.books }))
                end
            end
            callback(true)
        end)
    end)
    if not delivered then self.add_request = handle end
    return handle
end

function WeRead:_fetchStore(cursor, callback)
    if self.store_category_id then
        return self.client:category(self.store_category_id, cursor, callback)
    end
    return self.client:search(self.store_keyword, cursor, callback, self.store_sid)
end

function WeRead:_startStore(label, category_id, callback)
    callback = callback or function() end
    if not self.alive or not self.client then callback(nil, "微信书城不可用"); return nil end
    self.store_generation = (self.store_generation or 0) + 1
    if self.store_request and type(self.store_request.cancel) == "function" then self.store_request:cancel() end
    self.store_keyword, self.store_category_id = tostring(label or ""), category_id
    self.store_results, self.store_loading, self.store_error = {}, true, nil
    self.store_cursor, self.store_sid, self.store_has_more, self.store_page = 0, nil, false, 1
    local generation, store_generation, delivered = self.generation, self.store_generation, false
    local handle = self:_fetchStore(0, function(wire, err)
        delivered = true
        if not self.alive or generation ~= self.generation or store_generation ~= self.store_generation then return end
        self.store_request, self.store_loading = nil, false
        if not wire then self.store_error = err or "书城搜索失败"; callback(nil, self.store_error); return end
        local books = {}
        local rows = type(wire.books) == "table" and wire.books or {}
        for _, row in ipairs(rows) do
            local book = Mapper.book(row, self.account_id)
            if book then books[#books + 1] = book end
        end
        self.store_results = books
        self.store_sid = type(wire.sid) == "string" and wire.sid or nil
        self.store_cursor = tonumber(rows[#rows] and rows[#rows].searchIdx) or #rows
        self.store_has_more = (wire.hasMore == 1 or wire.hasMore == true) and #rows > 0
        callback(books)
    end)
    if not delivered then self.store_request = handle end
    return handle
end

function WeRead:searchStore(keyword, callback)
    return self:_startStore(keyword, nil, callback)
end

function WeRead:categoryStore(category_id, label, callback)
    callback = callback or function() end
    local valid = false
    for _, ranking in ipairs(self.RANKINGS) do
        if ranking.id == category_id and ranking.label == label then valid = true; break end
    end
    if not valid or not self.client or type(self.client.category) ~= "function" then
        callback(nil, "微信书城榜单不可用")
        return nil
    end
    return self:_startStore(label, category_id, callback)
end

function WeRead:loadMoreStore(callback)
    callback = callback or function() end
    if not self.alive or not self.client or not self.store_has_more or self.store_loading then return nil end
    self.store_loading, self.store_error = true, nil
    local generation, store_generation, delivered = self.generation, self.store_generation, false
    local cursor = self.store_cursor
    local handle = self:_fetchStore(cursor, function(wire, err)
        delivered = true
        if not self.alive or generation ~= self.generation or store_generation ~= self.store_generation then return end
        self.store_request, self.store_loading = nil, false
        if not wire then self.store_error = err or "书城加载失败"; callback(nil, self.store_error); return end
        local rows = type(wire.books) == "table" and wire.books or {}
        local seen = {}
        for _, book in ipairs(self.store_results) do seen[book.remote_id] = true end
        local added = 0
        for _, row in ipairs(rows) do
            local book = Mapper.book(row, self.account_id)
            if book and not seen[book.remote_id] then
                seen[book.remote_id] = true
                self.store_results[#self.store_results + 1] = book
                added = added + 1
            end
        end
        local next_cursor = tonumber(rows[#rows] and rows[#rows].searchIdx) or cursor + #rows
        self.store_cursor = next_cursor
        if type(wire.sid) == "string" and wire.sid ~= "" then self.store_sid = wire.sid end
        self.store_has_more = (wire.hasMore == 1 or wire.hasMore == true)
            and #rows > 0 and next_cursor > cursor and added > 0
        callback(self.store_results)
    end)
    if not delivered then self.store_request = handle end
    return handle
end

function WeRead:clearStore()
    self.store_generation = (self.store_generation or 0) + 1
    if self.store_request and type(self.store_request.cancel) == "function" then self.store_request:cancel() end
    self.store_request, self.store_keyword, self.store_category_id, self.store_results = nil, nil, nil, nil
    self.store_loading, self.store_error, self.store_has_more = false, nil, false
    self.store_cursor, self.store_sid, self.store_page = nil, nil, nil
end

function WeRead:cancel()
    self.generation = self.generation + 1
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    if self.store_request and type(self.store_request.cancel) == "function" then self.store_request:cancel() end
    if self.add_request and type(self.add_request.cancel) == "function" then self.add_request:cancel() end
    if self.review_request and type(self.review_request.cancel) == "function" then self.review_request:cancel() end
    if self.scheduled and self.scheduler and type(self.scheduler.unschedule) == "function" then
        pcall(self.scheduler.unschedule, self.scheduler, self.scheduled)
    end
    self.request, self.store_request, self.add_request, self.review_request, self.scheduled = nil, nil, nil, nil, nil
    if self.alive and self.status ~= "已登录" then self.status = "已取消" end
end

function WeRead:close()
    if not self.alive then return false end
    self:cancel()
    self.alive = false
    return true
end

function WeRead:start(on_qr, on_done)
    if not self.alive or not self.auth then
        self.status = "微信读书尚未初始化"
        if on_done then on_done(false) end
        return nil
    end
    self:cancel()
    self.status = "正在获取二维码…"
    local generation = self.generation
    local function current() return self.alive and self.generation == generation end
    local function finish(status)
        if not current() then return end
        self.request, self.scheduled = nil, nil
        self.status = status
        if on_done then on_done(status == "已登录") end
    end
    local poll
    poll = function(uuid)
        if not current() then return end
        local delivered = false
        local handle = self.auth:pollLogin(uuid, function(code, state, err)
            delivered = true
            if not current() then return end
            self.request = nil
            if state == "confirmed" then
                self.status = "正在确认登录…"
                local confirmed = false
                local login = self.auth:completeLogin(code, function(session, login_error)
                    confirmed = true
                    if session then finish("已登录") else finish(login_error or "登录失败") end
                end)
                if not confirmed then self.request = login end
            elseif state == "waiting" or state == "scanned" then
                self.status = state == "scanned" and "已扫码，请在微信中确认" or "等待扫码…"
                if self.scheduler and type(self.scheduler.scheduleIn) == "function" then
                    local action = function() self.scheduled = nil; poll(uuid) end
                    self.scheduled = action
                    self.scheduler:scheduleIn(0.2, action)
                else finish("扫码轮询不可用") end
            else finish(err or "二维码已失效，请重新登录") end
        end)
        if not delivered then self.request = handle end
    end
    local delivered = false
    local request = self.auth:beginLogin(function(qr, err)
        delivered = true
        if not current() then return end
        self.request = nil
        if not qr then return finish(err or "获取二维码失败") end
        self.status = "等待扫码…"
        if on_qr then on_qr(qr) end
        poll(qr.uuid)
    end)
    if not delivered then self.request = request end
    return request
end

return WeRead
