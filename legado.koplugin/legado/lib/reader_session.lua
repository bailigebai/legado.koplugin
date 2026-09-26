local Errors = require("legado.lib.errors")
local Cleaner = require("legado.lib.content_cleaner")
local Models = require("legado.lib.models")
local Identity = require("legado.lib.identity")
local ReadingHistory = require("legado.lib.reading_history")
local has_socket, socket = pcall(require, 'socket')
local clock = has_socket and socket.gettime or os.clock
local has_time, monotonic = pcall(require, 'ui/time')
if has_time and monotonic.now and monotonic.to_s then
    clock = function() return monotonic.to_s(monotonic.now()) end
end

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
local function same_book(left, right)
    return left and right and left.book.id == right.book.id
        and source_id(left.source, left.book) == source_id(right.source, right.book)
end
local function html_document(title, body)
    local escaped = tostring(title or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local text = body:match("^<p>([^<>]*)</p>$")
    if text and text:find("[\r\n]") then
        local paragraphs = {}
        for line in (text .. "\n"):gmatch("(.-)\r?\n") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then paragraphs[#paragraphs + 1] = "<p>" .. line .. "</p>" end
        end
        if #paragraphs > 0 then body = table.concat(paragraphs) end
    end
    return "<!doctype html><html><head><meta charset=\"utf-8\"><title>" .. escaped
        .. "</title><style>html,body{margin:0;padding:0}p{orphans:1;widows:1;page-break-inside:auto}"
        .. "h1,h2,h3,h4,h5,h6{page-break-before:auto}pre{white-space:pre-wrap}</style></head><body>" .. body .. "</body></html>"
end

function ReaderSession.new(options)
    options = options or {}
    assert(options.cache, "ReaderSession requires cache")
    assert(options.storage, "ReaderSession requires storage")
    assert(options.ui, "ReaderSession requires a KOReader UI adapter")
    return setmetatable({ cache = options.cache, storage = options.storage, ui = options.ui, service = options.service,
        settings = options.settings, scheduler = options.scheduler, statistics=options.statistics, timing=options.timing,
        diagnostics = options.diagnostics or function() end, active = nil, pending = nil,
        next_token = 0, foreground_generation = 0, prefetch_generation = 0, catalog_background_generation = 0,
        foreground_handles = {}, foreground_state = nil, prefetch_requests = {}, catalog_background_action = nil }, ReaderSession)
end

function ReaderSession:_timing(stage, started, backend, state, details)
    if not self.timing then return end
    local now = clock()
    local metric = { stage=stage, ms=math.max(0,math.floor((now-started)*1000)), backend=backend or 'pending' }
    if state and state.transition then
        metric.attempt = state.transition.id
        metric.total_ms = math.max(0, math.floor((now-state.transition.started)*1000))
    end
    if details then
        metric.over_budget = details.over_budget == true
        metric.pages = tonumber(details.pages)
    end
    pcall(self.timing, metric)
end
local function preferred_backend(session)
    return session.preferred_backend or (session.settings and session.settings:get('immersive_reader')==true and 'immersive' or 'native')
end

function ReaderSession:_beginTransition(state, started)
    self.transition_id = (self.transition_id or 0) + 1
    state.transition = { id = self.transition_id, started = tonumber(started) or clock() }
end

function ReaderSession:prefetchCount()
    local value = self.settings and type(self.settings.get) == "function" and self.settings:get("prefetch") or 3
    return math.floor(clamp(value, 0, 10))
end

function ReaderSession:_statistics(method,...)
    if not self.statistics then return end
    local state=self.active
    if method~='start' and method~='close' and method~='flush' and state and state.active
        and self.statistics_owner~=state.statistics_book_id then
        if state.paused and method~='resume' then return self:_statistics('flush') end
        local started,err=self:_statistics('start',state.book,self:_statisticsPage(state,state.document),state.statistics_book_id)
        if started~=true then return nil,err end
    end
    local ok,result,err=pcall(self.statistics[method],self.statistics,...)
    if method=='start' then self.statistics_owner=ok and result==true and select(3,...) or nil
    elseif method=='close' or (ok and result==false) then self.statistics_owner=nil end
    if ok and result==false and method=='onPageChanged' and state and state.active and not state.paused then
        return self:_statistics('start',state.book,self:_statisticsPage(state,state.document),state.statistics_book_id)
    end
    if not ok or (not result and err) then
        self.diagnostics('statistics',not ok and {code='STATISTICS_ERROR',message='阅读统计暂不可用'} or err)
    end
    return ok and result,err
end

function ReaderSession:_statisticsPage(state,document)
    if not self.statistics or state.catalog_complete==false then return 1 end
    local ok,value=pcall(function() return document and document.getProgressFraction and document:getProgressFraction() end)
    local fraction=ok and tonumber(value) or 0
    return math.max(1,math.min(10000,math.floor((state.index-1+clamp(fraction,0,1))/math.max(1,#state.chapters)*10000)+1))
end

function ReaderSession:_save(state, document)
    if not state then return false end
    if not state.active then
        -- Native ReaderUI may already have released its document. Retry the
        -- captured snapshot without calling into that closed reader again.
        if not state.pending_progress then return false end
        local saved,err=self.storage:putProgress(state.pending_progress)
        if not saved then self.diagnostics('progress',err);return nil,err end
        state.pending_progress=nil
        return true
    end
    local fraction = 0
    if document and type(document.getProgressFraction) == "function" then
        local ok, value = pcall(document.getProgressFraction, document)
        if ok then fraction = clamp(value, 0, 1) end
    end
    local chapter = state.chapters[state.index]
    if not chapter then return false end
    local previous = state.pending_progress
    if not previous then
        local read_error
        if type(self.storage.getProgress) == "function" then previous, read_error = self.storage:getProgress(state.book.id) end
        if read_error then return nil, read_error end
        previous = previous or {}
    end
    local now = os.time()
    local progress = ReadingHistory.record(previous, state.book, state.started_at, now)
    if state.inherited_layout then
        progress.reader_settings=progress.reader_settings or state.inherited_layout.reader_settings
        progress.immersive_style=progress.immersive_style or state.inherited_layout.immersive_style
    end
    if document and type(document.getReaderSettings) == 'function' then
        local ok, values = pcall(document.getReaderSettings, document)
        if not ok or type(values) ~= 'table' then
            local err = self:_reader_error('KOReader could not collect reading settings', values, 'reader_settings')
            self.diagnostics('reader_settings', err)
            return nil, err
        end
        progress[document.reading_settings_key or 'reader_settings'] = values
    end
    if document and document.backend=='immersive' and document.getPosition then
        local ok, position=pcall(document.getPosition,document)
        if not ok then return nil,self:_reader_error('阅读位置保存失败',position,'progress') end
        progress.immersive_position=position
    end
    progress.book_id, progress.source_id = state.book.id, source_id(state.source, state.book)
    progress.chapter_uid, progress.chapter_index = chapter.uid, chapter.index or state.index
    progress.chapter_url, progress.chapter_title = chapter.url, chapter.title
    progress.fraction, progress.updated_at = fraction, now
    progress.chapter_count, progress.catalog_complete = #state.chapters, state.catalog_complete ~= false
    progress.statistics_book_id=state.statistics_book_id
    state.chapter_seconds=(state.chapter_seconds or 0)+(state.started_at and math.max(0,now-state.started_at) or 0)
    state.reading_seconds=progress.reading_seconds
    local saved, err = self.storage:putProgress(progress)
    if not saved then
        state.pending_progress = progress
        self.diagnostics('progress', err)
        if not state.paused then state.started_at = now end
        return nil, err
    end
    state.pending_progress = nil
    if not state.paused then state.started_at = now end
    self:_statistics('checkpoint')
    return true
end

local function staged(error_value, stage)
    if type(error_value) == "table" and error_value.code then
        error_value.details = type(error_value.details) == "table" and error_value.details or {}
        error_value.details.stage = error_value.details.stage or stage
    end
    return error_value
end

function ReaderSession:_reader_error(message, cause, stage)
    if type(cause) == "table" and cause.code then return staged(cause, stage) end
    return Errors.new(Errors.STORAGE_ERROR, message, { stage = stage })
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
    state.on_complete = nil
    if notification then notification.notified = true; notification.callback = nil end
    pcall(callback, value, err)
    return true
end

function ReaderSession:_fail_candidate(state, error_value)
    if self.pending == state then self.pending = nil end
    state.cancelled, state.active = true, false
    state.error = self:_reader_error("KOReader could not activate generated chapter", error_value, "reader_open")
    local previous = state.previous
    if previous and previous.document and previous.document.closed ~= true then
        previous.active = true
        self.active = previous
    else
        if previous then previous.active = false end
        if self.active == previous or self.active == state then self.active = nil end
    end
    self.diagnostics("reader", state.error)
    self:_notify(state, nil, state.error)
    return nil, state.error
end

function ReaderSession:_scheduleBackgroundCatalog(state)
    if state.offline or state.catalog_complete ~= false or not self.scheduler or not self.scheduler.scheduleIn then return false end
    if self.catalog_state==state or self.catalog_background_action then return true end
    self.catalog_background_generation = self.catalog_background_generation + 1
    local generation = self.catalog_background_generation
    local function load()
        local current=self.active
        if generation ~= self.catalog_background_generation or not same_book(current,state) or not current.active then return end
        self.catalog_background_action = nil
        self:loadCatalog(current, function(_, err)
            if not err and same_book(self.active,current) and self.active.active then self:_prefetch(self.active) end
        end)
    end
    self.catalog_background_action = load
    -- Reader commit already happened; yield for its first paint, not a UI
    -- refresh-throttle interval. Directory collection is independent of menus.
    self.scheduler:scheduleIn(.1, load)
    return true
end

function ReaderSession:_schedulePrefetch(state)
    if not self.scheduler or not self.scheduler.scheduleIn then return self:_prefetch(state) end
    local action = self.prefetch_action
    if action and self.scheduler.unschedule then self.scheduler:unschedule(action) end
    self.prefetch_action = nil
    self:_retainPrefetch(state)
    state.prefetch_status = { total = math.min(self:prefetchCount(), #state.chapters - state.index), cached = 0 }
    local generation = self.prefetch_generation
    local function run()
        if generation ~= self.prefetch_generation or self.active ~= state or not state.active then return end
        self.prefetch_action = nil
        self:_prefetch(state)
        if state.document and state.document.getPagePosition then
            local page, total = state.document:getPagePosition()
            self:onPageUpdate(state, state.document, page, total)
        end
    end
    self.prefetch_action = run
    -- Start the successor request while the current document is already
    -- committed.  The transport remains asynchronous, so this does not block
    -- the reader.  Keep one zero-delay pass for transports that complete
    -- synchronously and for the normal page-position check.
    run()
    if generation == self.prefetch_generation and self.active == state and state.active
        and self.scheduler and self.scheduler.scheduleIn then
        self.prefetch_action = run
        self.scheduler:scheduleIn(0, run)
    end
end

function ReaderSession:_activate_candidate(state, document)
    if self.pending ~= state or state.cancelled or not self:_isCurrent(state) then
        return nil, self:_reader_error("stale reader-ready callback", nil, "reader_open")
    end
    if state.restore_fraction ~= nil and not (document and document.restored_on_open) then
        if not document or type(document.setProgressFraction) ~= "function" then
            return self:_fail_candidate(state, self:_reader_error("KOReader progress restore API is unavailable", nil, "reader_open"))
        end
        local ok, restored, restore_error = pcall(document.setProgressFraction, document, state.restore_fraction)
        if not ok or restored == nil or restored == false then
            return self:_fail_candidate(state, restore_error or restored)
        end
    end
    if state.before_commit then
        local ok,saved,err=pcall(state.before_commit)
        if not ok or not saved then return self:_fail_candidate(state,err or saved) end
        state.before_commit=nil
    end
    local previous = state.previous
    if same_book(previous, state) then
        if state.inherits_catalog then
            local chapter=state.chapters[state.index]
            state.chapters,state.catalog_complete=previous.chapters,previous.catalog_complete
            state.catalog_error=previous.catalog_error
            state.index=self:recoverIndex(state.chapters,{chapter_uid=chapter.uid,chapter_url=chapter.url,chapter_index=state.index})
        end
        state.prefetch_failures = previous.prefetch_failures
        if self.catalog_state == previous then self.catalog_state = state end
    end
    if previous and previous ~= state then previous.active = false end
    state.document, state.restore_fraction, state.end_handled, state.active, state.started_at = document, nil, false, true, os.time()
    if state.open_started then self:_timing('reader_ready',state.open_started,state.backend,state);state.open_started=nil end
    local stored=self.storage.getProgress and self.storage:getProgress(state.book.id)
    local inherited=state.reader_settings_book_id and self.storage.getProgress and self.storage:getProgress(state.reader_settings_book_id)
    state.inherited_layout=inherited and {reader_settings=inherited.reader_settings,immersive_style=inherited.immersive_style} or nil
    state.reading_seconds=stored and stored.reading_seconds or 0
    local fraction_ok,fraction=pcall(function() return document and document.getProgressFraction and document:getProgressFraction() end)
    state.initial_fraction=fraction_ok and tonumber(fraction) or 0
    state.statistics_book_id=state.statistics_book_id or (stored and stored.statistics_book_id)
        or (inherited and inherited.statistics_book_id) or state.reader_settings_book_id or state.book.id
    state.reader_settings_book_id = nil -- source inheritance is only for this first open
    if document then document.reading_state = state end
    self.active, self.pending = state, nil
    if self.cache and self.cache.setActive then
        self.cache:setActive({source_id=source_id(state.source,state.book),book_id=state.book.id})
    end
    self:_statistics('start',state.book,self:_statisticsPage(state,document),state.statistics_book_id)
    if state.prepared_html then state.prepared_html[state.chapters[state.index].uid] = nil end
    if state.offline then
        local chapter = state.chapters[state.index]
        self.last_offline_chapter = { index = state.index, chapter_uid = chapter and chapter.uid }
    end
    if not (document and document.defer_notification) then self:_committed(state, document) end
    return document
end

function ReaderSession:_committed(state, document)
    if self.active ~= state or not state.active or state.document ~= document or state.committed then return false end
    state.committed = true
    self:_notify(state, document, nil)
    -- The launch intent belongs to the detail screen, not to subsequent page turns.
    state.is_current = nil
    state.on_progress = nil
    -- The previous view is only needed until commit; retaining it chains every chapter.
    state.previous = nil
    if not state.offline and self.active == state and state.active then
        self:_schedulePrefetch(state)
        self:_scheduleBackgroundCatalog(state)
    end
    return true
end

function ReaderSession:_callbacks(state)
    return {
        now = clock,
        timing = function(stage, started, details) self:_timing(stage, started, state.backend, state, details) end,
        can_open = function() return self.pending == state and not state.cancelled and self:_isCurrent(state) end,
        native_statistics=self.statistics~=nil,
        save_style=function(style)
            if self.active~=state or not state.active then return nil,Errors.new(Errors.CANCELLED,'阅读会话已切换') end
            local saved,err=self:_save(state,state.document)
            if not saved then return nil,err end
            local progress;progress,err=self.storage:getProgress(state.book.id)
            if err then return nil,err end
            progress.immersive_style=style
            return self.storage:putProgress(progress)
        end,
        chapter=function(index,request) return self:navigate(index,request) end,
        refresh=function(request) return self:navigate(state.index,request) end,
        error=function(_,err) self.diagnostics('read',err) end,
        context=function(_,base)
            local elapsed=not state.paused and state.started_at and math.max(0,os.time()-state.started_at) or 0
            local context={reading_seconds=(state.reading_seconds or 0)+elapsed,prefetch=state.prefetch_status,
                catalog_error=state.catalog_error and state.catalog_error.code}
            if state.backend=='immersive' and state.prefetch_status and self.ui.getPreparedChapterStatus then
                local ok, prepared=pcall(self.ui.getPreparedChapterStatus,self.ui,state)
                if ok and prepared then
                    context.prefetch={total=state.prefetch_status.total,cached=state.prefetch_status.cached,
                        first_pages=prepared.first_pages,paginated=prepared.paginated}
                end
            end
            local duration=(state.chapter_seconds or 0)+elapsed
            local advanced=(base.chapter_fraction or 0)-(state.initial_fraction or 0)
            if duration>=10 and advanced>.02 then
                -- ponytail: estimate from this chapter's observed forward progress, reset on chapter change.
                local remaining=math.max(0,duration/advanced*(1-base.chapter_fraction))
                context.chapter_remaining=remaining
                context.chapter_remaining_text=remaining<60 and '不足 1 分钟' or ('约 '..math.ceil(remaining/60)..' 分钟')
            end
            return context
        end,
        read_settings = function()
            local book_id = state.reader_settings_book_id or state.book.id
            local previous = state.previous
            local progress = previous and previous.book.id == book_id and previous.pending_progress
            local err
            if not progress and type(self.storage.getProgress) == 'function' then progress, err = self.storage:getProgress(book_id) end
            return progress and progress.reader_settings, err
        end,
        ready = function(document)
            return self:_activate_candidate(state, document)
        end,
        committed = function(document) return self:_committed(state, document) end,
        failure = function(error_value)
            if self.pending == state and not state.cancelled then self:_fail_candidate(state, error_value) end
        end,
        flush = function(document)
            if self.active == state and state.active and document == state.document then return self:_save(state, document) end
        end,
        pause = function(document, suspend)
            if self.active == state and state.active and document == state.document and suspend then
                self:_cancelForeground(); self:_cancelPrefetch(); self:_cancelCatalog()
                if self.pending then self.pending.cancelled = true; self.pending = nil end
                state.end_handled = false
                state.prefetch_catalog_key, state.near_end_prefetch = nil, nil
            end
            if self.active == state and state.active and document == state.document and not state.paused then
                local saved, err = self:_save(state, document)
                if not saved and document.backend=='immersive' and not suspend then return nil,err end
                state.paused, state.started_at = true, nil
                self:_statistics('pause')
                return saved, err
            end
            return true
        end,
        resume = function(document)
            if self.active == state and state.active and document == state.document and state.paused then
                state.paused, state.started_at = false, os.time()
                self:_statistics('resume',self:_statisticsPage(state,document))
                self:_schedulePrefetch(state)
                self:_scheduleBackgroundCatalog(state)
            end
        end,
        close = function(document)
            if self.active == state and state.active and document == state.document then
                local replacing=self.pending and self.pending.previous==state
                -- _open_cached already saved this chapter before replacement.
                -- An ordinary host close still needs its final position saved.
                local saved,save_error=true,nil
                if not replacing then saved,save_error=self:_save(state, document) end
                self:_statistics('close')
                -- Native ReaderUI closes the old chapter before ready(new).
                -- The selecting drawer owns is_current until that ready event;
                -- closing it here would cancel its own successful navigation.
                if not replacing and state.side_toc and state.side_toc.close then pcall(state.side_toc.close, state.side_toc) end
                state.active = false
                self:_cancelForeground()
                self:_cancelPrefetch()
                if not (replacing and same_book(state,self.pending)) then self:_cancelCatalog() end
                return saved,save_error
            end
        end,
        end_of_book = function(document, started)
            if self.active == state and state.active and document == state.document then return self:_end(state, document, started) end
        end,
        page_update = function(document, page, total)
            if state.side_toc and state.side_toc.setCurrent then
                pcall(state.side_toc.setCurrent, state.side_toc, state.index)
            end
            return self:onPageUpdate(state, document, page, total)
        end,
    }
end

function ReaderSession:_prepareHtml(state, chapter, body)
    local started=clock()
    state.prepared_html = state.prepared_html or {}
    local checksum = Identity.hash(body)
    local prepared = state.prepared_html[chapter.uid]
    if prepared and prepared.checksum == checksum and prepared.title == chapter.title then
        if not self.cache.readHtml or self.cache:readHtml(source_id(state.source, state.book), state.book.id, chapter) then
            self:_timing('html_reused',started,'native',state)
            return prepared.path
        end
    end
    local path, err = self.cache:writeHtml(source_id(state.source, state.book), state.book.id, chapter, html_document(chapter.title, body))
    if not path then return nil, staged(err, 'html_write') end
    state.prepared_html[chapter.uid] = { path = path, checksum = checksum, title = chapter.title }
    self:_timing('html_write',started,'native',state)
    return path
end

function ReaderSession:_open_cached(state, index, restore_fraction)
    if not self:_isCurrent(state) then return nil, Errors.new(Errors.CANCELLED, "reading intent is stale") end
    if not state.transition then self:_beginTransition(state) end
    local chapter = state.chapters[index]
    local started=clock()
    local body, error_value = self.cache:readBody(source_id(state.source, state.book), state.book.id, chapter)
    self:_timing(body and 'cache_hit' or 'cache_miss',started,state.backend,state)
    if not body then return nil, staged(error_value, "cache_read") end
    local backend=state.backend or preferred_backend(self)
    local previous=self.active
    if previous and (previous.active or previous.pending_progress) then
        local save_started=clock()
        local saved,err=self:_save(previous,previous.document)
        self:_timing('progress_save',save_started,backend,state)
        if not saved then return nil,staged(err,'progress') end
    end
    if state.on_progress then state.on_progress(3,'整理章节') end
    local path,progress,write_error
    if backend=='immersive' then
        if not self.ui.openChapter then return nil,self:_reader_error('独立阅读器接口不可用',nil,'reader_open') end
        progress,write_error=self.storage:getProgress(state.reader_settings_book_id or state.book.id)
        if write_error then return nil,staged(write_error,'progress') end
    else
        path,write_error=self:_prepareHtml(state,chapter,body)
        if not path then return nil,staged(write_error,'html_write') end
    end
    self.next_token = self.next_token + 1
    local candidate = {
        token = self.next_token, source = state.source, book = state.book, chapters = state.chapters,
        index = index, restore_fraction = restore_fraction, previous = self.active, active = false,
        offline = state.offline, on_complete = state.on_complete, notification = state.notification,
        catalog_complete = state.catalog_complete,
        inherits_catalog = previous and state.chapters==previous.chapters,
        prepared_html = state.prepared_html,
        reader_settings_book_id = state.reader_settings_book_id,
        statistics_book_id = state.statistics_book_id,
        backend=backend, before_commit=state.before_commit, open_started=clock(), transition=state.transition,
        on_progress = state.on_progress,
        is_current = state.is_current,
    }
    if self.pending then self.pending.cancelled = true end
    self.pending = candidate
    if state.on_progress then state.on_progress(4,'打开阅读器') end
    local ok, document, open_error
    if backend=='immersive' then
        ok,document,open_error=pcall(self.ui.openChapter,self.ui,{state=candidate,body=body,progress=progress},self:_callbacks(candidate))
    else
        ok,document,open_error=pcall(self.ui.openDocument,self.ui,path,self:_callbacks(candidate))
    end
    if candidate.error then return nil,candidate.error end
    if not ok then return self:_fail_candidate(candidate, document) end
    if not document then return self:_fail_candidate(candidate, open_error or Errors.new(Errors.STORAGE_ERROR, "阅读器无法打开缓存章节", { stage = "reader_open" })) end
    candidate.opened_document = document
    return document
end

function ReaderSession:_fetch_then_open(state, index, restore_fraction)
    if state.on_progress then state.on_progress(2,'正在准备章节：'..tostring(state.chapters[index].title or '')) end
    if not self.service or type(self.service.getContent) ~= "function" then
        state.fetching, state.end_handled = false, false
        local error_value = Errors.new(Errors.STORAGE_ERROR, "chapter is not cached and BookService is unavailable", { stage = "fetch" })
        self.diagnostics("read", error_value)
        self:_notify(state, nil, error_value)
        return nil, error_value
    end
    local chapter = state.chapters[index]
    local prefetch = self.prefetch_requests[chapter.uid]
    if not prefetch or (prefetch.state ~= state and prefetch.state~=state.origin) or prefetch.chapter.uid ~= chapter.uid then
        self:_cancelPrefetch()
        prefetch = nil
    end
    self:_cancelForeground()
    local generation = self.foreground_generation
    state.fetching = true
    self.foreground_state = state
    local completed = false
    local fetch_started=clock()
    local function callback(content, request_error, cached)
        if completed then return end
        completed = true
        self:_timing('foreground_content',fetch_started,state.backend,state)
        -- BookService's third callback argument is trace metadata, not a cache flag.
        cached = cached == true
        if not self:_isCurrent(state) then
            state.fetching = false
            if self.foreground_state == state then self.foreground_handles, self.foreground_state = {}, nil end
            return
        end
        if generation ~= self.foreground_generation or self.foreground_state ~= state then return end
        if self.active ~= state and state.active then return end
        state.fetching = false
        self.foreground_handles, self.foreground_state = {}, nil
        if request_error or (not content and not cached) then
            state.end_handled = false
            local err = staged(request_error or Errors.new(Errors.NETWORK_ERROR, "empty content"), "fetch")
            self.diagnostics("read", err); self:_notify(state, nil, err); return
        end
        if not cached then
            local body, clean_error = Cleaner.normalize(content.content or content, { replaceRegex = state.source.replaceRegex })
            if not body then clean_error = staged(clean_error, "clean"); state.end_handled = false; self.diagnostics("read", clean_error); self:_notify(state, nil, clean_error); return end
            local saved, save_error = self.cache:writeBody(source_id(state.source, state.book), state.book.id, chapter, body)
            if not saved then save_error = staged(save_error, "body_write"); state.end_handled = false; self.diagnostics("read", save_error); self:_notify(state, nil, save_error); return end
        end
        local opened, open_error = self:_open_cached(state, index, restore_fraction)
        if not opened then
            local current = self.active == state and state or self.active
            if current then current.end_handled = false end
            local err = open_error or Errors.new(Errors.STORAGE_ERROR, "KOReader could not open fetched chapter")
            self.diagnostics("read", err)
            self:_notify(state, nil, err)
        end
    end
    if prefetch then
        -- The background request already owns all content pages and cancellation.
        prefetch.foreground = callback
        if prefetch.handle and prefetch.handle.promote then prefetch.handle:promote('foreground') end
        local subscription = { cancel = function()
            if generation == self.foreground_generation and self.foreground_state == state then self:_cancelForeground() end
        end }
        state.fetch_handle = subscription
        return subscription
    end
    local ok, handle, request_error = pcall(self.service.getContent, self.service, state.source, state.book, chapter, callback, { priority = 'foreground' })
    if not ok or not handle then
        state.fetching, state.end_handled = false, false
        local err = not ok and self:_reader_error("foreground request failed", handle, "fetch") or staged(request_error or Errors.new(Errors.NETWORK_ERROR, "foreground request did not start"), "fetch")
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

function ReaderSession:_end(state, document, started)
    if state.end_handled then return end
    self:_beginTransition(state, started)
    started = state.transition.started
    state.end_handled = true
    local next_index = state.index + 1
    if next_index > #state.chapters then
        local saved, err = self:_save(state, document)
        if not saved then state.end_handled = false; return nil, staged(err, 'progress') end
        if state.catalog_complete == false then
            if state.offline then
                state.end_handled=false
                local err=Errors.new(Errors.STORAGE_ERROR,'catalog is incomplete; connect to load more chapters')
                self.diagnostics('read',err); return nil,err
            end
            return self:loadCatalog(state,function(_,err)
                state.end_handled=false
                if err then self.diagnostics('read',err)
                elseif state.active and (state.index < #state.chapters or state.catalog_complete ~= false) then self:_end(state,document,started)
                elseif state.active then self.diagnostics('read', Errors.new(Errors.NETWORK_ERROR, 'catalog did not provide a next chapter')) end
            end, nil, { max_chapters = next_index + self:prefetchCount() })
        end
        if type(self.ui.endOfBook) == "function" then return self.ui:endOfBook(document) end
        return false
    end
    -- Keep a slow next-chapter prefetch alive; foreground navigation joins it.
    local opened, open_error = self:_open_cached(state, next_index, nil)
    if opened then return opened end
    if open_error and open_error.details and open_error.details.stage ~= 'cache_read' then
        state.end_handled = false
        self.diagnostics('read', open_error)
        return nil, open_error
    end
    if state.offline then
        state.end_handled = false
        local err = Errors.new(Errors.STORAGE_ERROR, "next chapter is not cached", { stage = "cache_read" })
        self.diagnostics("read", err)
        return nil, err
    end
    return self:_fetch_then_open(state, next_index, nil)
end

-- Independent navigation reuses foreground requests and leaves the old page visible.
function ReaderSession:navigate(index, request)
    request=request or {}
    request.input_started = request.input_started or clock()
    local active=self.active
    if not active or not active.active then return nil,Errors.new(Errors.CANCELLED,'阅读会话已关闭') end
    local generation
    local function current()
        return self.active==active and active.active and (not generation or generation==self.foreground_generation)
            and (not request.is_current or request.is_current())
    end
    if not current() then return nil,Errors.new(Errors.CANCELLED,'章节请求已取消') end
    local bookmark=request.bookmark
    local bookmark_missing=false
    if bookmark then
        if bookmark.source_id~=source_id(active.source,active.book) then
            return nil,Errors.new(Errors.INVALID_INPUT,'这个书签属于其他站点，请先切回原书源。')
        end
        bookmark_missing=true
        for position,chapter in ipairs(active.chapters) do
            if (bookmark.chapter_uid and chapter.uid==bookmark.chapter_uid)
                or (bookmark.chapter_url and chapter.url==bookmark.chapter_url) then
                index,bookmark_missing=position,false;break
            end
        end
        if bookmark_missing then
            if active.offline or active.catalog_complete~=false or (request.bookmark_attempts or 0)>=2 then
                return nil,Errors.new(Errors.INVALID_INPUT,'当前目录未找到书签章节，已保留阅读位置。')
            end
            index=math.max(tonumber(bookmark.chapter_index) or 1,#active.chapters+1)
        end
    end
    self:_cancelForeground()
    generation=self.foreground_generation
    if self.pending then self.pending.cancelled = true; self.pending = nil end
    if (bookmark_missing or index>#active.chapters) and active.catalog_complete==false then
        return self:loadCatalog(active,function(_,err)
            if not current() then return end
            if err then
                self.diagnostics('read',err)
                if request.on_complete then request.on_complete(nil,err) end
            elseif bookmark then
                local next_request={};for key,value in pairs(request)do next_request[key]=value end
                next_request.bookmark_attempts=(request.bookmark_attempts or 0)+1
                local _,failure=self:navigate(index,next_request)
                if failure and request.on_complete then request.on_complete(nil,failure) end
            elseif index<=#active.chapters then self:navigate(index,request)
            else
                local missing=Errors.new(Errors.INVALID_INPUT,'没有后续章节')
                self.diagnostics('read',missing)
                if request.on_complete then request.on_complete(nil,missing) end
            end
        end,nil,{max_chapters=index+self:prefetchCount()})
    end
    if not active.chapters[index] then return nil,Errors.new(Errors.INVALID_INPUT,'章节不存在') end
    local state={source=active.source,book=active.book,chapters=active.chapters,index=index,origin=active,
        backend=active.backend,offline=active.offline,catalog_complete=active.catalog_complete,
        prepared_html=active.prepared_html,
        statistics_book_id=active.statistics_book_id,is_current=request.is_current,
        notification={notified=false,callback=function(document,err)
            if err then
                if active.document.resumeReading then active.document:resumeReading() end
                self.diagnostics('read',err)
            end
            if request.on_complete then request.on_complete(document,err) end
        end}}
    self:_beginTransition(state, request.input_started)
    local fraction=request.last_page and 1 or request.restore_fraction
    if request.refresh then fraction=active.document:getProgressFraction() end
    if not request.refresh then
        local document,err=self:_open_cached(state,index,fraction)
        if document then return document end
        if not err or not err.details or err.details.stage~='cache_read' then return nil,err end
    end
    if state.offline then return nil,Errors.new(Errors.NETWORK_ERROR,'离线模式无法获取该章节') end
    return self:_fetch_then_open(state,index,fraction)
end

function ReaderSession:_cancelCatalog()
    self.catalog_background_generation=(self.catalog_background_generation or 0)+1
    local action=self.catalog_background_action; self.catalog_background_action=nil
    if action and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,action) end
    self.catalog_generation=(self.catalog_generation or 0)+1
    self.catalog_waiters, self.catalog_state = nil, nil
    local handle=self.catalog_request; self.catalog_request=nil
    if handle and handle.cancel then handle:cancel() end
end

function ReaderSession:_updateCatalog(state,chapters,complete,persist)
    if type(chapters)~='table' or #chapters==0 then return nil,Errors.new(Errors.PARSE_ERROR,'目录没有可用章节') end
    if not complete and #chapters<#state.chapters then return true end
    local snapshot={};for i,chapter in ipairs(chapters) do snapshot[i]=chapter end
    local current=state.chapters[state.index] or {}
    local index=self:recoverIndex(snapshot,{chapter_url=current.url,chapter_uid=current.uid,chapter_index=state.index})
    if persist then
        local path,err=self.cache:writeCatalog(state.book.source_id,state.book.id,{chapters=snapshot,complete=complete})
        if not path then return nil,err or Errors.new(Errors.STORAGE_ERROR,'目录缓存保存失败') end
        if self.storage.replaceChapters then
            local saved; saved,err=self.storage:replaceChapters(state.book.id,snapshot)
            if not saved then return nil,err or Errors.new(Errors.STORAGE_ERROR,'目录保存失败') end
        end
    end
    state.chapters,state.index,state.catalog_complete=snapshot,index,complete
    -- Publish completion once; intermediate parsing never repaints the drawer.
    if complete and state.side_toc and not state.side_toc.closed then
        pcall(state.side_toc.setItems,state.side_toc,snapshot,true)
    end
    return true
end

function ReaderSession:loadCatalog(state,callback,on_progress,options)
    options = options or {}
    if state.catalog_complete~=false then callback(state.chapters); return {cancel=function() end} end
    if not self.service or state.offline then callback(state.chapters); return {cancel=function() end} end
    local target=tonumber(options.max_chapters)
    if target then target=math.max(1,math.floor(target)) end
    if target and #state.chapters>=target then
        local ok,saved,err=pcall(self._updateCatalog,self,state,state.chapters,false,true)
        if not ok then err=self:_reader_error('catalog save failed',saved,'catalog') end
        callback(ok and saved and state.chapters or nil,err,{catalog_complete=false})
        return {cancel=function() end}
    end
    local waiter = { callback = callback, on_progress = on_progress, active = true, target=target }
    local function subscription()
        return {cancel=function()
            -- The session owns the full scan. Closing a drawer only detaches
            -- its callback; pause/close/book changes cancel through _cancelCatalog.
            waiter.active = false
        end}
    end
    if self.catalog_state == state and self.catalog_waiters then
        self.catalog_waiters[#self.catalog_waiters + 1] = waiter
        return subscription()
    end
    self:_cancelCatalog()
    local generation,completed=self.catalog_generation,false
    state.catalog_error=nil
    local waiters = { waiter }
    self.catalog_state, self.catalog_waiters = state, waiters
    local function deliver(other,chapters,err,metadata)
        other.active=false
        local ok,cause=pcall(other.callback,chapters,err,metadata)
        if not ok then pcall(self.diagnostics,'catalog',self:_reader_error('catalog subscriber failed',cause,'catalog')) end
    end
    local function finish(chapters, err, metadata)
        if completed or generation ~= self.catalog_generation then return end
        completed = true
        local request=self.catalog_request
        local owner=self.catalog_state or state
        owner.catalog_error=err
        self.catalog_request, self.catalog_state, self.catalog_waiters = nil, nil, nil
        if err then pcall(self.diagnostics,'catalog',err) end
        if err and request and request.cancel then pcall(request.cancel,request) end
        local active=self.active
        for _, other in ipairs(waiters) do
            -- A subscriber may immediately request a larger catalog. That
            -- starts a new generation, but all subscribers still own this
            -- completed result until the reading session itself changes.
            if self.active~=active then return end
            if other.active then deliver(other,chapters,err,metadata) end
        end
    end
    local function update(chapters,complete,persist)
        state=self.catalog_state or state
        local ok,saved,err=pcall(self._updateCatalog,self,state,chapters,complete,persist)
        if not ok then err=self:_reader_error('catalog update failed',saved,'catalog') end
        if not ok or not saved then finish(nil,err);return false end
        return true
    end
    local ok,handle,start_error=pcall(self.service.getChapters,self.service,state.source,state.book,function(chapters,err,metadata)
        if completed or generation~=self.catalog_generation then return end
        state = self.catalog_state or state
        if chapters and not err then
            local complete = not metadata or metadata.catalog_complete ~= false
            if not update(chapters,complete,true) then return end
        end
        finish(chapters,err,metadata)
    end,{on_progress=function(page,count,chapters)
        if completed or generation~=self.catalog_generation then return end
        if chapters and #chapters>0 then
            local ready=false
            for _,other in ipairs(waiters) do
                if other.active and other.target and #chapters>=other.target then ready=true;break end
            end
            if not update(chapters,false,ready) then return end
            local active=self.active
            for _,other in ipairs(waiters) do
                if self.active~=active then return end
                if other.active and other.target and #chapters>=other.target then
                    deliver(other,state.chapters,nil,{catalog_complete=false})
                end
            end
        end
        for _,other in ipairs(waiters) do
            if other.active and other.on_progress then pcall(other.on_progress,page,count) end
        end
    end,max_pages=options.max_pages,background_catalog=true})
    if not ok or not handle then
        finish(nil, not ok and self:_reader_error('catalog request failed',handle,'catalog')
            or start_error or Errors.new(Errors.NETWORK_ERROR,'catalog request did not start'))
    elseif not completed then self.catalog_request=handle
    elseif handle.cancel then pcall(handle.cancel,handle) end
    return subscription()
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
    if self.foreground_state then self.foreground_state.fetching, self.foreground_state.end_handled = false, false end
    for _, request in pairs(self.prefetch_requests) do request.foreground = nil end
    self.foreground_state = nil
    cancel_handles(handles)
end

function ReaderSession:_cancelPrefetch()
    self.prefetch_generation = self.prefetch_generation + 1
    local action = self.prefetch_action
    self.prefetch_action = nil
    if action and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule, self.scheduler, action) end
    local retry = self.prefetch_retry_action
    self.prefetch_retry_action = nil
    if retry and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,retry) end
    local handles = {}
    for _, request in pairs(self.prefetch_requests) do handles[#handles + 1] = request.handle end
    self.prefetch_requests = {}
    cancel_handles(handles)
end

-- Keep work that is still useful after a chapter turn. Remove ownership before
-- cancellation: a transport is allowed to deliver its cancellation callback.
function ReaderSession:_retainPrefetch(state)
    local wanted, handles = {}, {}
    if not state.offline then
        for index = state.index + 1, math.min(#state.chapters, state.index + self:prefetchCount()) do
            wanted[state.chapters[index].uid] = true
        end
    end
    for uid, request in pairs(self.prefetch_requests) do
        if same_book(request.state, state) and (wanted[uid] or request.foreground) then request.state = state
        else
            self.prefetch_requests[uid] = nil
            handles[#handles + 1] = request.handle
        end
    end
    cancel_handles(handles)
end

function ReaderSession:onPageUpdate(state, document, page, total)
    if self.active == state and state.active and state.document==document and not state.paused then
        self:_statistics('onPageChanged',self:_statisticsPage(state,document))
    end
    if self.active ~= state or not state.active or state.paused or state.document ~= document or state.offline or self:prefetchCount() == 0 then return end
    page, total = tonumber(page), tonumber(total)
    if not page or not total or page < 1 or page > total or total - page > 3 or state.near_end_prefetch then return end
    if state.near_end_retry_after and clock()<state.near_end_retry_after then return end
    state.near_end_prefetch = true
    state.near_end_retry_after = nil
    local chapter = state.chapters[state.index + 1]
    if not chapter then
        if state.catalog_complete == false then
            return self:loadCatalog(state, function(_, err)
                if self.active ~= state or not state.active then return end
                if err then
                    self.diagnostics('prefetch', err)
                    if type(err)=='table' and (err.code==Errors.NETWORK_ERROR or err.code==Errors.TIMEOUT) then
                        state.near_end_prefetch=false
                        state.near_end_retry_after=clock()+6
                    end
                elseif state.chapters[state.index + 1] then self:_prefetch(state) end
            end, nil, { max_chapters = state.index + self:prefetchCount() })
        end
        return
    end
    local request = self.prefetch_requests[chapter.uid]
    if request and request.state == state and request.chapter.uid == chapter.uid then return request.handle end
    local body = self.cache:readBody(source_id(state.source, state.book), state.book.id, chapter)
    if body then
        if state.backend~='immersive' then return self:_prepareHtml(state,chapter,body) end
        return true
    end
    return self:_prefetch(state)
end

-- Complete bodies are published by BookService only after all web pages arrive.
function ReaderSession:_preparePrefetched(state, index, body)
    local chapter = state.chapters[index]
    state.prefetch_ready = state.prefetch_ready or {}
    state.prefetch_ready[chapter.uid] = true
    state.prefetch_failures[chapter.uid] = nil
    local err
    if state.backend ~= 'immersive' then
        local path; path, err = self:_prepareHtml(state, chapter, body)
    elseif index <= state.index + 3 and self.ui.prepareChapter then
        local ok, _, prepare_error = pcall(self.ui.prepareChapter, self.ui, state, chapter, body)
        if not ok or prepare_error then
            self.diagnostics('prefetch', prepare_error or self:_reader_error('chapter preparation failed'))
        end
    end
    if err then self.diagnostics('prefetch', err) end
    return err
end

function ReaderSession:_prefetchRetry(state)
    if not self.scheduler or not self.scheduler.scheduleIn or self.prefetch_retry_action then return end
    local generation = self.prefetch_generation
    local function retry()
        self.prefetch_retry_action = nil
        local current = self.active
        if generation ~= self.prefetch_generation or not same_book(current, state) or not current.active then return end
        current.prefetch_retry_ready = current.prefetch_retry_ready or {}
        for uid, failures in pairs(current.prefetch_failures or {}) do
            if failures == 1 then current.prefetch_retry_ready[uid] = true end
        end
        self:_prefetch(current)
    end
    self.prefetch_retry_action = retry
    self.scheduler:scheduleIn(1, retry)
end

function ReaderSession:_prefetchRequest(state, index)
    local chapter, source = state.chapters[index], source_id(state.source, state.book)
    local request = { state = state, chapter = chapter, started = clock() }
    self.prefetch_requests[chapter.uid] = request
    local function callback(content, err)
        if self.prefetch_requests[chapter.uid] ~= request then return end
        self.prefetch_requests[chapter.uid] = nil
        local current = request.state
        if self.active ~= current or not current.active then return end
        self:_timing('prefetch_content', request.started, current.backend)
        if content and not err then
            local body, clean_error = Cleaner.normalize(content.content or content, { replaceRegex = current.source.replaceRegex })
            if body then
                local saved, save_error = self.cache:writeBody(source, current.book.id, chapter, body)
                if saved then
                    for i = current.index + 1, math.min(#current.chapters, current.index + self:prefetchCount()) do
                        if current.chapters[i].uid == chapter.uid then err = self:_preparePrefetched(current, i, body); break end
                    end
                else err = staged(save_error, 'body_write') end
            else err = staged(clean_error, 'clean') end
        else err = err or Errors.new(Errors.NETWORK_ERROR, 'empty content') end
        if err then
            local retryable = type(err) == 'table' and (err.code == Errors.NETWORK_ERROR or err.code == Errors.TIMEOUT)
            local failures = retryable and ((current.prefetch_failures[chapter.uid] or 0) + 1) or 2
            current.prefetch_failures[chapter.uid] = failures
            self.diagnostics('prefetch', err)
            if failures == 1 then self:_prefetchRetry(current) end
        end
        if request.foreground then
            request.foreground(nil, err, true)
            -- A native reader may still be opening asynchronously. Its ready
            -- callback, not this old session, schedules the following window.
            return
        end
        self:_prefetch(current)
    end
    local ok, handle, err = pcall(self.service.getContent, self.service, state.source, state.book, chapter, callback,
        { priority = index == state.index + 1 and 'next' or 'background' })
    if not ok or not handle then
        callback(nil, not ok and self:_reader_error('prefetch request failed', handle)
            or err or Errors.new(Errors.NETWORK_ERROR, 'prefetch request did not start'))
    elseif self.prefetch_requests[chapter.uid] == request then request.handle = handle end
end

function ReaderSession:_prefetch(state)
    if self.active ~= state or not state.active then return end
    self:_retainPrefetch(state)
    if state.offline or state.paused or self:prefetchCount() == 0
        or not self.service or type(self.service.getContent) ~= 'function' then return end
    -- Synchronous cache/transport callbacks request another pass without growing
    -- the Lua stack or accidentally occupying more than two network slots.
    if self.prefetch_pumping then self.prefetch_again = true; return end
    self.prefetch_pumping = true
    repeat
        self.prefetch_again = false
        state = self.active
        if not state or not state.active or state.paused or state.offline then break end
        state.prefetch_failures = state.prefetch_failures or {}
        state.prefetch_ready = state.prefetch_ready or {}
        local target = state.index + self:prefetchCount()
        if #state.chapters < target and state.catalog_complete == false then
            local catalog_key = tostring(#state.chapters) .. ':' .. tostring(target)
            if state.prefetch_catalog_key ~= catalog_key then
                state.prefetch_catalog_key = catalog_key
                self:loadCatalog(state, function(_, err)
                    if self.active ~= state or not state.active then return end
                    if err then self.diagnostics('prefetch', err) else self:_prefetch(state) end
                end, nil, { max_chapters = target })
            end
        end
        local status = { total = math.min(self:prefetchCount(), #state.chapters - state.index), cached = 0 }
        state.prefetch_status = status
        local running = 0
        for _ in pairs(self.prefetch_requests) do running = running + 1 end
        for index = state.index + 1, math.min(#state.chapters, target) do
            local chapter = state.chapters[index]
            local request = self.prefetch_requests[chapter.uid]
            if request then
                if index == state.index + 1 and request.handle and request.handle.promote then request.handle:promote('next') end
            elseif not state.prefetch_ready[chapter.uid] then
                local body = self.cache:readBody(source_id(state.source, state.book), state.book.id, chapter)
                if body then self:_preparePrefetched(state, index, body)
                elseif running < 2 and not state.fetching and not self.pending then
                    local failures = state.prefetch_failures[chapter.uid] or 0
                    if failures == 0 or (failures == 1 and state.prefetch_retry_ready and state.prefetch_retry_ready[chapter.uid]) then
                        if state.prefetch_retry_ready then state.prefetch_retry_ready[chapter.uid] = nil end
                        self:_prefetchRequest(state, index)
                        if self.prefetch_requests[chapter.uid] then running = running + 1 end
                    elseif failures == 1 then self:_prefetchRetry(state)
                    end
                end
            end
            if state.prefetch_ready[chapter.uid] then status.cached = status.cached + 1 end
        end
    until not self.prefetch_again
    self.prefetch_pumping = false
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
    self:_cancelCatalog()
    if self.pending then self.pending.cancelled = true; self.pending = nil end
    local notification = { callback = options.on_complete, notified = false }
    local state = { source = source, book = book, chapters = chapters,
        index = math.max(1, math.min(#chapters, tonumber(index) or 1)), active = false,
        catalog_complete = options.catalog_complete ~= false,
        reader_settings_book_id = options.reader_settings_book_id,
        statistics_book_id = options.statistics_book_id,
        backend=options.backend,before_commit=options.before_commit,
        on_progress = options.on_progress,
        on_complete = options.on_complete, notification = notification, is_current = options.is_current }
    if not self:_isCurrent(state) then return nil, Errors.new(Errors.CANCELLED, "reading intent is stale") end
    local document, error_value = self:_open_cached(state, state.index, options.restore_fraction)
    if document then return document end
    if error_value and error_value.details and error_value.details.stage=='cache_read' then
        local handle, fetch_error = self:_fetch_then_open(state, state.index, options.restore_fraction)
        return handle, fetch_error
    end
    self:_notify(state, nil, error_value)
    return nil, error_value
end

function ReaderSession:resume(source, book, chapters, callback, options)
    options = options or {}
    local backend = options.backend or preferred_backend(self)
    local progress = self.storage:getProgress(book.id)
    local index = 1
    if progress then index = self:recoverIndex(chapters, progress) end
    return self:open(source, book, chapters, index, {
        backend = backend,
        restore_fraction = backend~='immersive'
            and progress and clamp(progress.fraction, 0, 1) or nil,
        on_complete = callback,
        is_current = options.is_current,
        catalog_complete = options.catalog_complete,
        on_progress = options.on_progress,
    })
end

function ReaderSession:openOffline(source, book, index, callback, options)
    options = options or {}
    local backend = options.backend or preferred_backend(self)
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
    self:_cancelForeground()
    self:_cancelPrefetch()
    self:_cancelCatalog()
    local progress = index == nil and type(self.storage.getProgress) == "function" and self.storage:getProgress(book.id) or nil
    if progress then index = self:recoverIndex(chapters, progress) end
    local wanted = math.max(1, math.min(#chapters, tonumber(index) or 1))
    local notification = { callback = callback, notified = false }
    for candidate = wanted, 1, -1 do
        local state = { source = source, book = book, chapters = chapters, index = candidate,
            catalog_complete = catalog.complete == true,
            active = false, offline = true, backend = backend, on_complete = callback, notification = notification,
            is_current = options.is_current }
        local fraction = backend~='immersive'
            and progress and candidate == wanted and clamp(progress.fraction, 0, 1) or nil
        local document, open_error = self:_open_cached(state, candidate, fraction)
        if document then return document end
        if not open_error or not open_error.details or open_error.details.stage~='cache_read' then
            self:_notify(state,nil,open_error)
            return nil,open_error
        end
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
    self:_cancelCatalog()
    self:_cancelForeground()
    self:_cancelPrefetch()
    if self.pending then self.pending.cancelled = true; self.pending = nil end
    if self.active and (self.active.active or self.active.pending_progress) then
        local saved,err=self:_save(self.active,self.active.document)
        if not saved then return nil,err end
        local document=self.active.document
        self.active.active=false
        if document and document.backend=='immersive' and not document.closed then document:close() end
    end
    self:_statistics('close')
    self.active = nil
    if self.cache and self.cache.setActive then self.cache:setActive(nil) end
    return true
end

return ReaderSession
