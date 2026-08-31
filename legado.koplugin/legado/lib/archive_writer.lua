local Errors = require("legado.lib.errors")

local ArchiveWriter = {}
ArchiveWriter.__index = ArchiveWriter

local function storage_error(message, cause)
    return Errors.new(Errors.STORAGE_ERROR, message, cause and { cause = tostring(cause) } or nil)
end

local function load_archiver()
    local ok, module = pcall(require, "ffi/archiver")
    return ok and module or nil
end

function ArchiveWriter.new(options)
    options = options or {}
    return setmetatable({ archiver = options.archiver or load_archiver() }, ArchiveWriter)
end

local function close_writer(writer)
    if not writer or type(writer.close) ~= "function" then return true end
    local ok, result = pcall(writer.close, writer)
    if not ok then return nil, result end
    if result == false then return nil, writer.err or "archive commit failed" end
    return true
end

function ArchiveWriter:_verify(path, entries)
    local Reader = self.archiver and self.archiver.Reader
    if type(Reader) ~= "table" or type(Reader.new) ~= "function" then
        return nil, storage_error("archive verification is unavailable")
    end
    local reader = Reader:new()
    local opened_ok, opened = pcall(reader.open, reader, path)
    if not opened_ok or not opened then
        if type(reader.close) == "function" then pcall(reader.close, reader) end
        return nil, storage_error("archive verification open failed", opened_ok and reader.err or opened)
    end
    local seen, index, verify_error = {}, 0, nil
    local iterate_ok, iterator, state, control = pcall(reader.iterate, reader)
    if not iterate_ok or type(iterator) ~= "function" then
        verify_error = storage_error("archive verification iteration failed", iterator)
    else
        while not verify_error do
            local next_ok, entry = pcall(iterator, state, control)
            if not next_ok then verify_error = storage_error("archive verification read failed", entry); break end
            control = entry
            if not entry then break end
            index = index + 1
            local expected = entries[index]
            if not expected or entry.path ~= expected.path or entry.mode ~= "file"
                or tonumber(entry.size) ~= #expected.data or seen[entry.path] then
                verify_error = storage_error("archive verification mismatch")
                break
            end
            seen[entry.path] = true
        end
        if not verify_error and index ~= #entries then verify_error = storage_error("archive verification entry count mismatch") end
    end
    if type(reader.close) == "function" then pcall(reader.close, reader) end
    if verify_error then return nil, verify_error end
    return true
end

function ArchiveWriter:write(path, entries)
    if type(path) ~= "string" or path == "" or type(entries) ~= "table" or #entries == 0 then
        return nil, Errors.new(Errors.INVALID_INPUT, "archive path and entries are required")
    end
    local Writer = self.archiver and self.archiver.Writer
    if type(Writer) ~= "table" or type(Writer.new) ~= "function" then
        return nil, storage_error("KOReader ffi/archiver writer is unavailable")
    end
    local writer = Writer:new()
    local open_ok, opened = pcall(writer.open, writer, path, "epub")
    if not open_ok or not opened then
        return nil, storage_error("cannot open EPUB archive", open_ok and writer.err or opened)
    end
    local failure
    for index, entry in ipairs(entries) do
        if type(entry) ~= "table" or type(entry.path) ~= "string" or type(entry.data) ~= "string" then
            failure = storage_error("invalid EPUB archive entry")
            break
        end
        if type(writer.setZipCompression) == "function" then
            local method = index == 1 and "store" or "deflate"
            local method_ok, compressed = pcall(writer.setZipCompression, writer, method)
            if not method_ok or not compressed then
                failure = storage_error("cannot configure EPUB compression", method_ok and writer.err or compressed)
                break
            end
        end
        local write_ok, written = pcall(writer.addFileFromMemory, writer, entry.path, entry.data, entry.mtime or 315532800)
        if not write_ok or not written then
            failure = storage_error("cannot write EPUB archive entry", write_ok and writer.err or written)
            break
        end
    end
    local closed, close_error = close_writer(writer)
    if failure then return nil, failure end
    if not closed then return nil, storage_error("cannot commit EPUB archive", close_error) end
    return self:_verify(path, entries)
end

return ArchiveWriter
