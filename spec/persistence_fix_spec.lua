local assertx = require("assertions")

local sha_inputs = {}
package.preload["ffi/sha2"] = function()
    return {
        sha256 = function(value)
            sha_inputs[#sha_inputs + 1] = value
            return "nativehash"
        end,
    }
end

local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Storage = require("legado.lib.storage")
local Identity = require("legado.lib.identity")

local function temporary_path(label)
    local path = assert(os.tmpname())
    os.remove(path)
    os.remove(path .. ".tmp")
    os.remove(path .. ".bak")
    return path .. "-legado-review-" .. label
end

local function cleanup(path)
    os.remove(path)
    os.remove(path .. ".tmp")
    os.remove(path .. ".bak")
end

local function fake_sqlite(state)
    state.tables = state.tables or {}
    state.payloads = state.payloads or { sources = {}, books = {}, chapters = {}, progress = {}, downloads = {} }
    state.chapter_books = state.chapter_books or {}
    state.commands = state.commands or {}

    local function quoted_values(values)
        local result = {}
        for value in values:gmatch("'([^']*)'") do result[#result + 1] = value end
        return result
    end

    local function database()
        local db = {}
        function db:exec(sql)
            if sql:match("^SELECT") then
                if sql:find("sqlite_master", 1, true) then
                    return state.tables.meta and { name = { "legado_v1_meta" } } or nil, state.tables.meta and 1 or 0
                end
                if sql:find("FROM legado_v1_meta", 1, true) then
                    return state.schema_version and { value = { tostring(state.schema_version) } } or nil, state.schema_version and 1 or 0
                end
                local selected_table = sql:match("FROM legado_v1_(%w+)")
                local selected_key = sql:match("WHERE [%w_]+='([^']*)'")
                local payloads = {}
                if selected_table == "chapters" and selected_key then
                    for uid, payload in pairs(state.payloads.chapters) do
                        if state.chapter_books[uid] == selected_key or uid == selected_key then payloads[#payloads + 1] = payload end
                    end
                elseif selected_table and selected_key and state.payloads[selected_table] and state.payloads[selected_table][selected_key] then
                    payloads[1] = state.payloads[selected_table][selected_key]
                end
                return #payloads > 0 and { payload = payloads } or nil, #payloads
            end
            state.commands[#state.commands + 1] = sql
            for statement in sql:gmatch("[^;]+") do
                local table_name = statement:match("CREATE TABLE IF NOT EXISTS legado_v1_(%w+)")
                if table_name then state.tables[table_name] = true end
                if statement:find("INSERT INTO legado_v1_meta", 1, true) then
                    state.tables.meta = true
                    state.schema_version = tonumber(statement:match("VALUES %('schema_version',(%d+)%)"))
                end
                local replacement = statement:match("INSERT OR REPLACE INTO legado_v1_(%w+)%s*%b()")
                if replacement then
                    local values = quoted_values(statement)
                    state.payloads[replacement][values[1]] = values[2]
                    if replacement == "chapters" then
                        state.chapter_books[values[1]] = values[3]:match("^book") and values[3] or values[4]
                    end
                end
                local deleted, key = statement:match("DELETE FROM legado_v1_(%w+) WHERE [%w_]+='([^']*)'")
                if deleted then
                    if deleted == "chapters" then
                        for uid in pairs(state.payloads.chapters) do
                            if state.chapter_books[uid] == key then state.payloads.chapters[uid] = nil; state.chapter_books[uid] = nil end
                        end
                    else
                        state.payloads[deleted][key] = nil
                    end
                end
                local deleted_all = statement:match("DELETE FROM legado_v1_(%w+)%s*$")
                if deleted_all then state.payloads[deleted_all] = {} end
            end
            return {}
        end
        function db:rowexec(sql, callback)
            if not callback then
                if sql:find("sqlite_master", 1, true) then return state.tables.meta and "legado_v1_meta" or nil end
                if sql:find("FROM legado_v1_meta", 1, true) then return state.schema_version and tostring(state.schema_version) or nil end
                local table_name = sql:match("FROM legado_v1_(%w+)")
                local key = sql:match("WHERE [%w_]+='([^']*)'")
                if table_name == "chapters" and key then
                    for uid, payload in pairs(state.payloads.chapters) do
                        if state.chapter_books[uid] == key or uid == key then return payload end
                    end
                elseif table_name and key and state.payloads[table_name] then
                    return state.payloads[table_name][key]
                end
                return nil
            end
            if sql:find("sqlite_master", 1, true) then
                if state.tables.meta then callback({ name = "legado_v1_meta" }) end
                return true
            end
            if sql:find("FROM legado_v1_meta", 1, true) then
                if state.schema_version then callback({ value = tostring(state.schema_version) }) end
                return true
            end
            local table_name = sql:match("FROM legado_v1_(%w+)")
            local key = sql:match("WHERE [%w_]+='([^']*)'")
            if table_name and state.payloads[table_name] then
                if key then
                    if table_name == "chapters" then
                        for uid, payload in pairs(state.payloads.chapters) do
                            if state.chapter_books[uid] == key or uid == key then callback({ payload = payload }) end
                        end
                    else
                        local payload = state.payloads[table_name][key]
                        if payload then callback({ payload = payload }) end
                    end
                else
                    for _, payload in pairs(state.payloads[table_name]) do callback({ payload = payload }) end
                end
            end
            return true
        end
        return db
    end

    return { open = function() return database() end }
end

-- This KOReader-shaped driver keeps writes private until COMMIT. A failed
-- commit deliberately leaves its transaction open until the backend rolls it
-- back, which makes accidental uncommitted visibility and a blocked next
-- BEGIN observable in the public storage facade.
local function transactional_sqlite(state)
    state.committed = state.committed or { sources = {}, chapters = {}, chapter_books = {} }
    state.rollbacks = state.rollbacks or 0

    local function clone(map)
        local result = {}
        for key, value in pairs(map) do result[key] = value end
        return result
    end

    local function clone_state(value)
        return { sources = clone(value.sources), chapters = clone(value.chapters), chapter_books = clone(value.chapter_books) }
    end

    local function quoted_values(sql)
        local result = {}
        for value in sql:gmatch("'([^']*)'") do result[#result + 1] = value end
        return result
    end

    local function database()
        local db = {}
        local function visible() return state.transaction or state.committed end
        local function payload_rows(table_name, key)
            local data = visible()
            local values = {}
            if table_name == "chapters" then
                for uid, payload in pairs(data.chapters) do
                    if data.chapter_books[uid] == key then values[#values + 1] = payload end
                end
            elseif data[table_name] and data[table_name][key] then
                values[1] = data[table_name][key]
            end
            return values
        end

        function db:exec(sql)
            if sql:match("^SELECT") then
                if sql:find("sqlite_master", 1, true) or sql:find("legado_v1_meta", 1, true) then return nil, 0 end
                local table_name = sql:match("FROM legado_v1_(%w+)")
                local key = sql:match("WHERE [%w_]+='([^']*)'")
                local values = table_name and key and payload_rows(table_name, key) or {}
                return #values > 0 and { payload = values } or nil, #values
            end
            if sql:match("^BEGIN IMMEDIATE") then
                if state.transaction then return false, "transaction already active" end
                state.transaction = clone_state(state.committed)
                return {}
            end
            if sql:match("^ROLLBACK") then
                state.transaction = nil
                state.rollbacks = state.rollbacks + 1
                return {}
            end
            if sql:match("^COMMIT") then
                if state.fail_next_commit then
                    state.fail_next_commit = false
                    return false, "simulated commit failure"
                end
                state.committed = state.transaction
                state.transaction = nil
                return {}
            end
            if sql:find("CREATE TABLE", 1, true) or sql:find("INSERT INTO legado_v1_meta", 1, true) then return {} end

            local data = assert(state.transaction, "mutation outside transaction")
            local replacement = sql:match("INSERT OR REPLACE INTO legado_v1_(%w+)%s*%b()")
            if replacement then
                local values = quoted_values(sql)
                data[replacement][values[1]] = values[2]
                if replacement == "chapters" then
                    for _, value in ipairs(values) do
                        if value:match("^book%-") then data.chapter_books[values[1]] = value break end
                    end
                end
                return {}
            end
            local deleted, key = sql:match("DELETE FROM legado_v1_(%w+) WHERE [%w_]+='([^']*)'")
            if deleted == "sources" then data.sources[key] = nil return {} end
            if deleted == "chapters" then
                for uid in pairs(data.chapters) do
                    if data.chapter_books[uid] == key then data.chapters[uid] = nil; data.chapter_books[uid] = nil end
                end
                return {}
            end
            local deleted_all = sql:match("DELETE FROM legado_v1_(%w+)%s*$")
            if deleted_all then data[deleted_all] = {} return {} end
            return {}
        end

        function db:rowexec() return nil end
        return db
    end

    return { open = function() return database() end }
end

local sqlite_state = {}
local sqlite_path = temporary_path("sqlite")
local sqlite_storage = assert(Storage.new({ path = sqlite_path, sqlite_loader = function() return fake_sqlite(sqlite_state) end }))
assertx.equal("sqlite", sqlite_storage:backendName(), "KOReader-shaped sqlite driver is selected without nrows")
local sqlite_source = assert(sqlite_storage:createSource({ id = "source-sql", name = "Synthetic SQL source", url = "https://example.test/sql" }))
local sqlite_book = assert(sqlite_storage:createBook({ id = "book-sql", source_id = sqlite_source.id, name = "Synthetic SQL book", url = "https://example.test/sql/book" }))
assert(sqlite_storage:replaceChapters(sqlite_book.id, { { uid = "sql-chapter", index = 1, title = "One", url = "https://example.test/sql/book/1" } }))
assert(sqlite_storage:putProgress(sqlite_book.id, { chapter_uid = "sql-chapter", fraction = 0.5 }))
local sqlite_restarted = assert(Storage.new({ path = sqlite_path, sqlite_loader = function() return fake_sqlite(sqlite_state) end }))
assertx.equal("Synthetic SQL source", assert(sqlite_restarted:getSource("source-sql")).name, "sqlite source survives restart")
assertx.equal("Synthetic SQL book", assert(sqlite_restarted:getBook("book-sql")).name, "sqlite book survives restart")
assertx.equal("sql-chapter", assert(sqlite_restarted:listChapters("book-sql"))[1].uid, "sqlite chapters survive restart")
assertx.equal(0.5, assert(sqlite_restarted:getProgress("book-sql")).fraction, "sqlite progress survives restart")
assert(sqlite_restarted:replaceSources({ { id = "source-sql-replaced", name = "Replacement", url = "https://example.test/replaced" } }))
assertx.equal(nil, sqlite_restarted:getSource("source-sql"), "sqlite source replacement removes omitted rows as one batch")
assertx.equal("Replacement", assert(sqlite_restarted:getSource("source-sql-replaced")).name, "sqlite source replacement stores replacement rows")

local transaction_state = {}
local transactional_storage = assert(Storage.new({ path = temporary_path("transactional"), sqlite_loader = function() return transactional_sqlite(transaction_state) end }))
assert(transactional_storage:replaceSources({ { id = "source-tx-old", name = "Old source" } }))
transaction_state.fail_next_commit = true
local source_commit_ok, source_commit_error = transactional_storage:replaceSources({ { id = "source-tx-new", name = "New source" } })
assertx.equal(nil, source_commit_ok, "source replacement returns the original failed commit result")
assertx.equal(Errors.STORAGE_ERROR, source_commit_error.code, "source commit failure remains a storage error")
assertx.equal("Old source", assert(transactional_storage:getSource("source-tx-old")).name, "failed source commit leaves prior committed set visible")
assertx.equal(1, transaction_state.rollbacks, "failed source commit is rolled back")
assert(transactional_storage:replaceSources({ { id = "source-tx-new", name = "New source" } }))
assertx.equal("New source", assert(transactional_storage:getSource("source-tx-new")).name, "source replacement can begin a later transaction after rollback")

assert(transactional_storage:replaceChapters("book-tx", { { uid = "chapter-tx-old", index = 1, title = "Old" } }))
transaction_state.fail_next_commit = true
local chapter_commit_ok, chapter_commit_error = transactional_storage:replaceChapters("book-tx", { { uid = "chapter-tx-new", index = 1, title = "New" } })
assertx.equal(nil, chapter_commit_ok, "chapter replacement returns the original failed commit result")
assertx.equal(Errors.STORAGE_ERROR, chapter_commit_error.code, "chapter commit failure remains a storage error")
assertx.equal("chapter-tx-old", assert(transactional_storage:listChapters("book-tx"))[1].uid, "failed chapter commit leaves prior committed set visible")
assertx.equal(2, transaction_state.rollbacks, "failed chapter commit is rolled back")
assert(transactional_storage:replaceChapters("book-tx", { { uid = "chapter-tx-new", index = 1, title = "New" } }))
assertx.equal("chapter-tx-new", assert(transactional_storage:listChapters("book-tx"))[1].uid, "chapter replacement can begin a later transaction after rollback")

cleanup(sqlite_path)
local migration_state = { tables = { meta = true }, schema_version = 999 }
local migration_path = temporary_path("sqlite-migration")
local rejected, migration_error = Storage.new({ path = migration_path, sqlite_loader = function() return fake_sqlite(migration_state) end })
assertx.equal(nil, rejected, "sqlite migration mismatch is rejected")
assertx.equal(Errors.MIGRATION_ERROR, migration_error.code, "sqlite migration error is stable")
for _, command in ipairs(migration_state.commands) do
    assertx.truthy(not command:find("PRAGMA", 1, true) and not command:find("CREATE TABLE", 1, true) and not command:find("INSERT", 1, true), "migration check never mutates existing database")
end
cleanup(migration_path)

local directories = {}
local path_fs = Fs.new({ lfs = {
    attributes = function(path) return directories[path] and { mode = "directory" } or nil end,
    mkdir = function(path) directories[path] = true return true end,
} })
assertx.truthy(path_fs:ensureDirectory("/mnt/us/legado/cache"), "creates absolute Kindle directory")
assertx.truthy(directories["/mnt"] and directories["/mnt/us"] and directories["/mnt/us/legado/cache"], "absolute path retains POSIX root")

local atomic_path = temporary_path("restore")
assert(Fs.new():atomicWrite(atomic_path, "old atomic value"))
local rename_calls = 0
local restore_fs = Fs.new({ rename = function(from, to)
    rename_calls = rename_calls + 1
    if rename_calls == 2 then return os.rename(from, to) end
    return nil, "simulated rename failure " .. rename_calls
end })
local atomic_ok, atomic_error = restore_fs:atomicWrite(atomic_path, "new atomic value")
assertx.equal(nil, atomic_ok, "failed replacement reports error when backup restore also fails")
assertx.equal(atomic_path .. ".bak", atomic_error.details.recovery_path, "failed restoration exposes recoverable backup path")
local backup = assert(io.open(atomic_path .. ".bak", "rb"))
assertx.equal("old atomic value", backup:read("*a"), "backup retains old content after failed restoration")
backup:close()
cleanup(atomic_path)

local writes, fail_write = 0, false
local fallback_fs = {
    read = function() return nil end,
    atomicWrite = function(_, _, _)
        writes = writes + 1
        if fail_write then fail_write = false return nil, Errors.new(Errors.STORAGE_ERROR, "simulated write failure") end
        return true
    end,
}
local fallback_storage = assert(Storage.new({ path = "synthetic-fallback.lua", fs = fallback_fs, sqlite_loader = function() return nil end }))
local fallback_source = assert(fallback_storage:createSource({ id = "source-fallback", name = "old name" }))
local fallback_book = assert(fallback_storage:createBook({ id = "book-fallback", source_id = fallback_source.id, name = "book" }))
assert(fallback_storage:replaceChapters(fallback_book.id, { { uid = "old-chapter", index = 1, title = "old" } }))
fail_write = true
assertx.equal(nil, fallback_storage:updateSource(fallback_source.id, { name = "new name" }), "failed source update is rejected")
assertx.equal("old name", assert(fallback_storage:getSource(fallback_source.id)).name, "failed update keeps live state unchanged")
assert(fallback_storage:updateSource(fallback_source.id, { name = "new name" }))
assertx.equal("new name", assert(fallback_storage:getSource(fallback_source.id)).name, "next update succeeds after failed write")
assert(fallback_storage:replaceSources({ { id = "source-batch", name = "batch source" } }))
assertx.equal(nil, fallback_storage:getSource(fallback_source.id), "fallback source replacement removes omitted rows")
assertx.equal("batch source", assert(fallback_storage:getSource("source-batch")).name, "fallback source replacement stores every new row")
fail_write = true
assertx.equal(nil, fallback_storage:replaceSources({ { id = "source-failed-batch", name = "failed batch" } }), "failed source batch replacement is rejected")
assertx.equal("batch source", assert(fallback_storage:getSource("source-batch")).name, "failed source batch replacement preserves live state")
assertx.equal(nil, fallback_storage:getSource("source-failed-batch"), "failed source batch replacement commits no new row")
fail_write = true
assertx.equal(nil, fallback_storage:replaceChapters(fallback_book.id, { { uid = "new-chapter", index = 1, title = "new" } }), "failed chapter replacement is rejected")
assertx.equal("old-chapter", assert(fallback_storage:listChapters(fallback_book.id))[1].uid, "failed chapter replacement keeps old rows")
assert(fallback_storage:replaceChapters(fallback_book.id, { { uid = "new-chapter", index = 1, title = "new" } }))
assertx.equal("new-chapter", assert(fallback_storage:listChapters(fallback_book.id))[1].uid, "chapter replacement succeeds after failed write")

local rejected_adapter = {
    putSource = function() return nil, Errors.new(Errors.STORAGE_ERROR, "adapter source failure") end,
    putBook = function() return nil, Errors.new(Errors.STORAGE_ERROR, "adapter book failure") end,
}
local adapter_storage = Storage.new({ backend = rejected_adapter })
local adapter_source, adapter_source_error = adapter_storage:createSource({ id = "adapter-source" })
assertx.equal(nil, adapter_source, "adapter source failure is returned")
assertx.equal(Errors.STORAGE_ERROR, adapter_source_error.code, "adapter source error is preserved")
local adapter_book, adapter_book_error = adapter_storage:createBook({ id = "adapter-book" })
assertx.equal(nil, adapter_book, "adapter book failure is returned")
assertx.equal(Errors.STORAGE_ERROR, adapter_book_error.code, "adapter book error is preserved")

local identity_key = Identity.source("https://user:synthetic-secret@example.test/catalog")
assertx.equal("source-nativehash", identity_key, "available KOReader hash is preferred")
assertx.truthy(not sha_inputs[1]:find("synthetic%-secret", 1, false), "native hash input excludes credentials")

return 56
