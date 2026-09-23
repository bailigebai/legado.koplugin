local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Identity = require("legado.lib.identity")
local SqliteBackend = require("legado.lib.sqlite_backend")

local Storage = {}
Storage.__index = Storage
Storage.SCHEMA_VERSION = 1

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    seen[value] = nil
    return result
end

local function sorted_keys(value)
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    return keys
end

local function escape(value)
    return value:gsub("[\\\"\n\r\t]", { ["\\"] = "\\\\", ["\""] = "\\\"", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" })
end

local function encode(value)
    local value_type = type(value)
    if value_type == "nil" then return "nil" end
    if value_type == "boolean" or value_type == "number" then return tostring(value) end
    if value_type == "string" then return "\"" .. escape(value) .. "\"" end
    if value_type ~= "table" then error("unsupported fallback value") end
    local fields = {}
    for _, key in ipairs(sorted_keys(value)) do
        fields[#fields + 1] = "[" .. encode(key) .. "]=" .. encode(value[key])
    end
    return "{" .. table.concat(fields, ",") .. "}"
end

local function parser(input)
    local position = 1
    local length = #input
    local function whitespace()
        while position <= length and input:sub(position, position):match("%s") do position = position + 1 end
    end
    local parse_value
    local function parse_string()
        position = position + 1
        local output = {}
        while position <= length do
            local character = input:sub(position, position)
            position = position + 1
            if character == "\"" then return table.concat(output) end
            if character == "\\" then
                local escaped = input:sub(position, position)
                position = position + 1
                local replacements = { n = "\n", r = "\r", t = "\t", ["\\"] = "\\", ["\""] = "\"" }
                if replacements[escaped] then output[#output + 1] = replacements[escaped]
                elseif escaped:match("%d") then
                    local digits = escaped .. input:sub(position, position + 1)
                    if not digits:match("^%d%d%d$") then error("invalid string escape") end
                    position = position + 2
                    output[#output + 1] = string.char(tonumber(digits))
                else error("invalid string escape") end
            else
                output[#output + 1] = character
            end
        end
        error("unterminated string")
    end
    local function parse_table()
        position = position + 1
        local result = {}
        whitespace()
        while input:sub(position, position) ~= "}" do
            if input:sub(position, position) ~= "[" then error("expected table key") end
            position = position + 1
            whitespace()
            local key = parse_value()
            whitespace()
            if input:sub(position, position) ~= "]" then error("expected table key end") end
            position = position + 1
            whitespace()
            if input:sub(position, position) ~= "=" then error("expected table assignment") end
            position = position + 1
            whitespace()
            result[key] = parse_value()
            whitespace()
            if input:sub(position, position) == "," then position = position + 1; whitespace()
            elseif input:sub(position, position) ~= "}" then error("expected table separator") end
        end
        position = position + 1
        return result
    end
    parse_value = function()
        whitespace()
        local character = input:sub(position, position)
        if character == "\"" then return parse_string() end
        if character == "{" then return parse_table() end
        local word = input:sub(position):match("^[%a_]+")
        if word == "true" then position = position + 4 return true end
        if word == "false" then position = position + 5 return false end
        if word == "nil" then position = position + 3 return nil end
        local number = input:sub(position):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if number and number ~= "-" then position = position + #number return tonumber(number) end
        error("invalid data literal")
    end
    whitespace()
    if input:sub(position, position + 5) ~= "return" or input:sub(position + 6, position + 6):match("[%w_]") then error("expected data return") end
    position = position + 6
    local result = parse_value()
    whitespace()
    if position <= length then error("trailing data") end
    return result
end

local function new_data()
    return { schema_version = Storage.SCHEMA_VERSION, data = {
        sources = {}, books = {}, chapters = {}, progress = {}, downloads = {},
    } }
end

local COLLECTIONS = { "sources", "books", "chapters", "progress", "downloads" }

local function validate_state_collections(state, path)
    for _, name in ipairs(COLLECTIONS) do
        if type(state.data[name]) ~= "table" then
            return nil, Errors.new(Errors.STORAGE_ERROR, "invalid fallback storage collection", {
                path = path, collection = name,
            })
        end
    end
    return true
end

local function list_values(map, field)
    local values = {}
    for _, value in pairs(map) do values[#values + 1] = copy(value) end
    table.sort(values, function(left, right)
        if field then
            local left_value, right_value = left[field], right[field]
            if left_value ~= right_value then return (left_value or 0) < (right_value or 0) end
        end
        return tostring(left.id or left.uid or "") < tostring(right.id or right.uid or "")
    end)
    return values
end

local function update_fields(target, patch)
    for key, value in pairs(patch) do target[key] = copy(value) end
    return target
end

function Storage.new(options)
    options = options or {}
    if options.backend then return setmetatable({ backend = "injected", adapter = options.backend, license = options.license }, Storage) end
    local loader = options.sqlite_loader
    if not loader then loader = function() return require("lua-ljsqlite3/init") end end
    local loaded, sqlite, sqlite_error = pcall(loader)
    if not loaded then sqlite_error, sqlite = sqlite, nil end
    if sqlite and type(sqlite.open) == "function" then
        local backend, backend_error = SqliteBackend.open(sqlite, options.path or "legado.sqlite")
        if backend then return setmetatable({ backend = "sqlite", adapter = backend, license = options.license }, Storage) end
        if Errors.is(backend_error, Errors.MIGRATION_ERROR) then return nil, backend_error end
    end

    local fs = options.fs or Fs.new()
    local path = options.path or "legado-storage.lua"
    local content = fs:read(path)
    local state
    if content then
        local parsed, parse_error = pcall(parser, content)
        if not parsed then return nil, Errors.new(Errors.STORAGE_ERROR, "corrupt fallback storage", { path = path, cause = parse_error }) end
        state = parse_error
        if type(state) ~= "table" or type(state.data) ~= "table" then
            return nil, Errors.new(Errors.STORAGE_ERROR, "invalid fallback storage", { path = path })
        end
        if state.schema_version ~= Storage.SCHEMA_VERSION then
            return nil, Errors.new(Errors.MIGRATION_ERROR, "unsupported storage migration", { path = path, from = state.schema_version, to = Storage.SCHEMA_VERSION })
        end
    else
        state = new_data()
    end
    local valid, validation_error = validate_state_collections(state, path)
    if not valid then return nil, validation_error end
    local self = setmetatable({ fs = fs, path = path, state = state, backend = "lua", sqlite_error = sqlite_error, license = options.license }, Storage)
    local saved, save_error = self:_save()
    if not saved then return nil, save_error end
    return self
end

function Storage:_save()
    return self:_save_state(self.state)
end

function Storage:_save_state(state)
    local encoded_ok, content = pcall(function() return "return " .. encode(state) end)
    if not encoded_ok then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot encode fallback storage", { cause = content }) end
    return self.fs:atomicWrite(self.path, content)
end

function Storage:_mutate(mutator)
    local candidate = copy(self.state)
    mutator(candidate)
    local saved, error_value = self:_save_state(candidate)
    if not saved then return nil, error_value end
    self.state = candidate
    return true
end

function Storage:backendName()
    return type(self.backend) == "string" and self.backend or "injected"
end

function Storage:_map(name)
    return self.state.data[name]
end

function Storage:_persist_value(name, id, value)
    local saved, error_value = self:_mutate(function(candidate)
        candidate.data[name][id] = copy(value)
    end)
    if not saved then return nil, error_value end
    return copy(value)
end

function Storage:createSource(source)
    source = copy(source or {})
    source.id = source.id or Identity.source(source.url or source.bookSourceUrl or source.name)
    if self.adapter then
        local saved, error_value = self.adapter:putSource(source)
        if not saved then return nil, error_value end
        return copy(source)
    end
    return self:_persist_value("sources", source.id, source)
end
function Storage:getSource(id)
    if self.adapter then return self.adapter:getSource(id) end
    local value = self:_map("sources")[id]; return value and copy(value) or nil
end
function Storage:updateSource(id, patch)
    local value = self:getSource(id)
    if not value then return nil, Errors.new(Errors.STORAGE_ERROR, "source not found", { id = id }) end
    if self.adapter then
        local updated = update_fields(value, patch or {})
        local saved, error_value = self.adapter:putSource(updated)
        return saved and updated or nil, error_value
    end
    return self:_persist_value("sources", id, update_fields(copy(value), patch or {}))
end
function Storage:deleteSource(id)
    if self.adapter then return self.adapter:deleteSource(id) end
    return self:_mutate(function(candidate) candidate.data.sources[id] = nil end)
end
function Storage:listSources() if self.adapter then return self.adapter:listSources() end return list_values(self:_map("sources"), "name") end
function Storage:replaceSources(sources)
    local replacement = {}
    for _, source in ipairs(sources or {}) do
        local value = copy(source or {})
        local id = value.id or value.bookSourceUrl
        if not id then return nil, Errors.new(Errors.INVALID_INPUT, "source requires id") end
        value.id = id
        replacement[id] = value
    end
    if self.adapter then
        if type(self.adapter.replaceSources) ~= "function" then
            return nil, Errors.new(Errors.STORAGE_ERROR, "source batch replacement unsupported")
        end
        return self.adapter:replaceSources(list_values(replacement, "name"))
    end
    return self:_mutate(function(candidate) candidate.data.sources = replacement end)
end

function Storage:createBook(book)
    book = copy(book or {})
    book.id = book.id or Identity.book(book.source_id, book.url or book.name)
    local existing, read_error = self:getBook(book.id)
    if read_error then return nil, read_error end
    if not existing then
        local books, count_error = self:listShelf()
        if count_error then return nil, count_error end
        if type(books) ~= "table" then return nil, Errors.new(Errors.STORAGE_ERROR, "cannot read bookshelf") end
        if #books >= 5 and not (self.license and self.license:isAuthorized() == true) then
            return nil, Errors.new("LICENSE_REQUIRED", "免费书架最多添加 5 本，继续添加需要输入密钥。")
        end
    end
    if self.adapter then
        local saved, error_value = self.adapter:putBook(book)
        if not saved then return nil, error_value end
        return copy(book)
    end
    return self:_persist_value("books", book.id, book)
end
function Storage:getBook(id) if self.adapter then return self.adapter:getBook(id) end local value = self:_map("books")[id]; return value and copy(value) or nil end
function Storage:updateBook(id, patch)
    local value = self:getBook(id)
    if not value then return nil, Errors.new(Errors.STORAGE_ERROR, "book not found", { id = id }) end
    if self.adapter then
        local updated = update_fields(value, patch or {})
        local saved, error_value = self.adapter:putBook(updated)
        return saved and updated or nil, error_value
    end
    return self:_persist_value("books", id, update_fields(copy(value), patch or {}))
end
function Storage:deleteBook(id)
    if self.adapter then return self.adapter:deleteBook(id) end
    return self:_mutate(function(candidate)
        candidate.data.books[id] = nil
        candidate.data.chapters[id] = nil
        candidate.data.progress[id] = nil
    end)
end
function Storage:updateBooks(books)
    if self.adapter then return self.adapter:updateBooks(books) end
    return self:_mutate(function(candidate)
        for _,book in ipairs(books) do candidate.data.books[book.id]=copy(book) end
    end)
end
function Storage:listShelf() if self.adapter then return self.adapter:listBooks() end return list_values(self:_map("books"), "name") end

function Storage:replaceChapters(book_id, chapters)
    local replacement = {}
    for index, chapter in ipairs(chapters or {}) do
        local value = copy(chapter)
        value.index = value.index or index
        value.uid = value.uid or Identity.chapter(book_id, value.url or value.title, value.index)
        replacement[value.uid] = value
    end
    if self.adapter then
        local values = list_values(replacement, "index")
        return self.adapter:replaceChapters(book_id, values)
    end
    return self:_mutate(function(candidate)
        candidate.data.chapters[book_id] = replacement
    end)
end
function Storage:listChapters(book_id) if self.adapter then return self.adapter:listChapters(book_id) end return list_values(self:_map("chapters")[book_id] or {}, "index") end
function Storage:getChapter(book_id, uid)
    if self.adapter then return self.adapter:getChapter(book_id, uid) end
    local value = (self:_map("chapters")[book_id] or {})[uid]
    return value and copy(value) or nil
end

function Storage:putProgress(book_id, progress)
    if type(book_id) == "table" then progress, book_id = book_id, book_id.book_id end
    if not book_id then return nil, Errors.new(Errors.INVALID_INPUT, "progress requires book id") end
    local value = copy(progress or {})
    value.book_id = book_id
    if self.adapter then
        local saved, error_value = self.adapter:putProgress(value)
        return saved and value or nil, error_value
    end
    return self:_persist_value("progress", book_id, value)
end
function Storage:getProgress(book_id) if self.adapter then return self.adapter:getProgress(book_id) end local value = self:_map("progress")[book_id]; return value and copy(value) or nil end
function Storage:listProgress()
    if not self.adapter then return list_values(self:_map("progress"), "book_id") end
    if type(self.adapter.listProgress) == "function" then return self.adapter:listProgress() end
    local books, error_value = self:listShelf()
    if not books then return nil, error_value end
    local values = {}
    for _, book in ipairs(books) do
        local progress, progress_error = self:getProgress(book.id)
        if progress_error then return nil, progress_error end
        if progress then values[#values + 1] = progress end
    end
    table.sort(values, function(left, right) return tostring(left.book_id or "") < tostring(right.book_id or "") end)
    return values
end

function Storage:putDownloadTask(task)
    task = copy(task or {})
    if not task.id then return nil, Errors.new(Errors.INVALID_INPUT, "download task requires id") end
    if self.adapter then
        local saved, error_value = self.adapter:putDownload(task)
        return saved and task or nil, error_value
    end
    return self:_persist_value("downloads", task.id, task)
end
function Storage:getDownloadTask(id) if self.adapter then return self.adapter:getDownload(id) end local value = self:_map("downloads")[id]; return value and copy(value) or nil end
function Storage:listDownloadTasks() if self.adapter then return self.adapter:listDownloads() end return list_values(self:_map("downloads"), "id") end

return Storage
