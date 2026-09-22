local A = require('assertions')
local Service = require('legado.lib.book_service')
local Models = require('legado.lib.models')
local Fakes = require('support.network_fakes')
local count = 0
local function eq(want, got, why) count = count + 1; A.equal(want, got, why) end

do
    local source = { id = 'site', searchUrl = 'https://books.test/search', ruleSearch = { bookList = '@js:java.ajax(result)', name = 'text', bookUrl = 'href' } }
    local requests = 0
    local service = Service.new { storage = {}, rule_engine = {}, url_template = { build = function(_, url) return { url = url } end, resolve = function(_, _, url) return url end },
        request_engine = { execute = function() requests = requests + 1; return {} end } }
    local err
    service:_search_source(source, 'Book', 1, function(_, value) err = value end)
    eq(0, requests, 'provably unsupported search list is rejected before contacting the website')
    eq('UNSUPPORTED_RULE', err and err.code, 'preflight rejection remains a normal per-source search failure')
end

do
    local source = { id = 'site', searchUrl = 'https://books.test/search', ruleSearch = { bookList = '$.items', name = '$.name', bookUrl = '$.url' } }
    local captured = {}
    local service = Service.new { storage = {}, rule_engine = {}, settings = { get = function(_, key) return key == 'search_timeout' and 7 or 20 end },
        url_template = { build = function(_, url) return { url = url } end, resolve = function(_, _, url) return url end },
        request_engine = { execute = function(_, request) captured[#captured + 1] = request; return {} end } }
    service:_search_source(source, 'Book', 1, function() end)
    eq(7, captured[1].timeout, 'search uses its own timeout without changing ordinary reading')
    service:_request(source, 'https://books.test/chapter', {}, function() end)
    eq(nil, captured[2].timeout, 'ordinary chapter request keeps the existing network timeout')
end

local function updates_fixture()
    local source = { id = 'site', bookSourceUrl = 'https://books.test/' }
    local books, details, catalogs, writes = {}, {}, {}, {}
    for i = 1, 3 do books[i] = { id = 'b' .. i, source_id = Models.sourceId(source), url = 'https://books.test/' .. i, last_chapter = 'Old', chapter_count = 10, custom_categories = { 'Keep' } } end
    local storage = {
        getSource = function(_, id) if id == Models.sourceId(source) then return source end end,
        updateBook = function(_, id, patch)
            writes[#writes + 1] = { id = id, patch = patch }
            local book = {}; for key, value in pairs(books[tonumber(id:sub(2))]) do book[key] = value end
            for key, value in pairs(patch) do book[key] = value end
            return book
        end,
    }
    local service = Service.new { storage = storage, rule_engine = {}, request_engine = {}, url_template = {} }
    function service:getBookInfo(_, book, cb)
        details[book.id] = { callback = cb, cancelled = false, book = book }
        return { cancel = function() details[book.id].cancelled = true end }
    end
    function service:getChapters(_, book, cb)
        catalogs[book.id] = { callback = cb, cancelled = false }
        return { cancel = function() catalogs[book.id].cancelled = true end }
    end
    return service, books, details, catalogs, writes
end

do
    local service, books, details, catalogs, writes = updates_fixture()
    eq('function', type(service.checkUpdates), 'book update service is available to the shelf')
    local result, progress
    service:checkUpdates(books, function(value) result = value end, function(value) progress = value end)
    eq(nil, details.b3, 'batch updates retain the existing two-request concurrency')
    details.b1.callback({ last_chapter = 'Old' })
    eq(nil, catalogs.b1, 'unchanged latest chapter reuses the known count')
    eq(1, progress.checked, 'each terminal book updates progress')
    eq('function', type(details.b3.callback), 'completed book frees one slot')
    details.b2.callback(nil, { code = 'TIMEOUT' })
    details.b3.callback({ last_chapter = 'New', toc_url = 'https://books.test/3/toc' })
    local chapters = {}; for i = 1, 12 do chapters[i] = { title = 'Chapter ' .. i } end
    catalogs.b3.callback(chapters, nil, { catalog_complete = true })
    eq(3, result.checked, 'failed book does not prevent completing other checks')
    eq(1, result.failed, 'per-book failure remains visible')
    eq(1, result.updated, 'only changed book counts as updated')
    eq(12, result.updates[1].chapter_count, 'update count is measured from the catalog')
    eq('New', result.updates[1].last_chapter, 'fresh latest chapter is persisted')
    eq('Keep', result.books[1].custom_categories[1], 'metadata patch preserves custom categories')
    eq(nil, writes[2].patch.fraction, 'book checks never overwrite reading progress')
    eq(nil, writes[2].patch.chapter_index, 'book checks never move the reading chapter')
end

do
    local service, books, details, _, writes = updates_fixture()
    local delivered = 0
    local handle = service:checkUpdates(books, function() delivered = delivered + 1 end)
    handle:cancel(); details.b1.callback({ last_chapter = 'Old' })
    eq(true, details.b1.cancelled, 'cancel releases an active detail request')
    eq(true, details.b2.cancelled, 'cancel releases all active book checks')
    eq(0, #writes, 'late callbacks after cancellation do not write book metadata')
    eq(nil, details.b3, 'cancellation does not start another book')
    eq(0, delivered, 'cancelled batch does not complete into a closed screen')
end

do
    local Matches = require('legado.ui.source_matches')
    local service = { storage = { listSources = function() return {} end }, requests = { concurrency = 2 }, search = function() return nil end }
    local view = Matches.new { service = service, book = { name = 'Book', author = 'Author' }, scheduler = Fakes.scheduler() }
    view:start()
    eq(false, view.loading, 'a search that fails to start cannot leave source matching spinning')
    eq(2, service.requests.concurrency, 'failed source matching restores the ordinary request limit')
    eq(nil, service.fast_search_concurrency, 'failed source matching releases burst search mode')
    view:close()
end

do
    local service, books, details, catalogs, writes = updates_fixture()
    local result
    service:checkUpdates({ books[1] }, function(value) result = value end)
    details.b1.callback({ last_chapter = 'New' })
    catalogs.b1.callback({}, nil, { catalog_complete = true })
    eq(1, result.failed, 'an empty parsed catalog is a failed update check')
    eq(0, #writes, 'empty catalog never erases the previous chapter count')
end

do
    local service, books, details, catalogs = updates_fixture()
    service:checkUpdates({ books[1] }, function() end)
    -- Production getBookInfo fills absent fields from the supplied book.
    details.b1.callback({ last_chapter = details.b1.book.last_chapter or '' })
    eq(true, catalogs.b1 ~= nil, 'missing fresh latest-chapter metadata cannot reuse an inherited old chapter title')
end

do
    local service, books, details, catalogs, writes = updates_fixture()
    local result, final_error
    service:checkUpdates({ books[1] }, function(value, err) result, final_error = value, err end)
    details.b1.callback({ last_chapter = 'New' })
    catalogs.b1.callback({ { title = 'New' } }, nil, { catalog_complete = false })
    eq(1, result.failed, 'a capped catalog is a visible failed update')
    eq('NETWORK_ERROR', final_error and final_error.code, 'all failed checks return an aggregate error')
    eq(0, #writes, 'partial catalog cannot replace a complete chapter count')
end

do
    local service, books, details, catalogs = updates_fixture()
    local result
    service.storage.updateBook = function() return nil, { code = 'STORAGE_ERROR' } end
    service:checkUpdates({ books[1] }, function(value) result = value end)
    details.b1.callback({ last_chapter = 'Old' })
    eq('STORAGE_ERROR', result.errors[1].code, 'failed persistence remains a per-book error')
    eq(0, result.updated, 'failed storage cannot report a successful book update')
end

for _, throws in ipairs({ false, true }) do
    local service, books = updates_fixture()
    local result
    service.getBookInfo = function() if throws then error('start failure') end end
    service:checkUpdates(books, function(value) result = value end)
    eq(3, result and result.failed, 'nil and throwing detail starters settle every queued book')
end

do
    local service, books, details = updates_fixture()
    local source = service.storage:getSource(books[1].source_id)
    service.storage.getSource = function() error('must resolve imported model identity') end
    service.storage.listSources = function() return { source } end
    service:checkUpdates({ books[1], { is_local = true }, false }, function() end)
    eq(true, details.b1 ~= nil, 'imported model source identity resolves through the current source list')
    eq(nil, details.b2, 'local and malformed bookshelf entries do not start requests')
end

do
    local Matches = require('legado.ui.source_matches')
    local source = { bookSourceUrl = 'https://books.test/' }
    local book = Models.book(source, { name = 'Book', author = 'Author', url = '/book' })
    local service = { storage = { listSources = function() return { source } end }, requests = { concurrency = 2 } }
    local search_done, catalog_limit
    function service:search(_, _, _, callback) search_done = callback; return { cancel = function() end } end
    function service:getChapters() catalog_limit = self.requests.concurrency; return nil end
    local view = Matches.new { service = service, book = book, scheduler = Fakes.scheduler() }
    view:start()
    search_done({ groups = { { book = book } } })
    eq(2, catalog_limit, 'catalog probes begin after temporary search concurrency is restored')
    eq(false, view.loading, 'nil catalog starter settles source matching')
    eq('REQUEST_ERROR', view.results[1].catalog_error, 'failed catalog startup is visible on its matching source')
    eq(nil, service.fast_search_concurrency, 'completed source matching leaves no temporary search mode')
    view:close()
end

return count
