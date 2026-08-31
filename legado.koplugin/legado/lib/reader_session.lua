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
        settings = options.settings, diagnostics = options.diagnostics or function() end, active = nil, pending = nil,
        next_token = 0, foreground_generation = 0, prefetch_generation = 0,
        foreground_handles = {}, foreground_state = nil, prefetch_handles = {} }, ReaderSession)
end

function ReaderSession:prefetchCount()
    local value = self.settings and type(self.settings.get) == "function" and self.settings:get("prefetch") or 3
    return math.floor(clamp(value, 0, 10))
end

function ReaderSession:_save(state, document)
    if not state or not state.active then return false end
    local fraction = 0
    if document and type(document.getProgressFraction) == "function" then
        local ok, value = pcall(document.getProgressFraction, document)
        if ok then fraction = clamp(value, 0, 1) end
    end
    local chapter = state.chapters[state.index]
    if not chapter then return false end
    self.storage:putProgress({ book_id = state.book.id, source_id = source_id(state.source, state.book), chapter_uid = chapter.uid,
        chapter_index = chapter.index or state.index, chapter_url = chapter.url, chapter_title = chapter.title,
        fraction = fraction, updated_at = os.time() })
    return true
end

function ReaderSession:_reader_error(message, cause)
    if type(cause) == "table" and cause.code then return cause end
    return Errors.new(Errors.STORAGE_ERROR, message, { cause = tostring(cause or "unknown") })
end

function ReaderSession:_isCurrent(state)
    if not state or type(state.is_current) ~= "function" then return true end
    local ok, current = pcall(state.is_current)
    return ok and current == true
end

function ReaderSession:_notify(state, value, err)
    if not state or not self:_isCurrent(state) then return false end
    local notification = state.notification
    local callback = notification and notification.callback or state.on_complete
    if state.notified or (notification and notification.notified) or type(callback) ~= "function" then return false end
    state.notified = true
    if notification then notification.notified = true end
    pcall(callback, value, err)
    return true
end

function ReaderSession:_fail_candidate(state, error_value)
    if self.pending == state then self.pending = nil end
    state.cancelled, state.active = true, false
    state.error = self:_reader_error("KOReader could not activate generated chapter", error_value)
    local previous = state.previous
    if previous then previous.active = true; self.active = previous end
    self.diagnostics("reader", state.error)
    self:_notify(state, nil, state.error)
    return nil, state.error
end

function ReaderSession:_activate_candidate(state, document)
    if self.pending ~= state or state.cancelled or not self:_isCurrent(state) then
        return nil, self:_reader_error("stale reader-ready callback")
    end
    if state.restore_fraction ~= nil then
        if not document or type(document.setProgressFraction) ~= "function" then
            return self:_fail_candidate(state, self:_reader_error("KOReader progress restore API is unavailable"))
        end
        local ok, restored, restore_error = pcall(document.setProgressFraction, document, state.restore_fraction)
        if not ok or restored == nil or restored == false then
            return self:_fail_candidate(state, restore_error or restored)
        end
    end
    local previous = state.previous
    if previous and previous ~= state then previous.active = false end
    state.document, state.restore_fraction, state.end_handled, state.active = document, nil, false, true
    self.active, self.pending = state, nil
    if state.offline then
        local chapter = state.chapters[state.index]
        self.last_offline_chapter = { index = state.index, chapter_uid = chapter and chapter.uid }
    end
    if not state.offline then self:_prefetch(state) end
    self:_notify(state, document, nil)
    return document
end

function ReaderSession:_callbacks(state)
    return {
        ready = function(document)
            return self:_activate_candidate(state, document)
        end,
        failure = function(error_value)
            if self.pending == state and not state.cancelled then self:_fail_candidate(state, error_value) end
        end,
        flush = function(document)
            if self.active == state and state.active and document == state.document then self:_save(state, document) end
        end,
        close = function(document)
            if self.active == state and state.active and document == state.document then
                self:_save(state, document)
                state.active = false
                self:_cancelForeground()
                self:_cancelPrefetch()
            end
        end,
        end_of_book = function(document)
            if self.active == state and state.active and document == state.document then self:_end(state, document) end
        end,
    }
end

function ReaderSession:_open_cached(state, index, restore_fraction)
    if not self:_isCurrent(state) then return nil, Errors.new(Errors.CANCELLED, "reading intent is stale") end
    local chapter = state.chapters[index]
    local body, error_value = self.cache:readBody(source_id(state.source, state.book), state.book.id, chapter)
    if not body then return nil, error_value end
    local page = html_document(chapter.title, body)
    local path, write_error = self.cache:writeHtml(source_id(state.source, state.book), state.book.id, chapter, page)
    if not path then return nil, write_error end
    self.next_token = self.next_token + 1
    local candidate = {
        token = self.next_token, source = state.source, book = state.book, chapters = state.chapters,
        index = index, restore_fraction = restore_fraction, previous = self.active, active = false,
        offline = state.offline, on_complete = state.on_complete, notification = state.notification,
        is_current = state.is_current,
    }
    if self.pending then self.pending.cancelled = true end
    self.pending = candidate
    local ok, document, open_error = pcall(self.ui.openDocument, self.ui, path, self:_callbacks(candidate))
    if not ok then return self:_fail_candidate(candidate, document) end
    if not document then return self:_fail_candidate(candidate, open_error or Errors.new(Errors.STORAGE_ERROR, "KOReader could not open cached chapter")) end
    if candidate.error then return nil, candidate.error end
    candidate.opened_document = document
    return document
end

function ReaderSession:_fetch_then_open(state, index, restore_fraction)
    if not self.service or type(self.service.getContent) ~= "function" then
        state.fetching, state.end_handled = false, false
        local error_value = Errors.new(Errors.STORAGE_ERROR, "chapter is not cached and BookService is unavailable")
        self.diagnostics("read", error_value)
        self:_notify(state, nil, error_value)
        return nil, error_value
    end
    local chapter = state.chapters[index]
    self:_cancelForeground()
    local generation = self.foreground_generation
    state.fetching = true
    self.foreground_state = state
    local completed = false
    local function callback(content, request_error)
        completed = true
        if not self:_isCurrent(state) then
            state.fetching = false
            if self.foreground_state == state then self.foreground_handles, self.foreground_state = {}, nil end
            return
        end
        if generation ~= self.foreground_generation or self.foreground_state ~= state then return end
        if self.active ~= state and state.active then return end
        state.fetching = false
        self.foreground_handles, self.foreground_state = {}, nil
        if request_error or not content then
            state.end_handled = false
            local err = request_error or Errors.new(Errors.NETWORK_ERROR, "empty content")
            self.diagnostics("read", err); self:_notify(state, nil, err); return
        end
        local body, clean_error = Cleaner.normalize(content.content or content, { replaceRegex = state.source.replaceRegex })
        if not body then state.end_handled = false; self.diagnostics("read", clean_error); self:_notify(state, nil, clean_error); return end
        local saved, save_error = self.cache:writeBody(source_id(state.source, state.book), state.book.id, chapter, body)
        if not saved then state.end_handled = false; self.diagnostics("read", save_error); self:_notify(state, nil, save_error); return end
        local opened, open_error = self:_open_cached(state, index, restore_fraction)
        if not opened then
            local current = self.active == state and state or self.active
            if current then current.end_handled = false end
            self.diagnostics("read", open_error or Errors.new(Errors.STORAGE_ERROR, "KOReader could not open fetched chapter"))
        end
    end
    local ok, handle, request_error = pcall(self.service.getContent, self.service, state.source, state.book, chapter, callback)
    if not ok or not handle then
        state.fetching, state.end_handled = false, false
        local err = not ok and self:_reader_error("foreground request failed", handle) or request_error or Errors.new(Errors.NETWORK_ERROR, "foreground request did not start")
        self.diagnostics("read", err)
        self:_notify(state, nil, err)
        return nil, err
    end
    if not completed and generation == self.foreground_generation then
        self.foreground_handles = { handle }
        state.fetch_handle = handle
    end
    return handle
end

function ReaderSession:_end(state, document)
    if state.end_handled then return end
    state.end_handled = true
    self:_save(state, document)
    local next_index = state.index + 1
    if next_index > #state.chapters then
        if type(self.ui.endOfBook) == "function" then return self.ui:endOfBook(document) end
        return false
    end
    -- A user-initiated page turn outranks speculative requests.  Cancelling
    -- them avoids two requests for the same next chapter on slow sources.
    self:_cancelPrefetch()
    local opened = self:_open_cached(state, next_index, nil)
    if opened then return opened end
    return self:_fetch_then_open(state, next_index, nil)
end

local function cancel_handles(handles)
    for _, handle in ipairs(handles) do
        if handle and type(handle.cancel) == "function" then pcall(handle.cancel, handle) end
    end
end

function ReaderSession:_cancelForeground()
    self.foreground_generation = self.foreground_generation + 1
    local handles = self.foreground_handles
    self.foreground_handles = {}
    self.foreground_state = nil
    cancel_handles(handles)
end

function ReaderSession:_cancelPrefetch()
    self.prefetch_generation = self.prefetch_generation + 1
    local handles = self.prefetch_handles
    self.prefetch_handles = {}
    cancel_handles(handles)
end

function ReaderSession:_prefetch(state)
    if not self.service or type(self.service.getContent) ~= "function" then return end
    self:_cancelPrefetch()
    local generation = self.prefetch_generation
    local maximum, cursor = self:prefetchCount(), state.index + 1
    local function step()
        if generation ~= self.prefetch_generation or self.active ~= state or not state.active or state.fetching or cursor > state.index + maximum or cursor > #state.chapters then return end
        local chapter, source = state.chapters[cursor], source_id(state.source, state.book)
        local body = self.cache:readBody(source, state.book.id, chapter)
        cursor = cursor + 1
        if body then step(); return end
        local completed = false
        local function callback(content, err)
            completed = true
            if generation ~= self.prefetch_generation or self.active ~= state or not state.active then return end
            if content and not err then
                local cleaned, clean_error = Cleaner.normalize(content.content or content, { replaceRegex = state.source.replaceRegex })
                if cleaned then
                    local saved, save_error = self.cache:writeBody(source, state.book.id, chapter, cleaned)
                    if not saved then self.diagnostics("prefetch", save_error) end
                else self.diagnostics("prefetch", clean_error) end
            else self.diagnostics("prefetch", err) end
            step()
        end
        local ok, handle, request_error = pcall(self.service.getContent, self.service, state.source, state.book, chapter, callback)
        if not ok or not handle then
            self.diagnostics("prefetch", not ok and self:_reader_error("prefetch request failed", handle) or request_error)
            step()
        elseif not completed and generation == self.prefetch_generation then
            self.prefetch_handles[#self.prefetch_handles + 1] = handle
        end
    end
    step()
end

function ReaderSession:open(source, book, chapters, index, options)
    options = options or {}
    if type(chapters) ~= "table" or #chapters == 0 then
        local err = Errors.new(Errors.INVALID_INPUT, "reading requires a non-empty catalog")
        if type(options.on_complete) == "function" then pcall(options.on_complete, nil, err) end
        return nil, err
    end
    self:_cancelForeground()
    self:_cancelPrefetch()
    if self.pending then self.pending.cancelled = true; self.pending = nil end
    local notification = { callback = options.on_complete, notified = false }
    local state = { source = source, book = book, chapters = chapters,
        index = math.max(1, math.min(#chapters, tonumber(index) or 1)), active = false,
        on_complete = options.on_complete, notification = notification, is_current = options.is_current }
    if not self:_isCurrent(state) then return nil, Errors.new(Errors.CANCELLED, "reading intent is stale") end
    local document, error_value = self:_open_cached(state, state.index, options.restore_fraction)
    if document then return document end
    if error_value and error_value.message and error_value.message:find("unavailable", 1, true) then
        local handle, fetch_error = self:_fetch_then_open(state, state.index, options.restore_fraction)
        return handle, fetch_error or error_value
    end
    self:_notify(state, nil, error_value)
    return nil, error_value
end

function ReaderSession:resume(source, book, chapters, callback, options)
    options = options or {}
    local progress = self.storage:getProgress(book.id)
    local index = 1
    if progress then index = self:recoverIndex(chapters, progress) end
    return self:open(source, book, chapters, index, {
        restore_fraction = progress and clamp(progress.fraction, 0, 1) or nil,
        on_complete = callback,
        is_current = options.is_current,
    })
end

function ReaderSession:openOffline(source, book, index, callback, options)
    options = options or {}
    if type(options.is_current) == "function" then
        local ok, current = pcall(options.is_current)
        if not ok or current ~= true then return nil, Errors.new(Errors.CANCELLED, "reading intent is stale") end
    end
    local catalog, catalog_error = self.cache:readCatalog(source_id(source, book), book.id)
    if not catalog then
        if type(callback) == "function" then pcall(callback, nil, catalog_error) end
        return nil, catalog_error
    end
    local chapters = catalog.chapters or catalog
    local wanted = math.max(1, math.min(#chapters, tonumber(index) or 1))
    local notification = { callback = callback, notified = false }
    for candidate = wanted, 1, -1 do
        local state = { source = source, book = book, chapters = chapters, index = candidate,
            active = false, offline = true, on_complete = callback, notification = notification,
            is_current = options.is_current }
        local document, open_error = self:_open_cached(state, candidate, nil)
        if document then return document end
        if candidate == 1 then self:_notify(state, nil, open_error); return nil, open_error end
    end
    local err = Errors.new(Errors.STORAGE_ERROR, "no readable cached chapter", { last_readable = 0 })
    if type(callback) == "function" and not notification.notified then pcall(callback, nil, err) end
    return nil, err
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
    self:_cancelForeground()
    self:_cancelPrefetch()
    if self.pending then self.pending.cancelled = true; self.pending = nil end
    if self.active then self:_save(self.active, self.active.document); self.active.active = false end
    self.active = nil
end

return ReaderSession
