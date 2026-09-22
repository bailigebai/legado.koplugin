local A = require('assertions')
local Loader = require('legado.lib.cover_loader')
local Safe = require('legado.lib.safe_functions')
local count = 0
local function eq(want, got, why) count = count + 1; A.equal(want, got, why) end
local png = Safe.functions.base64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJf8AAAAASUVORK5CYII=')
local book = { id = 'b', source_id = 's', url = 'https://books.test/1?private=hidden', cover_url = 'https://covers.test/b' }
local function fixture()
    local f = { files = {}, requests = {}, writes = 0 }
    f.loader = Loader.new { root = 'covers', fs = {
        ensureDirectory = function() return true end,
        readBounded = function(_, path) return f.files[path] end,
        atomicWrite = function(_, path, body) f.files[path] = body; f.writes = f.writes + 1; return true end,
    }, request_engine = { execute = function(_, request, callback)
        local entry = { request = request, callback = callback, cancelled = 0 }
        f.requests[#f.requests + 1] = entry
        return { cancel = function() entry.cancelled = entry.cancelled + 1 end }
    end } }
    return f
end
do
    local f = fixture(); local first, second, first_path = 0, 0, nil
    f.loader:load(book, function(path) first = first + 1; first_path = path end)
    local joined = f.loader:load(book, function() second = second + 1 end)
    eq(1, #f.requests, 'same cover joins one in-flight request')
    eq(true, f.requests[1].request.binary, 'cover requests preserve binary bytes even without an image MIME type')
    joined:cancel(); eq(0, f.requests[1].cancelled, 'closing one cover subscriber preserves the other subscriber')
    f.requests[1].callback({ body = png, headers = { ['content-type'] = 'application/octet-stream' } })
    eq(true, first_path and first_path:match('%.png$') ~= nil, 'actual bytes determine the cached image extension')
    eq(1, first, 'remaining cover subscriber receives the image once')
    eq(0, second, 'closed subscriber receives no late result')
    eq(1, f.writes, 'shared image is written once')
    local cached_path
    f.loader:load(book, function(path) cached_path = path end)
    eq(first_path, cached_path, 'valid cached image is reusable')
    eq(1, #f.requests, 'cached image needs no second request')
end
do
    local f = fixture(); local error_value
    f.loader:load(book, function(_, err) error_value = err end)
    f.requests[1].callback({ body = '<html>Access denied</html>', headers = { ['content-type'] = 'image/jpeg' } })
    eq('PARSE_ERROR', error_value and error_value.code, 'HTML cannot masquerade as a cached cover')
    eq(0, f.writes, 'non-image response never poisons the image cache')
end
do
    local f = fixture(); local delivered = 0
    local a = f.loader:load(book, function() delivered = delivered + 1 end)
    local b = f.loader:load(book, function() delivered = delivered + 1 end)
    a:cancel(); b:cancel()
    eq(1, f.requests[1].cancelled, 'last subscriber cancels the actual image request once')
    f.requests[1].callback({ body = png, headers = {} })
    eq(0, delivered, 'cancelled image request cannot deliver stale results')
    eq(0, f.writes, 'cancelled image request cannot write stale data')
    f.loader:load(book, function() end)
    eq(2, #f.requests, 'a later cover view can retry after cancellation')
end
do
    local Fakes = require('support.network_fakes')
    local scheduler, saved_bytes, received_path = Fakes.scheduler(), nil, nil
    local engine = require('legado.lib.request_engine').new {
        transport = Fakes.transport({ { status = 200, headers = { ['content-type'] = 'application/octet-stream; charset=gbk' }, chunks = { png } } }),
        scheduler = scheduler, subprocess = Fakes.subprocess { enabled = false },
        charset_converter = function() return 'converted text' end,
        logger = { debug = function() end, warn = function() end },
    }
    local loader = Loader.new { request_engine = engine, root = 'covers', fs = {
        ensureDirectory = function() return true end,
        atomicWrite = function(_, _, bytes) saved_bytes = bytes; return true end,
    } }
    loader:load(book, function(path) received_path = path end)
    scheduler:runAll()
    eq(png, saved_bytes, 'binary cover response bypasses charset conversion through the real request engine')
    eq(true, received_path and received_path:match('%.png$') ~= nil, 'real request engine delivers a reusable cover path')
end
for _, throws in ipairs({ false, true }) do
    local f = fixture(); local saved_error
    f.loader.fs.atomicWrite = function() if throws then error('disk failure') end return false end
    f.loader:load(book, function(_, err) saved_error = err end)
    local ok = pcall(f.requests[1].callback, { body = png })
    eq(true, ok, 'cover persistence failure stays inside its asynchronous request')
    eq('STORAGE_ERROR', saved_error and saved_error.code, 'failed and throwing cover writes return a storage error')
    f.loader:load(book, function() end)
    eq(2, #f.requests, 'cover write failure releases in-flight state for retry')
end
return count
