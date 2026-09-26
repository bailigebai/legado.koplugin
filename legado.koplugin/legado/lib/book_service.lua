local Errors = require("legado.lib.errors")
local Json = require("legado.lib.json_codec")
local Models = require("legado.lib.models")
local Capabilities = require("legado.lib.rule_capabilities")

local BookService = {}
BookService.__index = BookService
BookService.DEFAULT_CONCURRENCY = 2
BookService.MAX_CONCURRENCY = 3
-- Fast source matching uses a short-lived burst; normal reading stays conservative.
BookService.FAST_SEARCH_CONCURRENCY = 4
BookService.MAX_PAGES = 20
BookService.MAX_CATALOG_PAGES = 64
BookService.MAX_BACKGROUND_CATALOG_PAGES = 512
BookService.MAX_CATALOG_CHAPTERS = 100000
BookService.MAX_CONTENT_BYTES = 4 * 1024 * 1024
local priorities = { foreground = 1, next = 2, background = 3 }

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

local function response_metadata(response)
    if type(response) ~= "table" then return nil end
    local status = tonumber(response.status)
    local charset = type(response.charset) == "string" and response.charset:lower():match("^([%w._%-]+)$") or nil
    return { http_status = status, charset = charset }
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
        scheduler = options.scheduler or options.request_engine.scheduler,
    }, BookService)
end

function BookService:_parse(input, rule, context, list)
    if not rule or trim(rule) == "" then return list and {} or nil, nil end
    if list and type(self.rules.parseElements) == "function" then
        return self.rules:parseElements(input, rule, context)
    end
    return self.rules:parse(input, rule, context, list == true)
end

function BookService:_parse_url(input, rule, context)
    if not rule or trim(rule) == "" then return nil end
    local values, err = self.rules:parse(input, rule, context, true)
    return values and values[1], err
end

function BookService:_request(source, specification, context, callback)
    local request, build_error = self.templates:build(specification, context, source_headers(source))
    if not request then callback(nil, build_error); return { cancel = function() return false end } end
    local base = context and context.baseUrl or source.bookSourceUrl
    request.url = self.templates:resolve(base or "", request.url)
    request.source_id = source.id or source.bookSourceUrl
    if context and context.request_timeout then request.timeout = context.request_timeout end
    request.priority = context and context.priority or 'background'
    return self.requests:execute(request, callback)
end

function BookService:_rejected(callback, message)
    local handle, state = composite()
    local err = Errors.new(Errors.INVALID_INPUT, message)
    local function deliver()
        if state.cancelled or state.completed then return end
        state.completed = true
        callback(nil, err)
    end
    if self.scheduler and type(self.scheduler.scheduleIn) == "function" then
        local token = self.scheduler:scheduleIn(0, deliver)
        state.children[1] = { cancel = function()
            if self.scheduler and type(self.scheduler.unschedule) == "function" then self.scheduler:unschedule(token) end
            return true
        end }
    else deliver() end
    return handle
end

function BookService:_valid_book_source(source, book)
    return type(source) == "table" and type(book) == "table" and Models.sourceId(source) == book.source_id
end

function BookService:_book_values(source, input, rule, base_url, context)
    local function value(names, field)
        local expression = aliases(rule, names)
        local parse = (field == "url" or field == "cover_url" or field == "toc_url") and self._parse_url or self._parse
        local parsed, err = parse(self, input, expression, context, false)
        if err then return nil, err end
        return parsed
    end
    local data = {}
    local definitions = {
        name = { "name", "bookName" }, author = { "author" }, url = { "bookUrl", "url" },
        cover_url = { "coverUrl", "cover" }, intro = { "intro", "introduction" }, kind = { "kind", "category" },
        last_chapter = { "lastChapter", "latestChapter" }, word_count = { "wordCount" }, toc_url = { "tocUrl" },
    }
    -- Legado keeps recognizable books when supplementary metadata extraction fails.
    local optional = { cover_url = true, intro = true, kind = true, last_chapter = true, word_count = true }
    for field, names in pairs(definitions) do
        local parsed, err = value(names, field)
        if err and not optional[field] then return nil, err end
        if not err then data[field] = parsed end
    end
    return Models.book(source, data, base_url), nil
end

function BookService:_book_list(source, specification, rule, context, callback)
    return self:_single(source, specification, context, function(response)
        local final_url = response.final_url or context.baseUrl
        local parse_context = { key = context.key, page = context.page, baseUrl = final_url, result = response.body }
        local list_rule = aliases(rule, { "bookList", "list" })
        local members, list_error = self:_parse(response.body, list_rule, parse_context, true)
        if list_error then return nil, list_error end
        local books = {}
        for _, member in ipairs(members or {}) do
            local book, book_error = self:_book_values(source, member, rule, final_url, parse_context)
            if book_error then return nil, book_error end
            if book.name ~= "" and book.url ~= "" then books[#books + 1] = book end
        end
        return books
    end, callback)
end

function BookService:_search_source(source, keyword, page, callback)
    local rule = source_rule(source, 'ruleSearch')
    for _, value in ipairs({ source.searchUrl, aliases(rule, { 'bookList', 'list' }) or '',
        aliases(rule, { 'name', 'bookName' }) or '', aliases(rule, { 'author' }) or '', aliases(rule, { 'bookUrl', 'url' }) or '' }) do
        local code, message = Capabilities.findUnsupported(value)
        if code then callback(nil, Errors.new(Errors.UNSUPPORTED_RULE, message, { construct = code })); return {cancel=function() return false end} end
    end
    local timeout = math.max(1, math.min(20, tonumber(setting(self.settings, 'search_timeout', 10)) or 10))
    return self:_book_list(source, source.searchUrl, rule,
        { key = keyword, page = page, baseUrl = source.bookSourceUrl, result = '', request_timeout = timeout }, callback)
end

function BookService:checkUpdates(books, callback, on_progress)
    assert(type(callback) == 'function', 'book update callback is required')
    local handle, state = composite()
    local list, sources = {}, {}
    for _, book in ipairs(type(books) == 'table' and books or {}) do
        if type(book) == 'table' and not book.is_local then list[#list + 1] = book end
    end
    if self.storage.listSources then
        for _, source in ipairs(self.storage:listSources() or {}) do sources[Models.sourceId(source)] = source end
    end
    local next_index, active, checked, updated, failed = 1, 0, 0, 0, 0
    local saved_books, changes, errors, settled = {}, {}, {}, {}
    local function snapshot()
        local result = { total = #list, checked = checked, updated = updated, failed = failed, books = {}, updates = {}, errors = {} }
        for i = 1, #list do
            if saved_books[i] then result.books[#result.books + 1] = saved_books[i] end
            if changes[i] then result.updates[#result.updates + 1] = changes[i] end
            if errors[i] then result.errors[#result.errors + 1] = errors[i] end
        end
        return result
    end
    local pump, pumping
    local function complete(index, saved, patch, err)
        if state.cancelled or state.completed or settled[index] then return end
        settled[index] = true
        active, checked = active - 1, checked + 1
        if err then
            failed = failed + 1
            errors[index] = { book_id = list[index].id, code = err.code or Errors.NETWORK_ERROR, message = safe_message(err) }
        else
            saved_books[index] = saved
            if patch.updated_at then
                updated = updated + 1
                changes[index] = { id = list[index].id, last_chapter = patch.last_chapter, chapter_count = patch.chapter_count, updated_at = patch.updated_at }
            end
        end
        if type(on_progress) == 'function' then pcall(on_progress, snapshot()) end
        pump()
    end
    local function persist(index, latest, chapter_count)
        if state.cancelled or settled[index] then return end
        local book = list[index]
        local patch = { last_chapter = latest, chapter_count = chapter_count, last_checked_at = os.time() }
        if latest ~= (book.last_chapter or '') or chapter_count ~= book.chapter_count then patch.updated_at = patch.last_checked_at end
        local ok, saved, err = pcall(self.storage.updateBook, self.storage, book.id, patch)
        complete(index, saved, patch, not ok and Errors.new(Errors.STORAGE_ERROR, 'book update could not be saved')
            or (not saved and (err or Errors.new(Errors.STORAGE_ERROR, 'book update could not be saved'))) or nil)
    end
    local function request(index, method, source, book, done, options)
        local completed = false
        local ok, child, err = pcall(method, self, source, book, function(...)
            if completed or state.cancelled or settled[index] then return end
            completed = true
            done(...)
        end, options)
        if state.cancelled then if child and child.cancel then pcall(child.cancel, child) end
        elseif not completed and (not ok or not child) then
            complete(index, nil, nil, type(err) == 'table' and err or Errors.new(Errors.NETWORK_ERROR, 'book update request did not start'))
        elseif not completed then state.children[#state.children + 1] = child end
    end
    pump = function()
        if pumping or state.cancelled or state.completed then return end
        pumping = true
        while not state.cancelled and active < concurrency(self.settings) and next_index <= #list do
            local index, book = next_index, list[next_index]
            next_index, active = next_index + 1, active + 1
            local source = sources[book.source_id] or (self.storage.getSource and self.storage:getSource(book.source_id))
            if not source or source.enabled == false then complete(index, nil, nil, Errors.new(Errors.INVALID_INPUT, 'book source is unavailable'))
            else
                local fresh_book = shallow_copy(book)
                -- getBookInfo preserves missing metadata from its input. An old
                -- latest chapter must not look like a newly observed value.
                fresh_book.last_chapter = nil
                request(index, self.getBookInfo, source, fresh_book, function(info, err)
                if err or not info then complete(index, nil, nil, err or Errors.new(Errors.PARSE_ERROR, 'book details are empty')); return end
                local latest = trim(info.last_chapter)
                local previous_count = tonumber(book.chapter_count)
                if latest ~= '' and latest == trim(book.last_chapter) and previous_count and previous_count > 0
                    and previous_count < math.huge and previous_count % 1 == 0 then
                    persist(index, latest, book.chapter_count); return
                end
                local candidate = shallow_copy(book)
                if info.toc_url and info.toc_url ~= '' then candidate.toc_url = info.toc_url end
                request(index, self.getChapters, source, candidate, function(chapters, catalog_error, metadata)
                    if catalog_error or type(chapters) ~= 'table' or #chapters == 0 or (metadata and metadata.catalog_complete == false) then
                        complete(index, nil, nil, catalog_error or Errors.new(Errors.PARSE_ERROR, 'update catalog is incomplete')); return
                    end
                    if latest == '' then latest = chapters[#chapters] and chapters[#chapters].title or book.last_chapter or '' end
                    persist(index, latest, #chapters)
                end, { max_pages = BookService.MAX_CATALOG_PAGES })
            end) end
        end
        pumping = false
        if not state.cancelled and not state.completed and checked == #list then
            state.completed = true
            callback(snapshot(), #list > 0 and failed == #list and aggregate_error('all book update checks failed') or nil)
        end
    end
    pump()
    return handle
end

function BookService:exploreCategories(source)
    local value = source and source.exploreUrl
    if value == nil or value == "" then return {} end
    local entries = {}
    if type(value) == "table" then
        local size = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                return nil, Errors.new(Errors.INVALID_INPUT, "discovery categories must be an array")
            end
            size = size + 1
        end
        if size ~= #value then return nil, Errors.new(Errors.INVALID_INPUT, "discovery categories must be an array") end
        entries = value
    elseif type(value) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "exploreUrl must be a string or array")
    elseif trim(value):sub(1, 1) == "[" then
        local ok, decoded = pcall(Json.decode, value)
        if not ok or not Json.isArray(decoded) then return nil, Errors.new(Errors.INVALID_INPUT, "invalid discovery category JSON") end
        entries = decoded
    else
        local code, message = Capabilities.findUnsupported(value)
        if code and (not value:find("::", 1, true) or trim(value):sub(1, 1) == "@" or trim(value):sub(1, 1) == "<") then
            return nil, Errors.new(Errors.UNSUPPORTED_RULE, message)
        end
        for line in value:gsub("&&", "\n"):gmatch("[^\r\n]+") do
            local title, url = line:match("^(.-)::(.*)$")
            if trim(line) ~= "" then entries[#entries + 1] = { title = trim(title or line), url = url and trim(url) or nil } end
        end
    end
    local categories, valid, first_error = {}, 0, nil
    local json_null = Json.decode("null")
    for index, entry in ipairs(entries) do
        local category = type(entry) == "table" and shallow_copy(entry) or {}
        category.error = nil
        if category.url == json_null or category.url == "" then category.url = nil end
        if type(category.title) ~= "string" or trim(category.title) == ""
            or (category.url ~= nil and type(category.url) ~= "string") then
            category.error = Errors.new(Errors.INVALID_INPUT, "invalid discovery category")
        elseif category.url then
            local code, message = Capabilities.findUnsupported(category.url)
            if code then category.error = Errors.new(Errors.UNSUPPORTED_RULE, message)
            else
                local _, err = self.templates:build(category.url, { page = 1, baseUrl = source.bookSourceUrl, result = "" })
                category.error = err
            end
        end
        category.title = type(category.title) == "string" and trim(category.title) or ("分类 " .. index)
        if category.error then first_error = first_error or category.error else valid = valid + 1 end
        categories[#categories + 1] = category
    end
    if #categories > 0 and valid == 0 then return nil, first_error end
    return categories
end

function BookService:explore(source_id, category_index, page, callback)
    local source = self.storage:getSource(source_id)
    if not source or source.enabled == false or source.enabledExplore == false then
        return self:_rejected(callback, "discovery source is unavailable")
    end
    local categories, err = self:exploreCategories(source)
    if err then callback(nil, err); return { cancel = function() return false end } end
    local category = categories[category_index]
    if category and category.error then callback(nil, category.error); return { cancel = function() return false end } end
    if not category or not category.url then return self:_rejected(callback, "discovery category has no URL") end
    page = math.max(1, math.floor(tonumber(page) or 1))
    local rule = source_rule(source, "ruleExplore")
    if not aliases(rule, { "bookList", "list" }) then rule = source_rule(source, "ruleSearch") end
    return self:_book_list(source, category.url, rule,
        { page = page, baseUrl = source.bookSourceUrl, result = "" }, function(books, request_error)
            local groups = {}
            for _, book in ipairs(books or {}) do groups[#groups + 1] = { book = book, alternatives = { book } } end
            callback({ groups = groups, errors = {}, page = page, title = category.title }, request_error)
        end)
end

function BookService:_selected_sources(source_ids)
    local output = {}
    if type(source_ids) == "table" and #source_ids > 0 then
        for _, id in ipairs(source_ids) do
            local source = self.storage:getSource(id)
            if source and source.enabled ~= false then output[#output + 1] = source end
        end
    else
        for _, source in ipairs(self.storage:listSources() or {}) do
            if source.enabled ~= false then output[#output + 1] = source end
        end
    end
    return output
end

function BookService:search(keyword, source_ids, page, callback, on_progress)
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
    if self.fast_search_concurrency then
        limit = math.max(limit, math.min(BookService.FAST_SEARCH_CONCURRENCY,
            math.floor(tonumber(self.fast_search_concurrency) or limit)))
    end
    local next_index, active, finished, succeeded = 1, 0, 0, 0
    local results, failures, traces, delivered = {}, {}, {}, {}

    -- ponytail: rebuild snapshots for stable source order; cache groups if large searches slow the UI.
    local function snapshot()
        local groups, by_key, seen = {}, {}, {}
        local exact, other = {}, {}
        local normalized = keyword:lower()
        for source_index = 1, #sources do
            for _, book in ipairs(results[source_index] or {}) do
                local identity = book.source_id .. "\n" .. book.url
                if not seen[identity] then
                    seen[identity] = true
                    local key = Models.groupKey(book)
                    local group = by_key[key]
                    if not group then
                        group = { book = book, alternatives = {}, key = key }
                        by_key[key] = group
                        local bucket = (trim(book.name):lower() == normalized or trim(book.author):lower() == normalized) and exact or other
                        bucket[#bucket + 1] = group
                    end
                    group.alternatives[#group.alternatives + 1] = book
                end
            end
        end
        for _, group in ipairs(exact) do groups[#groups + 1] = group end
        for _, group in ipairs(other) do groups[#groups + 1] = group end
        local errors = {}
        for index = 1, #sources do if failures[index] then errors[#errors + 1] = failures[index] end end
        return { groups = groups, errors = errors, page = page, keyword = keyword,
            total = #sources, completed = finished, succeeded = succeeded, failed = finished - succeeded }
    end

    local function finish()
        if state.cancelled or state.completed or finished < #sources then return end
        state.completed = true
        local result = snapshot()
        local err
        if #sources > 0 and result.failed == #sources then err = aggregate_error("all selected sources failed", { count = result.failed }) end
        local trace = #sources == 1 and traces[1] or nil
        callback(result, err, trace)
    end

    local pump, pumping
    pump = function()
        if state.cancelled or state.completed or pumping then return end
        pumping = true
        while not state.cancelled and not state.completed and active < limit and next_index <= #sources do
            local index, source = next_index, sources[next_index]
            next_index, active = next_index + 1, active + 1
            local child = self:_search_source(source, keyword, page, function(books, err, metadata)
                if state.cancelled or state.completed or delivered[index] then return end
                delivered[index] = true
                active, finished = active - 1, finished + 1
                traces[index] = metadata
                if err then
                    failures[index] = { source_id = Models.sourceId(source), source_name = trim(source.bookSourceName), code = err.code or Errors.NETWORK_ERROR, message = safe_message(err) }
                else results[index] = books or {}; succeeded = succeeded + 1 end
                if type(on_progress) == "function" then on_progress(snapshot()) end
                pump(); finish()
            end)
            state.children[#state.children + 1] = child
        end
        pumping = false
        finish()
    end
    pump()
    return handle
end

function BookService:_single(source, specification, context, parser, callback)
    local handle, state = composite()
    local child = self:_request(source, specification, context, function(response, err)
        if state.cancelled or state.completed then return end
        if err then state.completed = true; callback(nil, err); return end
        local value, parse_error = parser(response)
        state.completed = true
        callback(value, parse_error, response_metadata(response))
    end)
    state.children[1] = child
    return handle
end

function BookService:getBookInfo(source, book, callback)
    assert(type(callback) == "function", "BookService book info callback must be a function")
    if not self:_valid_book_source(source, book) then return self:_rejected(callback, "source does not own the selected book") end
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

function BookService:getChapters(source, book, callback, options)
    assert(type(callback) == "function", "BookService catalog callback must be a function")
    if not self:_valid_book_source(source, book) then return self:_rejected(callback, "source does not own the selected book") end
    local rule = source_rule(source, "ruleToc")
    -- This collection's Forest rule includes the repeated "latest chapters" preview.
    -- Use the final (正文) list on that verified site, including already imported sources.
    if rule.chapterList=='class.section-list fix@li' and tostring(source.bookSourceUrl):match('^https?://23%.224%.242%.55[/#]') then
        rule=shallow_copy(rule)
        rule.chapterList='.section-list.fix:last li'
    end
    local chapter_list = trim(aliases(rule, { "chapterList", "list" }))
    local reverse = chapter_list:sub(1, 1) == "-"
    if reverse then chapter_list = trim(chapter_list:sub(2)) end
    local url = book.toc_url or book.url
    local handle, state = composite()
    options = options or {}
    local max_pages = math.max(1, math.min(BookService.MAX_BACKGROUND_CATALOG_PAGES,tonumber(options.max_pages)
        or (options.background_catalog and BookService.MAX_BACKGROUND_CATALOG_PAGES or BookService.MAX_CATALOG_PAGES)))
    local max_chapters = tonumber(options.max_chapters)
    -- In a newest-first catalog the oldest chapter is only known after every
    -- page arrives. A startup chapter cap would open a late chapter as #1.
    if reverse then max_chapters = nil end
    if max_chapters then max_chapters = math.max(1, math.floor(max_chapters)) end
    local chapters, seen, chapter_urls, page, trace = {}, {}, {}, 1, nil
    local parse_job
    local function cancel_parse()
        local job=parse_job;parse_job=nil
        if job and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,job) end
    end
    state.children[#state.children+1]={cancel=cancel_parse}
    local function finish(value, err)
        if state.cancelled or state.completed then return end
        cancel_parse()
        state.completed = true
        if reverse and value then
            for i = 1, math.floor(#value / 2) do value[i], value[#value - i + 1] = value[#value - i + 1], value[i] end
            for i, chapter in ipairs(value) do chapter.index = i end
        end
        callback(value, err, trace)
    end
    local function guarded(action)
        if state.cancelled or state.completed then return end
        local ok=pcall(action)
        if not ok then finish(nil,Errors.new(Errors.PARSE_ERROR,'catalog processing failed')) end
    end
    local function progress()
        -- Append-only ordered prefix; reversed catalogs cannot expose a stable
        -- first chapter until the final website page is known.
        if options.on_progress then pcall(options.on_progress,page,#chapters,not reverse and chapters or nil) end
    end
    local fetch
    fetch = function(current_url, attempt)
        if state.cancelled or state.completed then return end
        attempt=attempt or 0
        if attempt==0 and seen[current_url] then finish(nil, Errors.new(Errors.PARSE_ERROR, "catalog pagination loop detected")); return end
        seen[current_url] = true
        trace = nil
        local child = self:_request(source, current_url, { baseUrl = current_url, page = page, result = "" }, function(response, request_error)
            guarded(function()
                if state.cancelled or state.completed then return end
                if request_error then
                    local code=type(request_error)=='table' and request_error.code
                    local details=type(request_error)=='table' and request_error.details
                    local status=details and tonumber(details.status)
                    local transient=code==Errors.TIMEOUT or code==Errors.NETWORK_ERROR
                        and not (details and details.reason) and (not status or status>=500)
                    if options.background_catalog and transient and attempt<2 and self.scheduler and self.scheduler.scheduleIn then
                        -- Retry this page only; keep the parsed prefix and page number.
                        parse_job=function()parse_job=nil;guarded(function()fetch(current_url,attempt+1)end)end
                        self.scheduler:scheduleIn(attempt==0 and 1 or 3,parse_job)
                    else finish(nil,request_error) end
                    return
                end
                trace = response_metadata(response)
                local final_url = response.final_url or current_url
                local context = { baseUrl = final_url, page = page, result = response.body }
                local list, list_error
                if self.rules.parseCatalogElements then
                    list,list_error=self.rules:parseCatalogElements(response.body,chapter_list,context)
                else list,list_error=self:_parse(response.body,chapter_list,context,true) end
                if list_error then finish(nil, list_error); return end
                list=list or {}
                local cursor=1
                local batch
                batch=function()
                    if state.cancelled or state.completed then return end
                    local remaining=self.scheduler and type(self.scheduler.scheduleIn)=='function' and 15 or math.huge
                    while cursor<=#list and remaining>0 and (not max_chapters or #chapters<max_chapters) do
                        if state.cancelled then return end
                        local member=list[cursor];cursor=cursor+1;remaining=remaining-1
                        local title, title_error = self:_parse(member, aliases(rule, { "chapterName", "name", "title" }), context, false)
                        if title_error then finish(nil, title_error); return end
                        local chapter_url, url_error = self:_parse_url(member, aliases(rule, { "chapterUrl", "url" }), context)
                        if url_error then finish(nil, url_error); return end
                        local vip, vip_error = self:_parse(member, aliases(rule, { "isVip", "vip" }), context, false)
                        if vip_error then finish(nil, vip_error); return end
                        local chapter=Models.chapter(book, source, { index = #chapters + 1, title = title, url = chapter_url, vip = vip }, final_url)
                        if not chapter_urls[chapter.url] and (not max_chapters or (trim(chapter_url) ~= "" and chapter.url:match("^https?://"))) then
                            if #chapters>=BookService.MAX_CATALOG_CHAPTERS then
                                finish(nil,Errors.new(Errors.PARSE_ERROR,'catalog exceeds the chapter limit',{maximum=BookService.MAX_CATALOG_CHAPTERS}))
                                return
                            end
                            chapters[#chapters+1]=chapter; chapter_urls[chapter.url]=true
                        end
                    end
                    if max_chapters and #chapters>=max_chapters and cursor<=#list then
                        progress()
                        trace.catalog_complete = false
                        finish(chapters, nil)
                        return
                    end
                    if cursor<=#list then
                        progress()
                        if state.cancelled or state.completed then return end
                        parse_job=function() parse_job=nil;guarded(batch) end
                        -- Zero-delay tasks are drained in the same KOReader sweep.
                        self.scheduler:scheduleIn(.01,parse_job)
                        return
                    end
                    local next_url, next_error = self:_parse_url(response.body, aliases(rule, { "nextTocUrl", "nextUrl", "next" }), context)
                    if next_error then finish(nil, next_error); return end
                    progress()
                    if state.cancelled then return end
                    -- Some mobile sites expose both "previous" and "next" links with
                    -- the same class.  The source rule then yields the already visited
                    -- previous link; choose the last unvisited candidate.
                    if next_url and seen[self.templates:resolve(final_url, next_url)] then
                        local next_rule = aliases(rule, { "nextTocUrl", "nextUrl", "next" })
                        local candidates = self.rules:parse(response.body, next_rule, context, true)
                        if type(candidates) == "table" then
                            next_url = nil
                            for i = #candidates, 1, -1 do
                                local candidate = candidates[i]
                                if type(candidate) == "string" and trim(candidate) ~= "" then
                                    local resolved = self.templates:resolve(final_url, candidate)
                                    if not seen[resolved] then next_url = candidate; break end
                                end
                            end
                        end
                    end
                    if next_url ~= nil and trim(next_url) ~= "" then
                        if max_chapters and #chapters >= max_chapters then trace.catalog_complete=false; finish(chapters, nil); return end
                        if page >= max_pages then
                            if reverse then finish(nil, Errors.new(Errors.PARSE_ERROR, 'reversed catalog is incomplete; the first chapter cannot be located', { maximum = max_pages }))
                            elseif options.max_pages then trace.catalog_complete=false; finish(chapters, nil)
                            else finish(nil, Errors.new(Errors.PARSE_ERROR, "catalog pagination exceeds the safe limit", { maximum = max_pages })) end
                            return
                        end
                        page = page + 1
                        fetch(self.templates:resolve(final_url, next_url))
                        return
                    end
                    trace.catalog_complete=true
                    finish(chapters, nil)
                end
                batch()
            end)
        end)
        state.children[#state.children + 1] = child
    end
    guarded(function() fetch(url) end)
    return handle
end

function BookService:getContent(source, book, chapter, callback, options)
    assert(type(callback) == "function", "BookService content callback must be a function")
    if not self:_valid_book_source(source, book)
        or type(chapter) ~= "table" or chapter.source_id ~= book.source_id or chapter.book_id ~= book.id then
        return self:_rejected(callback, "chapter does not belong to the selected source and book")
    end
    local rule = source_rule(source, "ruleContent")
    local handle, state = composite()
    local priority = options and options.priority or 'foreground'
    if not priorities[priority] then priority = 'foreground' end
    function handle:promote(value)
        if state.cancelled or state.completed or not priorities[value] or priorities[value] >= priorities[priority] then return false end
        priority = value
        for _, child in ipairs(state.children) do
            if child and type(child.promote) == 'function' then pcall(child.promote, child, value) end
        end
        return true
    end
    local parts, seen, page, trace = {}, {}, 1, nil
    local bytes = 0
    local function finish(value, err)
        if state.cancelled or state.completed then return end
        state.completed = true
        callback(value, err, trace)
    end
    local fetch
    fetch = function(url)
        if state.cancelled or state.completed then return end
        if seen[url] then finish(nil, Errors.new(Errors.PARSE_ERROR, "content pagination loop detected")); return end
        seen[url] = true
        trace = nil
        local child = self:_request(source, url, { baseUrl = url, page = page, result = "", priority = priority }, function(response, request_error)
            if state.cancelled or state.completed then return end
            if request_error then finish(nil, request_error); return end
            trace = response_metadata(response)
            local final_url = response.final_url or url
            if final_url ~= url and seen[final_url] then finish(nil, Errors.new(Errors.PARSE_ERROR, 'content pagination loop detected')); return end
            seen[final_url] = true
            local context = { baseUrl = final_url, page = page, result = response.body }
            local expression = aliases(rule, { "content", "body" })
            local values, parse_error = self.rules:parse(response.body, expression or "", context, true)
            if parse_error then finish(nil, parse_error); return end
            local before = #parts
            for _, content in ipairs(values or {}) do
                if type(content) ~= "string" then finish(nil, Errors.new(Errors.PARSE_ERROR, "chapter content must be text")); return end
                if trim(content) ~= "" then
                    bytes = bytes + #content + (#parts > 0 and 1 or 0)
                    if bytes > BookService.MAX_CONTENT_BYTES then
                        finish(nil, Errors.new(Errors.RESPONSE_TOO_LARGE, 'chapter content exceeds byte limit', { max_bytes = BookService.MAX_CONTENT_BYTES }))
                        return
                    end
                    parts[#parts + 1] = content
                end
            end
            if #parts == before then finish(nil, Errors.new(Errors.PARSE_ERROR, 'chapter page is empty')); return end
            local next_url, next_error = self:_parse_url(response.body, aliases(rule, { "nextContentUrl", "nextUrl", "next" }), context)
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
