local Errors = require("legado.lib.errors")

local SqliteBackend = {}
SqliteBackend.__index = SqliteBackend
SqliteBackend.SCHEMA_VERSION = 1

local TABLE = "legado_v1_"

local function quote(value)
    return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function encode(value)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then return "\"" .. value:gsub("[\\\"\n\r\t]", { ["\\"] = "\\\\", ["\""] = "\\\"", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }) .. "\"" end
    local keys, fields = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    for _, key in ipairs(keys) do fields[#fields + 1] = "[" .. encode(key) .. "]=" .. encode(value[key]) end
    return "{" .. table.concat(fields, ",") .. "}"
end

-- SQLite payloads are emitted by this module only.  The parser deliberately
-- accepts literals, not Lua expressions, so corrupt database content cannot
-- execute through a load/loadstring call.
local function parse_literal(input)
    local index, length = 1, #input
    local function space() while index <= length and input:sub(index, index):match("%s") do index = index + 1 end end
    local parse
    local function string_value()
        index = index + 1
        local output = {}
        while index <= length do
            local character = input:sub(index, index); index = index + 1
            if character == "\"" then return table.concat(output) end
            if character == "\\" then
                local escaped = input:sub(index, index); index = index + 1
                local values = { n = "\n", r = "\r", t = "\t", ["\\"] = "\\", ["\""] = "\"" }
                if not values[escaped] then error("invalid payload escape") end
                output[#output + 1] = values[escaped]
            else output[#output + 1] = character end
        end
        error("unterminated payload string")
    end
    local function table_value()
        index = index + 1; space()
        local result = {}
        while input:sub(index, index) ~= "}" do
            if input:sub(index, index) ~= "[" then error("invalid payload table") end
            index = index + 1; local key = parse(); space()
            if input:sub(index, index) ~= "]" then error("invalid payload key") end
            index = index + 1; space()
            if input:sub(index, index) ~= "=" then error("invalid payload assignment") end
            index = index + 1; result[key] = parse(); space()
            if input:sub(index, index) == "," then index = index + 1; space()
            elseif input:sub(index, index) ~= "}" then error("invalid payload separator") end
        end
        index = index + 1
        return result
    end
    parse = function()
        space()
        local character = input:sub(index, index)
        if character == "\"" then return string_value() end
        if character == "{" then return table_value() end
        local token = input:sub(index):match("^[%a_]+")
        if token == "true" then index = index + 4 return true end
        if token == "false" then index = index + 5 return false end
        if token == "nil" then index = index + 3 return nil end
        local number = input:sub(index):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if number and number ~= "-" then index = index + #number return tonumber(number) end
        error("invalid payload literal")
    end
    local result = parse(); space()
    if index <= length then error("trailing payload data") end
    return result
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[copy(key)] = copy(child) end
    return result
end

function SqliteBackend.open(driver, path)
    if type(driver) ~= "table" or type(driver.open) ~= "function" then return nil, "invalid sqlite driver" end
    local opened, db = pcall(driver.open, path)
    if not opened or not db then return nil, db or "cannot open sqlite database" end
    if type(db.exec) ~= "function" or (type(db.rowexec) ~= "function" and type(db.prepare) ~= "function") then
        return nil, "unsupported sqlite driver"
    end
    local self = setmetatable({ db = db }, SqliteBackend)
    local initialized, error_value = self:_initialize()
    if not initialized then return nil, error_value end
    return self
end

function SqliteBackend:_exec(sql)
    local ok, result, count = pcall(self.db.exec, self.db, sql)
    if not ok or result == false or (result == nil and type(count) == "string") then
        return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite statement failed", { cause = result or count })
    end
    return true
end

function SqliteBackend:_rows(sql)
    local rows = {}
    local executed, resultset, count = pcall(self.db.exec, self.db, sql)
    if executed and resultset == nil and (count == 0 or count == nil) then return rows end
    if executed and type(resultset) == "table" and count and count > 0 then
        for index = 1, count do
            local row = {}
            for name, column in pairs(resultset) do
                if type(name) == "string" and type(column) == "table" then row[name] = column[index] end
            end
            rows[#rows + 1] = row
        end
        return rows
    end
    if not executed or resultset == false or (resultset == nil and type(count) == "string") then
        return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite query failed", { cause = resultset or count })
    end
    if type(self.db.rowexec) == "function" then
        local ok, first = pcall(self.db.rowexec, self.db, sql)
        if not ok then return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite row query failed", { cause = first }) end
        if first == nil then return rows end
        local column = sql:match("SELECT%s+([%w_]+)")
        if column then rows[1] = { [column] = first } end
        return rows
    end
    if type(self.db.prepare) == "function" then
        local ok, statement = pcall(self.db.prepare, self.db, sql)
        if not ok or not statement then return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite prepare failed", { cause = statement }) end
        local iterated, iteration_error = pcall(function()
            local row, names = statement:step({}, {})
            while row do
                local mapped = {}
                for index, name in ipairs(names or {}) do mapped[name] = row[index] end
                rows[#rows + 1] = mapped
                row, names = statement:step({}, {})
            end
        end)
        if statement.close then statement:close() elseif statement.finalize then statement:finalize() end
        if not iterated then return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite row iteration failed", { cause = iteration_error }) end
        return rows
    end
    return nil, Errors.new(Errors.STORAGE_ERROR, "sqlite query support unavailable")
end

function SqliteBackend:_initialize()
    local meta_tables, meta_error = self:_rows("SELECT name FROM sqlite_master WHERE type='table' AND name='" .. TABLE .. "meta'")
    if not meta_tables then return nil, meta_error end
    if meta_tables[1] then
        local versions, version_error = self:_rows("SELECT value FROM " .. TABLE .. "meta WHERE key='schema_version'")
        if not versions then return nil, version_error end
        if versions[1] and tonumber(versions[1].value) ~= SqliteBackend.SCHEMA_VERSION then
            return nil, Errors.new(Errors.MIGRATION_ERROR, "unsupported sqlite migration", { from = versions[1].value, to = SqliteBackend.SCHEMA_VERSION })
        end
    end
    local schema = table.concat({
        "PRAGMA journal_mode=WAL;", "PRAGMA synchronous=NORMAL;",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "sources (id TEXT PRIMARY KEY, payload TEXT NOT NULL);",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "books (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, payload TEXT NOT NULL);",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "chapters (uid TEXT PRIMARY KEY, book_id TEXT NOT NULL, chapter_index INTEGER NOT NULL, payload TEXT NOT NULL);",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "progress (book_id TEXT PRIMARY KEY, payload TEXT NOT NULL);",
        "CREATE TABLE IF NOT EXISTS " .. TABLE .. "downloads (id TEXT PRIMARY KEY, book_id TEXT, payload TEXT NOT NULL);",
    }, " ")
    local ready, ready_error = self:_exec(schema)
    if not ready then return nil, ready_error end
    local rows, rows_error = self:_rows("SELECT value FROM " .. TABLE .. "meta WHERE key='schema_version'")
    if not rows then return nil, rows_error end
    if not rows[1] then return self:_exec("INSERT INTO " .. TABLE .. "meta (key,value) VALUES ('schema_version'," .. SqliteBackend.SCHEMA_VERSION .. ")") end
    return true
end

function SqliteBackend:_put(table_name, key_name, id, payload, columns)
    local names, values = { key_name, "payload" }, { quote(id), quote(encode(payload)) }
    for key, value in pairs(columns or {}) do names[#names + 1] = key; values[#values + 1] = quote(value) end
    return self:_exec("INSERT OR REPLACE INTO " .. TABLE .. table_name .. " (" .. table.concat(names, ",") .. ") VALUES (" .. table.concat(values, ",") .. ")")
end

function SqliteBackend:_get(table_name, where)
    local rows, error_value = self:_rows("SELECT payload FROM " .. TABLE .. table_name .. " WHERE " .. where .. " LIMIT 1")
    if not rows then return nil, error_value end
    if not rows[1] then return nil end
    local parsed, payload = pcall(parse_literal, rows[1].payload)
    if not parsed then return nil, Errors.new(Errors.STORAGE_ERROR, "corrupt sqlite payload", { cause = payload }) end
    return copy(payload)
end

function SqliteBackend:_list(table_name, where, order)
    local sql = "SELECT payload FROM " .. TABLE .. table_name
    if where then sql = sql .. " WHERE " .. where end
    if order then sql = sql .. " ORDER BY " .. order end
    local rows, error_value = self:_rows(sql)
    if not rows then return nil, error_value end
    local values = {}
    for _, row in ipairs(rows) do
        local parsed, payload = pcall(parse_literal, row.payload)
        if not parsed then return nil, Errors.new(Errors.STORAGE_ERROR, "corrupt sqlite payload", { cause = payload }) end
        values[#values + 1] = copy(payload)
    end
    return values
end

function SqliteBackend:putSource(value) return self:_put("sources", "id", value.id, value) end
function SqliteBackend:getSource(id) return self:_get("sources", "id=" .. quote(id)) end
function SqliteBackend:deleteSource(id) return self:_exec("DELETE FROM " .. TABLE .. "sources WHERE id=" .. quote(id)) end
function SqliteBackend:listSources() return self:_list("sources", nil, "id") end
function SqliteBackend:putBook(value) return self:_put("books", "id", value.id, value, { source_id = value.source_id or "" }) end
function SqliteBackend:getBook(id) return self:_get("books", "id=" .. quote(id)) end
function SqliteBackend:deleteBook(id) return self:_exec("DELETE FROM " .. TABLE .. "books WHERE id=" .. quote(id)) end
function SqliteBackend:listBooks() return self:_list("books", nil, "id") end
function SqliteBackend:getProgress(book_id) return self:_get("progress", "book_id=" .. quote(book_id)) end
function SqliteBackend:putProgress(value) return self:_put("progress", "book_id", value.book_id, value) end
function SqliteBackend:getDownload(id) return self:_get("downloads", "id=" .. quote(id)) end
function SqliteBackend:putDownload(value) return self:_put("downloads", "id", value.id, value, { book_id = value.book_id or "" }) end
function SqliteBackend:listDownloads() return self:_list("downloads", nil, "id") end

function SqliteBackend:replaceChapters(book_id, chapters)
    local started, start_error = self:_exec("BEGIN IMMEDIATE")
    if not started then return nil, start_error end
    local deleted, delete_error = self:_exec("DELETE FROM " .. TABLE .. "chapters WHERE book_id=" .. quote(book_id))
    if not deleted then self:_exec("ROLLBACK"); return nil, delete_error end
    for _, chapter in ipairs(chapters) do
        local saved, save_error = self:_put("chapters", "uid", chapter.uid, chapter, { book_id = book_id, chapter_index = chapter.index })
        if not saved then self:_exec("ROLLBACK"); return nil, save_error end
    end
    return self:_exec("COMMIT")
end
function SqliteBackend:listChapters(book_id) return self:_list("chapters", "book_id=" .. quote(book_id), "chapter_index, uid") end
function SqliteBackend:getChapter(book_id, uid) return self:_get("chapters", "book_id=" .. quote(book_id) .. " AND uid=" .. quote(uid)) end

return SqliteBackend
