local Errors = require("legado.lib.errors")
local Json = require("legado.lib.json_codec")
local Models = require("legado.lib.models")

local BookService = {}
BookService.__index = BookService
BookService.DEFAULT_CONCURRENCY = 2
BookService.MAX_CONCURRENCY = 3
BookService.MAX_PAGES = 20

local function trim(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function shallow_copy(value)
    local result = {}
    for key, child in pairs(value or {}) do result[key] = child end
    return result
end

local function setting(settings, key, fallback)
    if type(settings) == "table" and type(settings.get) == "function" then
        local ok, value = pcall(settings.get, settings, key)
        if ok and value ~= nil then return value end
    elseif type(settings) == "table" and settings[key] ~= nil then return settings[key] end
    return fallback
end

local function concurrency(settings)
    local value = math.floor(tonumber(setting(settings, "concurrency", BookService.DEFAULT_CONCURRENCY)) or BookService.DEFAULT_CONCURRENCY)
    return math.max(1, math.min(BookService.MAX_CONCURRENCY, value))
end

local function source_rule(source, name)
    local rule = source and source[name]
    if type(rule) == "table" then return rule end
    if type(rule) == "string" and trim(rule):sub(1, 1) == "{" then
        local ok, decoded = pcall(Json.decode, rule)
        if ok and type(decoded) == "table" then return decoded end
    end
    if type(rule) == "string" and trim(rule) ~= "" then return { list = rule, content = rule } end
    return {}
end

local function source_headers(source)
    local header = source and source.header
    if type(header) == "table" then return shallow_copy(header) end
    if type(header) ~= "string" or trim(header) == "" then return {} end
    local ok, decoded = pcall(Json.decode, header)
    if ok and type(decoded) == "table" then return shallow_copy(decoded) end
    local output = {}
    for line in header:gmatch("[^\r\n]+") do
        local name, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if name and value then output[name] = value end
    end
    return output
end

local function merge_headers(base, override)
    local result = shallow_copy(base)
    for name, value in pairs(override or {}) do result[name] = value end
    return result
end

local function aliases(rule, names)
    for _, name in ipairs(names) do
        if type(rule[name]) == "string" and trim(rule[name]) ~= "" then return rule[name] end
    end
    return nil
end

local function safe_message(err)
    local code = type(err) == "table" and err.code or "NETWORK_ERROR"
    local messages = {
        TIMEOUT = "请求超时", CANCELLED = "请求已取消", RESPONSE_TOO_LARGE = "响应内容过大",
        ENCODING_ERROR = "网页编码不受支持", PARSE_ERROR = "书源规则解析失败",
        UNSUPPORTED_RULE = "书源包含不支持的规则", SITE_REJECTED = "网站拒绝了请求",
        INVALID_INPUT = "书源配置无效", NETWORK_ERROR = "网络请求失败",
    }
    return messages[code] or "书源处理失败"
end

local function aggregate_error(message, details)
    return Errors.new(Errors.NETWORK_ERROR, message, details)
end

local function composite()
    local state = { cancelled = false, completed = false, children = {} }
    local handle = {}
    function handle:cancel()
        if state.cancelled or state.completed then return false end
        state.cancelled = true
        for _, child in ipairs(state.children) do
            if child and type(child.cancel) == "function" then pcall(child.cancel, child) end
        end
        return true
    end
    function handle:isCancelled() return state.cancelled end
    return handle, state
end

function BookService.new(options)
    options = options or {}
    assert(options.storage, "BookService requires storage")
    assert(options.rule_engine, "BookService requires rule_engine")
    assert(options.request_engine, "BookService requires request_engine")
    assert(options.url_template, "BookService requires url_template")
    return setmetatable({
        storage = options.storage, rules = options.rule_engine, requests = options.request_engine,
        templates = options.url_template, settings = options.settings,
    }, BookService)
end

function BookService:_parse(input, rule, context, list)
    if not rule or trim(rule) == "" then return list and {} or nil, nil end
    return self.rules:parse(input, rule, context, list == true)
end

function BookService:_request(source, specification, context, callback)
    local request, build_error = self.templates:build(specification, context)
    if not request then callback(nil, build_error); return { cancel = function() return false end } end
    local base = context and context.baseUrl or source.bookSourceUrl
    request.url = self.templates:resolve(base or "", request.url)
    request.headers = merge_headers(source_headers(source), request.headers)
    request.source_id = source.id or source.bookSourceUrl
    return self.requests:execute(request, callback)
end

function BookService:_book_values(source, input, rule, base_url, context)
    local function value(names)
        local expression = aliases(rule, names)
        local parsed, err = self:_parse(input, expression, context, false)
        if err then return nil, err end
        return parsed
    end
    local data = {}
    local definitions = {
        name = { "name", "bookName" }, author = { "author" }, url = { "bookUrl", "url" },
        cover_url = { "coverUrl", "cover" }, intro = { "intro", "introduction" }, kind = { "kind", "category" },
        last_chapter = { "lastChapter", "latestChapter" }, word_count = { "wordCount" }, toc_url = { "tocUrl" },
    }
    for field, names in pairs(definitions) do
        local parsed, err = value(names)
        if err then return nil, err end
        data[field] = parsed
    end
    return Models.book(source, data, base_url), nil
end

function BookService:_search_source(source, keyword, page, callback)
    local rule = source_rule(source, "ruleSearch")
    local context = { key = keyword, page = page, baseUrl = source.bookSourceUrl, result = "" }
    return self:_request(source, source.searchUrl, context, function(response, request_error)
        if request_error then callback(nil, request_error); return end
        local final_url = response.final_url or context.baseUrl
        local parse_context = { key = keyword, page = page, baseUrl = final_url, result = response.body }
        local list_rule = aliases(rule, { "bookList", "list" })
        local members, list_error = self:_parse(response.body, list_rule, parse_context, true)
        if list_error then callback(nil, list_error); return end
        local books = {}
        for _, member in ipairs(members or {}) do
            local book, book_error = self:_book_values(source, member, rule, final_url, parse_context)
            if book_error then callback(nil, book_error); return end
            if book.name ~= "" and book.url ~= "" then books[#books + 1] = book end
        end
        callback(books, nil)
    end)
end

function BookService:_selected_sources(source_ids)
    local output = {}
    if type(source_ids) == "table" and #source_ids > 0 then
        for _, id in ipairs(source_ids) do
            local source = self.storage:getSource(id)
            if source then output[#output + 1] = source end
        end
    else
        for _, source in ipairs(self.storage:listSources() or {}) do
            if source.enabled ~= false then output[#output + 1] = source end
        end
    end
    return output
end

function BookService:search(keyword, source_ids, page, callback)
    assert(type(callback) == "function", "BookService search callback must be a function")
    local handle, state = composite()
    keyword, page = trim(keyword), math.max(1, math.floor(tonumber(page) or 1))
    local sources = self:_selected_sources(source_ids)
    if keyword == "" then
        state.completed = true
        callback(nil, Errors.new(Errors.INVALID_INPUT, "search keyword is required"))
        return handle
    end
    local limit = concurrency(self.settings)
    local next_index, active, finished = 1, 0, 0
    local results, failures = {}, {}

    local function finish()
        if state.cancelled or state.completed or finished < #sources then return end
        state.completed = true
        local groups, by_key = {}, {}
        for source_index = 1, #sources do
            for _, book in ipairs(results[source_index] or {}) do
                local key = Models.groupKey(book)
                local group = by_key[key]
                if not group then
                    group = { book = book, alternatives = {}, key = key }
                    by_key[key] = group; groups[#groups + 1] = group
                end
                group.alternatives[#group.alternatives + 1] = book
            end
        end
        local errors = {}
        for index = 1, #sources do if failures[index] then errors[#errors + 1] = failures[index] end end
        local result = { groups = groups, errors = errors, page = page, keyword = keyword }
        local err
        if #sources > 0 and #errors == #sources then err = aggregate_error("all selected sources failed", { count = #errors }) end
        callback(result, err)
    end

    local pump
    pump = function()
        if state.cancelled or state.completed then return end
        while active < limit and next_index <= #sources do
            local index, source = next_index, sources[next_index]
            next_index, active = next_index + 1, active + 1
            local child = self:_search_source(source, keyword, page, function(books, err)
                if state.cancelled or state.completed then return end
                active, finished = active - 1, finished + 1
                if err then
                    failures[index] = { source_id = source.id, source_name = trim(source.bookSourceName), code = err.code or Errors.NETWORK_ERROR, message = safe_message(err) }
                else results[index] = books or {} end
                pump(); finish()
            end)
            state.children[#state.children + 1] = child
        end
        finish()
    end
    if #sources == 0 then state.completed = true; callback({ groups = {}, errors = {}, page = page, keyword = keyword }, nil)
    else pump() end
    return handle
end

function BookService:_single(source, specification, context, parser, callback)
    local handle, state = composite()
    local child = self:_request(source, specification, context, function(response, err)
        if state.cancelled or state.completed then return end
        if err then state.completed = true; callback(nil, err); return end
        local value, parse_error = parser(response)
        state.completed = true
        callback(value, parse_error)
    end)
    state.children[1] = child
    return handle
end

function BookService:getBookInfo(source, book, callback)
    assert(type(callback) == "function", "BookService book info callback must be a function")
    if type(source) ~= "table" or type(book) ~= "table" then callback(nil, Errors.new(Errors.INVALID_INPUT, "source and book are required")); return composite() end
    local rule = source_rule(source, "ruleBookInfo")
    return self:_single(source, book.url, { baseUrl = book.url, result = "" }, function(response)
        local final_url = response.final_url or book.url
        local parsed, err = self:_book_values(source, response.body, rule, final_url, { baseUrl = final_url, result = response.body })
        if not parsed then return nil, err end
        for key, value in pairs(book) do if parsed[key] == nil or parsed[key] == "" then parsed[key] = value end end
        parsed.id = Models.book(source, { url = parsed.url, name = parsed.name, author = parsed.author }, final_url).id
        return parsed, nil
    end, callback)
end

function BookService:getChapters(source, book, callback)
    assert(type(callback) == "function", "BookService catalog callback must be a function")
    local rule = source_rule(source, "ruleToc")
    local url = book.toc_url or book.url
    local handle, state = composite()
    local chapters, seen, page = {}, {}, 1
    local function finish(value, err)
        if state.cancelled or state.completed then return end
        state.completed = true
        callback(value, err)
    end
    local fetch
    fetch = function(current_url)
        if state.cancelled or state.completed then return end
        if seen[current_url] then finish(nil, Errors.new(Errors.PARSE_ERROR, "catalog pagination loop detected")); return end
        seen[current_url] = true
        local child = self:_request(source, current_url, { baseUrl = current_url, page = page, result = "" }, function(response, request_error)
            if state.cancelled or state.completed then return end
            if request_error then finish(nil, request_error); return end
            local final_url = response.final_url or current_url
            local context = { baseUrl = final_url, page = page, result = response.body }
            local list, list_error = self:_parse(response.body, aliases(rule, { "chapterList", "list" }), context, true)
            if list_error then finish(nil, list_error); return end
            for _, member in ipairs(list or {}) do
                local title, title_error = self:_parse(member, aliases(rule, { "chapterName", "name", "title" }), context, false)
                if title_error then finish(nil, title_error); return end
                local chapter_url, url_error = self:_parse(member, aliases(rule, { "chapterUrl", "url" }), context, false)
                if url_error then finish(nil, url_error); return end
                local vip, vip_error = self:_parse(member, aliases(rule, { "isVip", "vip" }), context, false)
                if vip_error then finish(nil, vip_error); return end
                chapters[#chapters + 1] = Models.chapter(book, source, { index = #chapters + 1, title = title, url = chapter_url, vip = vip }, final_url)
            end
            local next_url, next_error = self:_parse(response.body, aliases(rule, { "nextTocUrl", "nextUrl", "next" }), context, false)
            if next_error then finish(nil, next_error); return end
            if next_url ~= nil and trim(next_url) ~= "" then
                if page >= BookService.MAX_PAGES then
                    finish(nil, Errors.new(Errors.PARSE_ERROR, "catalog pagination exceeds the safe limit", { maximum = BookService.MAX_PAGES }))
                    return
                end
                page = page + 1
                fetch(self.templates:resolve(final_url, next_url))
                return
            end
            finish(chapters, nil)
        end)
        state.children[#state.children + 1] = child
    end
    fetch(url)
    return handle
end

function BookService:getContent(source, book, chapter, callback)
    assert(type(callback) == "function", "BookService content callback must be a function")
    if book.source_ref and source and source.id and book.source_ref ~= source.id then
        local handle, state = composite(); state.completed = true
        callback(nil, Errors.new(Errors.INVALID_INPUT, "content source does not match selected book")); return handle
    end
    local rule = source_rule(source, "ruleContent")
    local handle, state = composite()
    local parts, seen, page = {}, {}, 1
    local function finish(value, err)
        if state.cancelled or state.completed then return end
        state.completed = true
        callback(value, err)
    end
    local fetch
    fetch = function(url)
        if state.cancelled or state.completed then return end
        if seen[url] then finish(nil, Errors.new(Errors.PARSE_ERROR, "content pagination loop detected")); return end
        seen[url] = true
        local child = self:_request(source, url, { baseUrl = url, page = page, result = "" }, function(response, request_error)
            if state.cancelled or state.completed then return end
            if request_error then finish(nil, request_error); return end
            local final_url = response.final_url or url
            local context = { baseUrl = final_url, page = page, result = response.body }
            local content, parse_error = self:_parse(response.body, aliases(rule, { "content", "body" }), context, false)
            if parse_error then finish(nil, parse_error); return end
            if content ~= nil and trim(content) ~= "" then parts[#parts + 1] = tostring(content) end
            local next_url, next_error = self:_parse(response.body, aliases(rule, { "nextContentUrl", "nextUrl", "next" }), context, false)
            if next_error then finish(nil, next_error); return end
            if next_url ~= nil and trim(next_url) ~= "" then
                if page >= BookService.MAX_PAGES then
                    finish(nil, Errors.new(Errors.PARSE_ERROR, "content pagination exceeds the safe limit", { maximum = BookService.MAX_PAGES }))
                    return
                end
                page = page + 1
                fetch(self.templates:resolve(final_url, next_url))
                return
            end
            finish({ content = table.concat(parts, "\n"), next_url = nil, final_url = final_url, pages = page }, nil)
        end)
        state.children[#state.children + 1] = child
    end
    fetch(chapter.url)
    return handle
end

return BookService
