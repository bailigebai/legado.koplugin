local Json = require("legado.lib.json_codec")
local Importer = require("legado.lib.source_importer")
local Rules = require("legado.lib.rule_engine")
local Safe = require("legado.lib.safe_functions")
local Scanner = require("legado.lib.compatibility_scanner")
local Requests = require("legado.lib.request_engine")
local Service = require("legado.lib.book_service")
local Diagnostics = require("legado.lib.diagnostics")

local Probe = {}

function Probe.new(text, fetch, convert, clock, timeout, reader_root, ensure_reader_paths, catalog_pages, catalog_chapters)
    local sources = {}
    local storage = {
        listSources = function() return sources end,
        replaceSources = function(_, values) sources = values; return true end,
        getSource = function(_, id)
            for _, source in ipairs(sources) do if source.id == id then return source end end
        end,
    }
    local imported = Importer:new({ storage = storage }):importJson(text)
    assert(not imported.error and imported.rejected == 0, "source collection cannot be imported")
    local engine = Requests.new({ scheduler = { scheduleIn = function() end },
        transport = { request = function(_, request, sink) return fetch(request, sink) end },
        charset_converter = function(...) return convert(...) end,
        now = function() return clock() end, logger = {}, settings = { timeout = timeout },
    })
    -- Desktop probe uses the production HTTP policy synchronously; Kindle workers are tested separately.
    local requests = { execute = function(_, request, callback)
        local normalized, err = engine:_normalize(request)
        if not normalized then callback(nil, err)
        else
            for name in pairs(normalized.headers) do
                local lower = name:lower()
                if lower:find("cookie", 1, true) or lower:find("authorization", 1, true)
                    or lower:find("token", 1, true) or lower:find("api-key", 1, true) then
                    normalized.headers[name] = nil
                end
            end
            local outcome = engine:_run_work(normalized, clock() + normalized.timeout)
            callback(outcome.response, outcome.error or (outcome.panic and { code = "PROBE_ERROR" }))
        end
        return { cancel = function() return false end }
    end }
    local rules = Rules.new({ json_decoder = Json, html_parser = require("legado.vendor.htmlparser"),
        safe_functions = Safe.functions, url_resolver = Safe.resolve_url })
    local rule_fields, rule_errors = {}, {}
    local function reset_rule_errors(source)
        rule_fields, rule_errors = {}, {}
        for _, field in ipairs({"ruleExplore", "ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent"}) do
            for key, rule in pairs(type(source[field]) == "table" and source[field] or {}) do
                if type(rule) == "string" and tostring(key):match("^[%w_]+$") then rule_fields[rule] = field .. "." .. key end
            end
        end
    end
    for _, method in ipairs({ "parse", "parseElements" }) do
        local implementation = rules[method]
        rules[method] = function(self, input, rule, ...)
            local result, err = implementation(self, input, rule, ...)
            if err then rule_errors[#rule_errors + 1] = { field = rule_fields[rule] or "unknown", code = err.code,
                limit = type(err.details) == "table" and err.details.limit or nil } end
            return result, err
        end
    end
    local service = Service.new({ storage = storage, rule_engine = rules, request_engine = requests,
        url_template = require("legado.lib.url_template").new({ rule_engine = rules }) })
    local diagnostics = Diagnostics.new({ book_service = service, now = function() return clock() end })
    local reader_cache
    if reader_root then
        reader_cache = require("legado.lib.cache_store").new({ root = reader_root })
    end
    local function check_reader_document(source, book, chapter, body)
        if ensure_reader_paths then ensure_reader_paths(book.source_id, book.id) end
        local stored, store_error = reader_cache:writeBody(book.source_id, book.id, chapter, body)
        if not stored then
            return { status = "failed", code = store_error.code,
                stage = store_error.details and store_error.details.stage or "body_write" }
        end
        local bytes, path
        local session = require("legado.lib.reader_session").new({
            cache = reader_cache,
            storage = { putProgress = function() return true end },
            settings = { get = function() return 0 end },
            ui = { openDocument = function(_, candidate, callbacks)
                path = candidate
                local file = io.open(candidate, "rb")
                if not file then return nil, { code = "STORAGE_ERROR", details = { stage = "reader_open" } } end
                bytes = file:read("*a")
                file:close()
                local document = { getProgressFraction = function() return 0 end }
                callbacks.ready(document)
                return document
            end },
        })
        local opened, open_error = session:open(source, book, { chapter }, 1)
        if not opened then
            return { status = "failed", code = open_error.code,
                stage = open_error.details and open_error.details.stage }
        end
        local valid = type(bytes) == "string" and bytes:sub(1, 15):lower() == "<!doctype html>"
            and bytes:sub(-14):lower() == "</body></html>" and path:sub(-5):lower() == ".html"
        return { status = valid and "passed" or "failed", format = valid and "html" or "invalid",
            bytes = type(bytes) == "string" and #bytes or 0, reader_entry = opened ~= nil }
    end
    local sample
    local get_chapters, get_content = service.getChapters, service.getContent
    function service:getChapters(source, book, callback)
        return get_chapters(self, source, book, function(chapters, err, metadata)
            if chapters and #chapters > 0 then
                local seen, duplicates = {}, 0
                for _, chapter in ipairs(chapters) do
                    if seen[chapter.url] then duplicates = duplicates + 1 end
                    seen[chapter.url] = true
                end
                sample.catalog_duplicate_urls = duplicates
                sample.catalog_complete = metadata and metadata.catalog_complete
                sample.first_chapter_title = chapters[1].title
                sample.last_chapter_title = chapters[#chapters].title
                sample.first_chapter_number = tonumber(chapters[1].title:match("%d+"))
                sample.last_chapter_number = tonumber(chapters[#chapters].title:match("%d+"))
            end
            callback(chapters, err, metadata)
        end, { max_pages=catalog_pages, max_chapters=catalog_chapters })
    end
    function service:getContent(source, book, chapter, callback)
        return get_content(self, source, book, chapter, function(content, err, metadata)
            if content then
                sample.content_bytes = #content.content
                if reader_cache then sample.reader_document = check_reader_document(source, book, chapter, content.content) end
            end
            callback(content, err, metadata)
        end)
    end
    local search_errors
    local search = service.search
    function service:search(keyword, ids, page, callback)
        return search(self, keyword, ids, page, function(result, err, metadata)
            search_errors = result and result.errors
            callback(result, err, metadata)
        end)
    end
    return {
        inventory = function()
            local rows = {}
            for index, source in ipairs(sources) do
                local report = Scanner.scan(source)
                local issues = {}
                for _, issue in ipairs(report.issues) do issues[#issues + 1] = { field = issue.field, code = issue.code } end
                rows[index] = { index = index, name = source.bookSourceName,
                    url = source.bookSourceUrl, status = report.status,
                    capabilities = report.capabilities, issues = issues, enabled = source.enabled }
            end
            return Json.encode(rows)
        end,
        explore = function(index)
            local source = assert(sources[index])
            reset_rule_errors(source)
            local report = { status = "completed", steps = {}, rule_errors = rule_errors }
            local function step(name, err, counts)
                report.steps[#report.steps+1] = { name=name, status=err and "failed" or "passed",
                    error=err and {code=err.code} or nil, field_counts=counts }
                if err then report.status="failed" end
            end
            local categories, err = service:exploreCategories(source)
            step("categories",err,{results=#(categories or {})})
            if err then return Json.encode(report) end
            local selected
            for i, category in ipairs(categories or {}) do
                if category.url and not category.error then selected=i; break end
            end
            if not selected then report.status="no_categories"; return Json.encode(report) end
            report.category=categories[selected].title
            service:explore(source.id,selected,1,function(result, failure)
                local groups=result and result.groups or {}
                local covers,intros=0,0
                for _,group in ipairs(groups) do
                    if group.book.cover_url~="" then covers=covers+1 end
                    if group.book.intro~="" then intros=intros+1 end
                end
                step("category_books",failure,{results=#groups})
                report.card_covers,report.card_intros=covers,intros
                if failure or #groups==0 then if not failure then report.status="empty" end; return end
                service:getBookInfo(source,groups[1].book,function(book, info_error)
                    step("detail",info_error)
                    if not book then return end
                    report.detail_intro_bytes=#book.intro
                    report.detail_has_cover=book.cover_url~=""
                    if book.cover_url=="" then return end
                    requests:execute({url=book.cover_url,source_id=book.source_id,max_bytes=2*1024*1024},function(response, cover_error)
                        step("cover",cover_error)
                        if response then
                            local body=response.body or ""
                            report.cover_bytes=#body
                            report.cover_image_signature=body:sub(1,3)=="\255\216\255" or body:sub(1,8)=="\137PNG\r\n\26\n" or body:sub(1,3)=="GIF" or body:sub(9,12)=="WEBP"
                            if not report.cover_image_signature then report.status="failed" end
                        end
                    end)
                end)
            end)
            return Json.encode(report)
        end,
        run = function(index, keyword)
            local report
            search_errors = nil
            sample = {}
            local source = assert(sources[index])
            reset_rule_errors(source)
            diagnostics:run(source, keyword, function(value) report = value end)
            if report then report.search_errors, report.rule_errors, report.sample = search_errors, rule_errors, sample end
            return Json.encode(assert(report, "synchronous probe did not complete"))
        end,
    }
end

return Probe
