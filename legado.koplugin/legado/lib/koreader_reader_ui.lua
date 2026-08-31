-- Small compatibility adapter around KOReader's documented ReaderUI entry point.
-- The session owns only documents it opens through this adapter; it never observes
-- arbitrary ReaderUI instances.
local Errors = require("legado.lib.errors")

local Adapter = {}
Adapter.__index = Adapter

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

function Adapter.new(options)
    options = options or {}
    return setmetatable({ ReaderUI = options.ReaderUI or optional("apps/reader/readerui") }, Adapter)
end

local function failure(message, cause)
    return Errors.new(Errors.STORAGE_ERROR, message, { cause = tostring(cause or "unknown") })
end

function Adapter:openDocument(path, callbacks)
    local reader_ui = self.ReaderUI
    if not reader_ui or type(reader_ui.showReader) ~= "function" then
        return nil, failure("KOReader reader UI is unavailable")
    end
    local proxy = { is_legado_document = true }
    local ready_error
    local function after_open()
        local reader = reader_ui.instance
        if not reader then
            ready_error = failure("KOReader did not expose the opened reader")
            if callbacks and callbacks.failure then pcall(callbacks.failure, ready_error) end
            return
        end
        proxy.reader = reader
        proxy.getProgressFraction = function()
            if reader.rolling and type(reader.rolling.getLastPercent) == "function" then
                return math.max(0, math.min(1, tonumber(reader.rolling:getLastPercent()) or 0))
            end
            local paging, document = reader.paging, reader.document
            local pages = paging and tonumber(paging.number_of_pages)
            local page = paging and tonumber(paging.current_page)
            if not pages and document and type(document.getPageCount) == "function" then pages = tonumber(document:getPageCount()) end
            if not page and type(reader.getCurrentPage) == "function" then page = tonumber(reader:getCurrentPage()) end
            if not page and document and type(document.getCurrentPage) == "function" then page = tonumber(document:getCurrentPage()) end
            if pages and pages > 1 then
                return math.max(0, math.min(1, ((page or 1) - 1) / (pages - 1)))
            end
            return 0
        end
        proxy.setProgressFraction = function(_, fraction)
            fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
            local ok, result
            if reader.rolling and type(reader.rolling.onGotoPercent) == "function" then
                ok, result = pcall(reader.rolling.onGotoPercent, reader.rolling, fraction * 100)
            elseif reader.paging and type(reader.paging.onGotoPercentage) == "function" then
                ok, result = pcall(reader.paging.onGotoPercentage, reader.paging, fraction)
            else
                return nil, failure("KOReader progress restore API is unavailable")
            end
            if not ok then return nil, failure("KOReader progress restore failed", result) end
            return result == nil and true or result
        end
        if reader then
            local old_flush, old_close, old_handle = reader.onFlushSettings, reader.onClose, reader.handleEvent
            reader.onFlushSettings = function(instance, ...)
                if callbacks and callbacks.flush then callbacks.flush(proxy) end
                return old_flush and old_flush(instance, ...) or nil
            end
            reader.onClose = function(instance, ...)
                if callbacks and callbacks.close then callbacks.close(proxy) end
                return old_close and old_close(instance, ...) or nil
            end
            -- ReaderPaging emits EndOfBook through ReaderUI:handleEvent.  We
            -- intercept only our local generated document, and retain the
            -- original dispatch for the final chapter.
            proxy.forwardEnd = function()
                local Event = optional("ui/event")
                if old_handle and Event and type(Event.new) == "function" then return old_handle(reader, Event:new("EndOfBook")) end
            end
            reader.handleEvent = function(instance, event, ...)
                if event and event.name == "EndOfBook" and callbacks and callbacks.end_of_book then
                    callbacks.end_of_book(proxy)
                    return true
                end
                return old_handle and old_handle(instance, event, ...) or nil
            end
        end
        -- ReaderUI invokes after_open at the end of ReaderReady.  Only now is
        -- the proxy safe to commit as the active plugin document.
        if callbacks and callbacks.ready then
            local ok, err = pcall(callbacks.ready, proxy)
            if not ok then
                ready_error = failure("KOReader reader-ready callback failed", err)
                if callbacks.failure then pcall(callbacks.failure, ready_error) end
            end
        end
    end
    local ok, show_error = pcall(reader_ui.showReader, reader_ui, path, nil, true, nil, after_open)
    if not ok then return nil, failure("KOReader could not show generated chapter", show_error) end
    if ready_error then return nil, ready_error end
    return proxy
end

function Adapter:endOfBook(document)
    if document and type(document.forwardEnd) == "function" then return document.forwardEnd() end
    return false
end

return Adapter
