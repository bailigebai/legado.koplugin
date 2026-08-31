local Errors = require("legado.lib.errors")
local Cleaner = require("legado.lib.content_cleaner")
local Models = require("legado.lib.models")

local ReaderSession = {}
ReaderSession.__index = ReaderSession

local function clamp(value, low, high)
    value = tonumber(value) or low
    return math.max(low, math.min(high, value))
end
local function normalized_title(value)
    return tostring(value or ""):lower():gsub("[%s%p]", "")
end
local function source_id(source, book)
    return (book and book.source_id) or (source and source.id) or Models.sourceId(source)
end
local function html_document(title, body)
    local escaped = tostring(title or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return "<!doctype html><html><head><meta charset=\"utf-8\"><title>" .. escaped .. "</title></head><body>" .. body .. "</body></html>"
end

function ReaderSession.new(options)
    options = options or {}
    assert(options.cache, "ReaderSession requires cache")
    assert(options.storage, "ReaderSession requires storage")
    assert(options.ui, "ReaderSession requires a KOReader UI adapter")
    return setmetatable({ cache = options.cache, storage = options.storage, ui = options.ui, service = options.service,
        settings = options.settings, diagnostics = options.diagnostics or function() end, active = nil, prefetch_handles = {} }, ReaderSession)
end

function ReaderSession:prefetchCount()
    local value = self.settings and type(self.settings.get) == "function" and self.settings:get("prefetch") or 3
    return math.floor(clamp(value, 0, 10))
end

function ReaderSession:_save(state, document)
    if not state or not state.active then return false end
    local fraction = 0
    if document and type(document.getProgressFraction) == "function" then fraction = clamp(document:getProgressFraction(), 0, 1) end
    local chapter = state.chapters[state.index]
    if not chapter then return false end
    self.storage:putProgress({ book_id = state.book.id, source_id = source_id(state.source, state.book), chapter_uid = chapter.uid,
        chapter_index = chapter.index or state.index, chapter_url = chapter.url, chapter_title = chapter.title,
        fraction = fraction, updated_at = os.time() })
    return true
end

function ReaderSession:_callbacks(state)
    return {
        ready = function(document)
            if self.active ~= state or not state.active or document ~= state.document then return end
            if state.restore_fraction ~= nil and type(document.setProgressFraction) == "function" then document:setProgressFraction(state.restore_fraction) end
            state.restore_fraction = nil
        end,
        flush = function(document)
            if self.active == state and state.active and document == state.document then self:_save(state, document) end
        end,
        close = function(document)
            if self.active == state and state.active and document == state.document then self:_save(state, document); state.active = false end
        end,
        end_of_book = function(document)
            if self.active == state and state.active and document == state.document then self:_end(state, document) end
        end,
    }
end

function ReaderSession:_open_cached(state, index, restore_fraction)
    local chapter = state.chapters[index]
    local body, error_value = self.cache:readBody(source_id(state.source, state.book), state.book.id, chapter)
    if not body then return nil, error_value end
    local page = html_document(chapter.title, body)
    local path, write_error = self.cache:writeHtml(source_id(state.source, state.book), state.book.id, chapter, page)
    if not path then return nil, write_error end
    state.index, state.restore_fraction, state.end_handled = index, restore_fraction, false
    local document = self.ui:openDocument(path, self:_callbacks(state))
    if not document then return nil, Errors.new(Errors.STORAGE_ERROR, "KOReader could not open cached chapter") end
    state.document = document
    self.active = state
    self:_prefetch(state)
    return document
end

function ReaderSession:_fetch_then_open(state, index, restore_fraction)
    if not self.service or type(self.service.getContent) ~= "function" then return nil, Errors.new(Errors.STORAGE_ERROR, "chapter is not cached for offline reading") end
    local chapter = state.chapters[index]
    state.fetching = true
    state.fetch_handle = self.service:getContent(state.source, state.book, chapter, function(content, request_error)
        if self.active ~= state or not state.active then return end
        state.fetching = false
        if request_error or not content then self.diagnostics("read", request_error or Errors.new(Errors.NETWORK_ERROR, "empty content")); return end
        local body, clean_error = Cleaner.normalize(content.content or content, { replaceRegex = state.source.replaceRegex })
        if not body then self.diagnostics("read", clean_error); return end
        local saved, save_error = self.cache:writeBody(source_id(state.source, state.book), state.book.id, chapter, body)
        if not saved then self.diagnostics("read", save_error); return end
        self:_open_cached(state, index, restore_fraction)
    end)
    return state.fetch_handle
end

function ReaderSession:_end(state, document)
    if state.end_handled then return end
    state.end_handled = true
    self:_save(state, document)
    local next_index = state.index + 1
    if next_index > #state.chapters then
        if type(self.ui.endOfBook) == "function" then self.ui:endOfBook(document) end
        return
    end
    -- A user-initiated page turn outranks speculative requests.  Cancelling
    -- them avoids two requests for the same next chapter on slow sources.
    self:_cancelPrefetch()
    local opened = self:_open_cached(state, next_index, nil)
    if not opened then self:_fetch_then_open(state, next_index, nil) end
end

function ReaderSession:_cancelPrefetch()
    for _, handle in ipairs(self.prefetch_handles) do
        if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
    end
    self.prefetch_handles = {}
end

function ReaderSession:_prefetch(state)
    if not self.service or type(self.service.getContent) ~= "function" then return end
    local maximum, cursor = self:prefetchCount(), state.index + 1
    local function step()
        if self.active ~= state or not state.active or state.fetching or cursor > state.index + maximum or cursor > #state.chapters then return end
        local chapter, source = state.chapters[cursor], source_id(state.source, state.book)
        local body = self.cache:readBody(source, state.book.id, chapter)
        cursor = cursor + 1
        if body then step(); return end
        local handle = self.service:getContent(state.source, state.book, chapter, function(content, err)
            if self.active ~= state or not state.active then return end
            if content and not err then
                local cleaned = Cleaner.normalize(content.content or content, { replaceRegex = state.source.replaceRegex })
                if cleaned then self.cache:writeBody(source, state.book.id, chapter, cleaned) end
            else self.diagnostics("prefetch", err) end
            step()
        end)
        self.prefetch_handles[#self.prefetch_handles + 1] = handle
    end
    step()
end

function ReaderSession:open(source, book, chapters, index, options)
    options = options or {}
    if type(chapters) ~= "table" or #chapters == 0 then return nil, Errors.new(Errors.INVALID_INPUT, "reading requires a non-empty catalog") end
    self:close()
    local state = { source = source, book = book, chapters = chapters, index = math.max(1, math.min(#chapters, tonumber(index) or 1)), active = true }
    local document, error_value = self:_open_cached(state, state.index, options.restore_fraction)
    if document then return document end
    self.active = state
    return self:_fetch_then_open(state, state.index, options.restore_fraction), error_value
end

function ReaderSession:resume(source, book, chapters)
    local progress = self.storage:getProgress(book.id)
    local index = 1
    if progress then index = self:recoverIndex(chapters, progress) end
    return self:open(source, book, chapters, index, { restore_fraction = progress and clamp(progress.fraction, 0, 1) or nil })
end

function ReaderSession:openOffline(source, book, index)
    local catalog, catalog_error = self.cache:readCatalog(source_id(source, book), book.id)
    if not catalog then return nil, catalog_error end
    local chapters = catalog.chapters or catalog
    local wanted = math.max(1, math.min(#chapters, tonumber(index) or 1))
    for candidate = wanted, 1, -1 do
        if self.cache:readBody(source_id(source, book), book.id, chapters[candidate]) then
            self.last_offline_chapter = { index = candidate, chapter_uid = chapters[candidate].uid }
            return self:open(source, book, chapters, candidate)
        end
    end
    return nil, Errors.new(Errors.STORAGE_ERROR, "no readable cached chapter", { last_readable = 0 })
end

function ReaderSession:recoverIndex(chapters, progress)
    for index, chapter in ipairs(chapters or {}) do if chapter.uid == progress.chapter_uid or (progress.chapter_url and chapter.url == progress.chapter_url) then return index end end
    local title, old = normalized_title(progress.chapter_title), tonumber(progress.chapter_index) or 1
    if title ~= "" then
        local best, distance
        for index, chapter in ipairs(chapters or {}) do if normalized_title(chapter.title) == title and (not distance or math.abs(index - old) < distance) then best, distance = index, math.abs(index - old) end end
        if best then return best end
    end
    return math.max(1, math.min(#chapters, old))
end

function ReaderSession:close()
    if self.active then self:_save(self.active, self.active.document); self.active.active = false end
    self:_cancelPrefetch()
    self.active = nil
end

return ReaderSession
