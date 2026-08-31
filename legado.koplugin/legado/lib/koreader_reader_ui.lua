-- Small compatibility adapter around KOReader's documented ReaderUI entry point.
-- The session owns only documents it opens through this adapter; it never observes
-- arbitrary ReaderUI instances.
local Adapter = {}
Adapter.__index = Adapter

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

function Adapter.new()
    return setmetatable({ ReaderUI = optional("apps/reader/readerui") }, Adapter)
end

function Adapter:openDocument(path, callbacks)
    local reader_ui = self.ReaderUI
    if not reader_ui or type(reader_ui.showReader) ~= "function" then return nil end
    local proxy = { is_legado_document = true }
    reader_ui:showReader(path, nil, true, nil, function()
        local reader = reader_ui.instance
        proxy.reader = reader
        proxy.getProgressFraction = function()
            local document = reader and reader.document
            if document and type(document.getCurrentPage) == "function" and type(document.getPageCount) == "function" then
                local pages = tonumber(document:getPageCount()) or 0
                if pages > 1 then return math.max(0, math.min(1, ((tonumber(document:getCurrentPage()) or 1) - 1) / (pages - 1))) end
            end
            return 0
        end
        proxy.setProgressFraction = function(_, fraction)
            local document, paging = reader and reader.document, reader and reader.paging
            if document and paging and type(document.getPageCount) == "function" and type(paging.onGotoPage) == "function" then
                local pages = tonumber(document:getPageCount()) or 1
                local page = math.max(1, math.min(pages, math.floor((tonumber(fraction) or 0) * math.max(0, pages - 1) + 1.5)))
                paging:onGotoPage(page)
            end
        end
        -- ReaderUI calls this callback after its document has been opened.
        if callbacks and callbacks.ready then callbacks.ready(proxy) end
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
    end)
    return proxy
end

function Adapter:endOfBook(document)
    if document and type(document.forwardEnd) == "function" then return document.forwardEnd() end
    return false
end

return Adapter
