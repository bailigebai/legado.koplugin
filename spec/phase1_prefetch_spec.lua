local A = require('assertions')
local Session = require('legado.lib.reader_session')
local Fakes = require('support.network_fakes')
local count = 0
local function eq(want, got, why) count = count + 1; A.equal(want, got, why) end
local source, book = { id = 's' }, { id = 'b', source_id = 's' }
local chapters = {}
for i = 1, 5 do chapters[i] = { uid = 'c' .. i, index = i, title = 'Chapter ' .. i, url = 'https://s/' .. i } end
local function fixture(options)
    options = options or {}
    local f = { requests = {}, catalog_requests = {}, opened = {}, bodies = { c1 = '<p>First</p>' }, html = {}, writes = {}, diagnostics = {}, ended = 0 }
    local scheduler = Fakes.scheduler()
    local cache = {
        readBody = function(_, _, _, chapter) return f.bodies[chapter.uid], { code = 'STORAGE_ERROR', message = 'unavailable' } end,
        writeBody = function(_, _, _, chapter, body) f.bodies[chapter.uid] = body; return true end,
        writeHtml = function(_, _, _, chapter, html)
            if f.html_error then return nil, { code = 'STORAGE_ERROR', message = 'disk full' } end
            f.html[chapter.uid] = html; f.writes[chapter.uid] = (f.writes[chapter.uid] or 0) + 1
            return chapter.uid .. '.html'
        end,
        readHtml = function(_, _, _, chapter) return f.html[chapter.uid], chapter.uid .. '.html' end,
        writeCatalog = function(_, _, _, catalog) f.catalog = catalog; return 'catalog.json' end,
        readCatalog = function() return f.catalog end,
    }
    local service = {
        getContent = function(_, _, _, chapter, callback)
            local request = { chapter = chapter, callback = callback, cancelled = 0 }
            request.cancel = function() request.cancelled = request.cancelled + 1 end
            f.requests[#f.requests + 1] = request
            return request
        end,
        getChapters = function(_, _, _, callback, request_options)
            local request = { callback = callback, cancelled = 0 }
            f.catalog_options = request_options
            request.cancel = function() request.cancelled = request.cancelled + 1 end
            f.catalog_requests[#f.catalog_requests + 1] = request
            return request
        end,
    }
    local ui = {
        openDocument = function(_, path, callbacks)
            local doc = { getProgressFraction = function() return .5 end, getPagePosition = function() return f.page or 1, f.pages or 12 end }
            f.opened[#f.opened + 1] = { path = path, document = doc, callbacks = callbacks }
            if not f.delay_ready then callbacks.ready(doc) end
            return doc
        end,
        endOfBook = function() f.ended = f.ended + 1 end,
    }
    f.session = Session.new { cache = cache, storage = { putProgress = function() return true end }, ui = ui,
        service = service, scheduler = scheduler, settings = { get = function() return options.prefetch or 3 end },
        diagnostics = function(kind, err) f.diagnostics[#f.diagnostics + 1] = { kind = kind, err = err } end }
    f.scheduler, f.cache, f.service = scheduler, cache, service
    f.open = function(list, index, opts) return f.session:open(source, book, list or chapters, index or 1, opts or {}) end
    f.page_update = function(page, total)
        f.page, f.pages = page, total
        local opened = f.opened[#f.opened]
        if opened.callbacks.page_update then opened.callbacks.page_update(opened.document, page, total) end
    end
    f.finish = function(index, content, err) f.requests[index].callback(content and { content = content, pages = 2 }, err) end
    f.next = function() local opened = f.opened[#f.opened]; opened.callbacks.end_of_book(opened.document) end
    return f
end

-- The first successor must start downloading as soon as the current reader is
-- committed; waiting for a later scheduler turn leaves a fast reader racing
-- the network at the chapter boundary.
do
    local f = fixture(); f.open()
    eq('c2', f.requests[1] and f.requests[1].chapter.uid,
        'committed reader starts next chapter prefetch immediately')
    f.session:close()
end

-- The delayed background catalog pass must request the complete catalog.
do
    local f = fixture(); f.open(nil, 1, { catalog_complete = false })
    f.scheduler:runNext() -- immediate prefetch work
    f.scheduler:runNext() -- background catalog after first paint
    eq(1, #f.catalog_requests, 'background catalog starts after the first-paint yield')
    eq(nil, f.catalog_options.max_chapters, 'background catalog is not capped to a partial page')
    f.session:close()
end

-- Removing in-flight reuse makes this issue a repeated slow network request.
do
    local f = fixture(); f.open(); f.scheduler:runNext()
    f.finish(1, '<p>Second ready</p>'); f.finish(2, '<p>Third ready</p>')
    eq('c4', f.requests[3].chapter.uid, 'fourth chapter is in flight behind two cached chapters')
    f.html.c3 = nil -- The new immediate chapter must still be prepared locally.
    f.next(); f.scheduler:runNext()
    eq(0, f.requests[3].cancelled, 'same-book transition retains a farther useful in-flight chapter')
    eq(4, #f.requests, 'retained fourth chapter leaves a free slot for the new window end')
    eq(true, f.html.c3 ~= nil, 'retaining farther work still prepares the immediate cached chapter')
    eq(1, f.session.active.prefetch_status.cached, 'new window counts its immediate cached chapter')
    f.finish(3, '<p>Fourth ready</p>')
    eq('c5', f.requests[4].chapter.uid, 'retained chain continues to the new window end')
    f.finish(4, '<p>Fifth ready</p>')
    eq(3, f.session.active.prefetch_status.cached, 'transferred chain completes the new window')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.scheduler:runNext()
    f.finish(1, '<p>Second already ready</p>')
    eq('c3', f.requests[2].chapter.uid, 'third chapter is already in flight')
    f.next(); f.scheduler:runNext()
    eq(0, f.requests[2].cancelled, 'same-book transition retains useful future chapter')
    local attempts=0
    for _,request in ipairs(f.requests) do if request.chapter.uid=='c3' then attempts=attempts+1 end end
    eq(1, attempts, 'same-book transition does not restart third chapter')
    f.finish(2,'<p>Third complete after transition</p>')
    eq('<p>Third complete after transition</p>',f.bodies.c3,'transferred prefetch publishes to current session')
    f.next();eq(3,f.session.active.index,'transferred ready chapter opens without network')
    f.session:close()
end

do
    local f=fixture();f.open({chapters[1]},1,{catalog_complete=false});f.scheduler:runNext()
    eq(1,#f.catalog_requests,'initial prefetch immediately resolves missing next catalog entry')
    f.catalog_requests[1].callback(chapters,nil,{catalog_complete=true})
    eq('c2',f.requests[1].chapter.uid,'newly resolved next chapter starts immediately')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.scheduler:runNext()
    eq('c2', f.requests[1].chapter.uid, 'next chapter receives the first background request')
    f.next(); f.next()
    eq(0, f.requests[1].cancelled, 'chapter end preserves its in-flight next chapter')
    eq(2, #f.requests, 'repeated chapter-end events share one pending request alongside the later chapter')
    f.finish(1, '<p>Page one</p>\n<p>Page two</p>')
    eq(2, f.session.active.index, 'complete multi-page chapter opens from the shared request')
    eq(true, f.html.c2:find('Page two', 1, true) ~= nil, 'prepared HTML contains the full chapter')
    eq(1, f.writes.c2, 'chapter opening reuses the prepared HTML')
    f.session:close()
end

-- The remaining-pages boundary must start before the startup timer, and dedupe redraws.
do
    local f=fixture({prefetch=1}); f.open(); f.scheduler:runNext()
    f.finish(1,nil,{code='TIMEOUT'})
    f.scheduler:runNext()
    eq(2,#f.requests,'one automatic retry follows a network failure')
    f.finish(2,nil,{code='TIMEOUT'}); f.scheduler:runAll()
    eq(2,#f.requests,'repeated network failure cannot loop automatically')
    f.page_update(9,12); eq(2,#f.requests,'redraw does not reset retry allowance')
    f.next(); eq(3,#f.requests,'explicit navigation may retry after automatic allowance')
    f.session:close(); f.scheduler:runAll()
end
for _,code in ipairs({'PARSE_ERROR','STORAGE_ERROR'}) do
    local f=fixture({prefetch=1}); f.open(); f.scheduler:runNext()
    f.finish(1,nil,{code=code}); f.scheduler:runAll()
    eq(1,#f.requests,code..' does not cause automatic download retries')
    f.session:close()
end
do
    local options={prefetch=3}; local f=fixture(options); f.open(); f.scheduler:runNext()
    options.prefetch=0; f.finish(1,'<p>Already in flight</p>')
    eq(2,#f.requests,'disabling prefetch starts no further requests')
    eq(1,f.requests[2].cancelled,'disabling prefetch cancels the other speculative request')
    f.session:close()
end
do
    local f=fixture({prefetch=1}); f.open(); f.scheduler:runNext()
    f.finish(1,nil,{code='NETWORK_ERROR'}); f.session:close(); f.scheduler:runAll()
    eq(1,#f.requests,'closing cancels the scheduled network retry')
end
do
    local f = fixture(); f.open()
    local started = #f.requests
    eq(2, started, 'committed reader starts the bounded upcoming pair')
    f.page_update(8, 12); eq(started, #f.requests, 'four remaining pages does not duplicate prefetch')
    f.page_update(9, 12); eq(started, #f.requests, 'three remaining pages reuses the existing prefetch')
    f.page_update(10, 12); f.page_update(9, 12)
    eq(started, #f.requests, 'repeat and backward page updates keep the same requests')
    f.finish(1, '<p>Next chapter</p>')
    eq(true, f.html.c2 ~= nil, 'HTML is prepared before reaching chapter end')
    f.next(); eq(2, f.session.active.index, 'ready next chapter opens immediately')
    eq(1, f.writes.c2, 'ready chapter HTML is not rebuilt at chapter end')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.scheduler:runNext()
    f.finish(1, nil, { code = 'NETWORK_ERROR', message = 'timeout' })
    eq('c3', f.requests[2].chapter.uid, 'background chain continues after a failed speculative chapter')
    f.page_update(9, 12)
    eq(0, f.requests[2].cancelled, 'near-end redraw preserves useful later work during retry backoff')
    eq('c4', f.requests[3].chapter.uid, 'a failed nearest chapter does not block the third successor')
    f.next(); eq('c2', f.requests[4].chapter.uid, 'explicit foreground retry takes priority over later work')
    f.finish(4, nil, { code = 'NETWORK_ERROR', message = 'timeout' })
    eq(false, f.session.active.end_handled, 'joined failure releases the chapter-end guard')
    f.next(); eq('c2', f.requests[#f.requests].chapter.uid, 'a later page turn can retry a failed next chapter')
    f.session:close()
end

do
    local f = fixture(); f.open({ chapters[1] }, 1, { catalog_complete = false })
    f.page_update(9, 12)
    eq(1, #f.catalog_requests, 'missing next catalog entry is loaded at three remaining pages')
    f.next(); f.page_update(10, 12)
    eq(1, #f.catalog_requests, 'chapter end reuses the catalog already loading')
    eq(0, f.catalog_requests[1].cancelled, 'in-flight catalog is not cancelled at chapter end')
    f.catalog_requests[1].callback(chapters, nil, { catalog_complete = true })
    eq(2, #f.requests, 'expanded catalog starts one request per chapter in the bounded pair')
    eq('c2', f.requests[1].chapter.uid, 'catalog expansion prioritizes the immediate next chapter')
    f.finish(1, '<p>Next</p>'); eq(2, f.session.active.index, 'pending page turn continues after catalog and body complete')
    f.session:close()
end

do
    local f = fixture({ prefetch = 0 }); f.open(); f.page_update(9, 12); f.scheduler:runAll()
    eq(0, #f.requests, 'disabled prefetch respects page events')
    f.next(); eq(1, #f.requests, 'disabled prefetch still permits explicit chapter navigation')
    f.session:close()
    local last = fixture(); last.open({ chapters[1] }); last.page_update(9, 12); last.scheduler:runAll(); last.next()
    eq(0, #last.requests, 'final chapter never requests beyond catalog')
    eq(1, last.ended, 'complete final chapter forwards native completion')
    last.session:close()
end

for _, action in ipairs({ 'close', 'switch', 'offline' }) do
    local f = fixture(); f.open(); f.scheduler:runNext(); f.next()
    local previous = f.opened[1]
    if action == 'close' then f.session:close()
    elseif action == 'switch' then f.open()
    else
        f.catalog = { chapters = chapters, complete = true }
        f.session:openOffline(source, book, 1)
    end
    local opened = #f.opened
    f.finish(1, '<p>Late old content</p>')
    if previous.callbacks.page_update then previous.callbacks.page_update(previous.document, 11, 12) end
    eq(nil, f.bodies.c2, action .. ' discards late previous content')
    eq(opened, #f.opened, action .. ' discards late automatic chapter opening')
    eq(1, f.requests[1].cancelled, action .. ' cancels its old live request once')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.page_update(9, 12); f.next(); f.html_error = true
    f.finish(1, '<p>Complete body</p>')
    eq(1, #f.opened, 'HTML write failure leaves the current reader open')
    eq(false, f.session.active.end_handled, 'HTML write failure allows an explicit retry')
    eq('<p>Complete body</p>', f.bodies.c2, 'failed HTML preparation preserves the completed body')
    f.html_error = false; f.next()
    eq(2, f.session.active.index, 'retry rebuilds HTML from the existing completed body')
    local next_requests = 0
    for _, request in ipairs(f.requests) do if request.chapter.uid == 'c2' then next_requests = next_requests + 1 end end
    eq(1, next_requests, 'retry after an HTML write failure does not fetch the same body again')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.page_update(9, 12); f.finish(1, '<p>Cached</p>')
    f.bodies.c2 = '<p>Updated by a new download</p>'
    f.next()
    eq(true, f.html.c2:find('Updated by a new download', 1, true) ~= nil, 'changed body invalidates previously prepared HTML')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.page_update(9, 12); f.finish(1, '<p>Cached</p>')
    f.html.c2, f.html_error = nil, true
    f.next()
    local next_requests = 0
    for _, request in ipairs(f.requests) do if request.chapter.uid == 'c2' then next_requests = next_requests + 1 end end
    eq(1, next_requests, 'failed regeneration of cached HTML does not redownload the completed chapter')
    eq(false, f.session.active.end_handled, 'HTML-only failure releases the chapter-end guard')
    f.session:close()
end

do
    local f = fixture(); f.open({ chapters[1] }, 1, { catalog_complete = false }); f.page_update(9, 12)
    local delivered = false
    local subscription = f.session:loadCatalog(f.session.active, function() delivered = true end)
    subscription:cancel()
    eq(0, f.catalog_requests[1].cancelled, 'closing a joined TOC does not cancel the reader catalog request')
    f.session:close(); f.catalog_requests[1].callback(chapters, nil, { catalog_complete = true })
    eq(false, delivered, 'closed TOC subscriber never receives the catalog result')
    eq(nil, f.catalog, 'closed reader rejects the late catalog before writing it')
    eq(0, #f.requests, 'closed reader cannot start content from a late catalog')
end

do
    local f = fixture(); f.open({ chapters[1] }, 1, { catalog_complete = false }); f.page_update(9, 12); f.next()
    f.catalog_requests[1].callback({ chapters[1] }, nil, { catalog_complete = false })
    eq(1, #f.catalog_requests, 'a catalog that does not grow cannot recursively re-request itself')
    eq(false, f.session.active.end_handled, 'incomplete unchanged catalog leaves chapter-end retry available')
    eq(0, f.ended, 'incomplete unchanged catalog does not claim the book is finished')
    f.next(); eq(2, #f.catalog_requests, 'explicit next-page retry can fetch the catalog again')
    f.session:close()
end

do
    local f = fixture(); f.open(); f.page_update(9, 12); f.next(); f.delay_ready = true
    f.finish(1, '<p>Next</p>')
    eq(2, #f.requests, 'foreground completion adds no requests while waiting for native reader readiness')
    local pending = f.opened[#f.opened]
    pending.callbacks.ready(pending.document); f.scheduler:runNext()
    eq('c3', f.requests[2].chapter.uid, 'new reader readiness starts its own next chapter')
    f.session:close()
end

for _, failure in ipairs({ 'throw', 'no_handle' }) do
    local f = fixture()
    f.service.getChapters = function()
        if failure == 'throw' then error('network initialization failed') end
        return nil, { code = 'NETWORK_ERROR', message = 'no request' }
    end
    f.open({ chapters[1] }, 1, { catalog_complete = false })
    local ok = pcall(f.page_update, 9, 12)
    eq(true, ok, failure .. ' catalog startup failure cannot crash a page update')
    eq(true, #f.diagnostics >= 1, failure .. ' catalog startup failure is recorded')
    eq(nil, f.session.catalog_waiters, failure .. ' catalog startup failure releases pending subscribers')
    f.session:close()
end

-- Real BookService/rules assemble all content pages before publishing the cache.
do
    local Models = require('legado.lib.models')
    local Safe = require('legado.lib.safe_functions')
    local rules = require('legado.lib.rule_engine').new { json_decoder = require('legado.lib.json_codec'),
        html_parser = require('legado.vendor.htmlparser'), safe_functions = Safe.functions, url_resolver = Safe.resolve_url }
    local source = { id = 's', bookSourceUrl = 'https://s/', ruleContent = { content = '$.content', nextContentUrl = '$.next' } }
    local book = { id = 'b', source_id = Models.sourceId(source) }
    local list = {}
    for i = 1, 2 do list[i] = { uid = 'c' .. i, index = i, title = 'Chapter ' .. i, url = 'https://s/' .. i, book_id = 'b', source_id = book.source_id } end
    local requests = {}
    local f = fixture()
    f.session.service = require('legado.lib.book_service').new { storage = {}, rule_engine = rules,
        url_template = require('legado.lib.url_template').new { rule_engine = rules },
        request_engine = { execute = function(_, request, callback)
            local entry = { url = request.url, callback = callback, cancelled = false }
            requests[#requests + 1] = entry
            return { cancel = function() entry.cancelled = true end }
        end } }
    f.bodies.c1 = nil
    f.session:open(source, book, list, 1)
    eq('https://s/1', requests[1].url, 'first uncached chapter uses the actual content pipeline')
    requests[1].callback { body = '{"content":"Current chapter"}', final_url = 'https://s/1' }
    eq(1, #f.opened, 'BookService trace metadata cannot skip caching the first downloaded chapter')
    f.page_update(9, 12)
    eq('https://s/2', requests[2].url, 'three-page notification starts the actual content pipeline')
    requests[2].callback { body = '{"content":"First web page","next":"2_2"}', final_url = 'https://s/2' }
    eq('https://s/2_2', requests[3].url, 'next content page is followed before completion')
    eq(nil, f.bodies.c2, 'partial chapter is not exposed as a complete cache entry')
    f.next(); eq(3, #requests, 'chapter-end wait does not restart the first web page')
    eq(false, requests[3].cancelled, 'second content page remains active at chapter end')
    requests[3].callback { body = '{"content":"Second web page"}', final_url = 'https://s/2_2' }
    eq(2, f.session.active.index, 'next reader opens only after the final content page')
    eq(true, f.html.c2:find('First web page', 1, true) ~= nil, 'prepared HTML includes the first web page')
    eq(true, f.html.c2:find('Second web page', 1, true) ~= nil, 'prepared HTML includes the final web page')
    f.session:close()
end

-- The adapter reads page/total only after native handlers have updated them.
do
    package.loaded['legado.lib.reader_chrome'] = { new = function() end }
    table.pack = table.pack or function(...) return { n = select('#', ...), ... } end
    local Event = dofile((os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader') .. '/frontend/ui/event.lua')
    local Adapter = require('legado.lib.koreader_reader_ui')
    local page, total, observed = 1, 12, {}
    local reader = {
        document = { getPageCount = function() return total end, getCurrentPage = function() return page end },
        handleEvent = function(_, event)
            if event.handler == 'onPageUpdate' then page = event.args[1]
            elseif event.handler == 'onPosUpdate' then page = event.args[2]
            elseif event.handler == 'onDocumentRerendered' then total, page = 20, 17 end
            return event.handler
        end,
    }
    local adapter = Adapter.new { ReaderUI = { showReader = function(_, _, _, _, _, ready) ready(reader) end } }
    local document = assert(adapter:openDocument('chapter.html', { page_update = function(doc, p, pages)
        observed[#observed + 1] = { doc = doc, page = p, total = pages }
    end }))
    eq('onPageUpdate', reader:handleEvent(Event:new('PageUpdate', 9)), 'page notification preserves native event result')
    eq(1, #observed, 'native page updates notify the reading session')
    eq(9, observed[1].page, 'page notification uses the updated native page')
    eq(12, observed[1].total, 'page notification uses actual document total')
    eq(document, observed[1].doc, 'page notification identifies the owning document')
    reader:handleEvent(Event:new('PosUpdate', 1000, 10))
    eq(10, observed[2].page, 'scroll-position update reports the new native page')
    reader:handleEvent(Event:new('DocumentRerendered'))
    eq(17, observed[3].page, 'font reflow notification reads the newly rendered page')
    eq(20, observed[3].total, 'font reflow notification reads the new page count')
    reader:onClose(); reader:handleEvent(Event:new('PageUpdate', 18))
    eq(3, #observed, 'closed native reader cannot publish stale page updates')
end
return count
