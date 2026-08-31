local assertx = require("assertions")

local function deep_equal(expected, actual, message)
    if type(expected) ~= type(actual) then
        error((message or "types differ") .. ": expected " .. type(expected) .. ", got " .. type(actual), 2)
    end
    if type(expected) ~= "table" then
        assertx.equal(expected, actual, message)
        return
    end
    for key, value in pairs(expected) do
        deep_equal(value, actual[key], (message or "tables differ") .. " at " .. tostring(key))
    end
    for key in pairs(actual) do
        assertx.truthy(expected[key] ~= nil, (message or "tables differ") .. " unexpected key " .. tostring(key))
    end
end

local function temporary_path(label)
    local path = assert(os.tmpname())
    os.remove(path)
    return path .. "-legado-" .. label
end

local function cleanup(path)
    os.remove(path)
    os.remove(path .. ".tmp")
end

local Errors = require("legado.lib.errors")
local Logger = require("legado.lib.logger")
local Fs = require("legado.lib.fs")
local Settings = require("legado.lib.settings")
local Storage = require("legado.lib.storage")
local Identity = require("legado.lib.identity")

local app_error = Errors.new(Errors.INVALID_INPUT, "missing source", { field = "url" })
assertx.equal(Errors.INVALID_INPUT, app_error.code, "structured error preserves code")
assertx.equal("missing source", app_error.message, "structured error preserves message")
assertx.equal("url", app_error.details.field, "structured error preserves details")
assertx.equal("INVALID_INPUT: missing source", tostring(app_error), "structured error is printable")

local redacted = Logger.redact({
    Cookie = "session=synthetic-secret",
    nested = {
        authorization = "Bearer synthetic-secret",
        password = "synthetic-secret",
        request_url = "https://example.test/search?token=synthetic-secret&api-key=also-secret&page=2",
        chapter_body = "synthetic chapter body must not be logged",
    },
})
assertx.equal("[REDACTED]", redacted.Cookie, "cookie is redacted case-insensitively")
assertx.equal("[REDACTED]", redacted.nested.authorization, "authorization is redacted recursively")
assertx.equal("[REDACTED]", redacted.nested.password, "password is redacted recursively")
assertx.truthy(not redacted.nested.request_url:find("synthetic%-secret"), "query secrets are redacted")
assertx.equal("[REDACTED]", redacted.nested.chapter_body, "chapter body is never loggable")

local messages = {}
local logger = Logger.new({ sink = function(level, value) messages[#messages + 1] = { level, value } end })
logger:info({ proxy_authorization = "Basic synthetic-secret", body = "chapter body" })
assertx.equal("info", messages[1][1], "logger exposes info level")
assertx.equal("[REDACTED]", messages[1][2].proxy_authorization, "logger redacts before emitting")
assertx.equal("[REDACTED]", messages[1][2].body, "logger never emits body content")

local settings_data = {}
local settings = Settings.new({
    read = function() return settings_data end,
    write = function(value) settings_data = value return true end,
})
assertx.equal(20, settings:get("timeout"), "settings default timeout")
assertx.equal(4 * 1024 * 1024, settings:get("max_response_bytes"), "settings response limit")
assertx.equal(5, settings:get("redirects"), "settings redirect default")
assertx.equal(2, settings:get("concurrency"), "settings concurrency default")
assertx.equal(3, settings:get("max_concurrency"), "settings max concurrency")
assertx.equal(20, settings:get("pagination"), "settings pagination default")
assertx.equal(3, settings:get("prefetch"), "settings prefetch default")
assertx.equal(20, settings:get("shelf_page"), "settings shelf default")
assertx.equal(true, settings:get("covers_enabled"), "settings covers default")
assertx.equal("info", settings:get("log_level"), "settings logging default")
assertx.truthy(settings_data.schema_version ~= nil, "settings records schema version")
settings:set("prefetch", 99)
assertx.equal(10, settings:get("prefetch"), "settings clamp prefetch range")

local path = temporary_path("atomic")
local fs = Fs.new()
assertx.truthy(fs:atomicWrite(path, "old value"), "writes initial file")
local failing_fs = Fs.new({ rename = function() return nil, "simulated rename failure" end })
local write_ok, write_error = failing_fs:atomicWrite(path, "new value")
assertx.equal(nil, write_ok, "atomic replacement reports rename failure")
assertx.equal(Errors.STORAGE_ERROR, write_error.code, "atomic replacement returns storage error")
assertx.equal("old value", assert(fs:read(path)), "failed replacement preserves old file")
cleanup(path)

local missing_sqlite_path = temporary_path("fallback")
local fallback, fallback_error = Storage.new({
    path = missing_sqlite_path,
    sqlite_loader = function() return nil, "sqlite unavailable" end,
})
assertx.truthy(fallback, "sqlite unavailable selects fallback")
assertx.equal(nil, fallback_error, "sqlite fallback is transparent")
assertx.equal("lua", fallback:backendName(), "fallback backend is selected")

local source = assert(fallback:createSource({ name = "Synthetic source", url = "https://example.test/books" }))
local book = assert(fallback:createBook({ source_id = source.id, name = "Synthetic book", author = "Test Author", url = "https://example.test/book/1" }))
assertx.truthy(book.id ~= nil, "book gets stable identity")
assert(fallback:replaceChapters(book.id, {
    { uid = "chapter-2", index = 2, title = "Second", url = "https://example.test/book/1/2" },
    { uid = "chapter-1", index = 1, title = "First", url = "https://example.test/book/1/1" },
}))
assert(fallback:putProgress(book.id, { chapter_uid = "chapter-1", chapter_index = 1, fraction = 0.25 }))
assert(fallback:putDownloadTask({ id = "download-1", book_id = book.id, status = "queued" }))

local restarted = assert(Storage.new({ path = missing_sqlite_path, sqlite_loader = function() return nil end }))
local chapters = assert(restarted:listChapters(book.id))
assertx.equal("chapter-1", chapters[1].uid, "chapters retain ascending index order across restart")
assertx.equal("chapter-2", chapters[2].uid, "chapters retain all rows across restart")
assertx.equal("chapter-1", assert(restarted:getProgress(book.id)).chapter_uid, "progress survives restart")
assertx.equal("queued", assert(restarted:getDownloadTask("download-1")).status, "download task survives restart")
assertx.equal("Synthetic source", assert(restarted:getSource(source.id)).name, "source CRUD survives restart")
assertx.equal("Synthetic book", assert(restarted:getBook(book.id)).name, "book CRUD survives restart")
cleanup(missing_sqlite_path)

local corrupt_path = temporary_path("corrupt")
local corrupt_file = assert(io.open(corrupt_path, "wb"))
corrupt_file:write("return os.execute('must never run')")
corrupt_file:close()
local corrupt_storage, corrupt_error = Storage.new({ path = corrupt_path, sqlite_loader = function() return nil end })
assertx.equal(nil, corrupt_storage, "corrupt fallback is rejected")
assertx.equal(Errors.STORAGE_ERROR, corrupt_error.code, "corrupt fallback returns structured error")
cleanup(corrupt_path)

local migration_path = temporary_path("migration")
local migration_file = assert(io.open(migration_path, "wb"))
local original_migration_data = "return { [\"schema_version\"] = 999, [\"data\"] = {} }"
migration_file:write(original_migration_data)
migration_file:close()
local migrated_storage, migration_error = Storage.new({ path = migration_path, sqlite_loader = function() return nil end })
assertx.equal(nil, migrated_storage, "unsupported migration is rejected")
assertx.equal(Errors.MIGRATION_ERROR, migration_error.code, "migration error remains stable")
local migration_read = assert(io.open(migration_path, "rb"))
assertx.equal(original_migration_data, migration_read:read("*a"), "failed migration preserves original data")
migration_read:close()
cleanup(migration_path)

local stable_source_key = Identity.source("https://user:synthetic-secret@example.test/catalog")
assertx.equal(stable_source_key, Identity.source("https://user:synthetic-secret@example.test/catalog"), "identity is deterministic")
assertx.truthy(not stable_source_key:find("synthetic%-secret", 1, false), "identity key excludes credentials")

return 57
