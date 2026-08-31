local Errors = require("legado.lib.errors")
local Scanner = require("legado.lib.compatibility_scanner")

local Diagnostics = {}
Diagnostics.__index = Diagnostics

local step_names = { "search", "result", "catalog", "content" }

local function safe_number(value)
    local ok, number = pcall(tonumber, value)
    if not ok or not number or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function safe_field(value, key)
    if type(value) ~= "table" then return nil end
    local ok, result = pcall(rawget, value, key)
    return ok and result or nil
end

local function safe_code(error_value, fallback)
    local code = safe_field(error_value, "code")
    if type(code) ~= "string" then return fallback end
    code = code:match("^([A-Z][A-Z0-9_]*)$")
    return code or fallback
end

local function error_status(error_value)
    local details = safe_field(error_value, "details")
    return safe_number(safe_field(details, "status"))
end

local function metadata_status(metadata)
    return safe_number(safe_field(metadata, "http_status") or safe_field(metadata, "status"))
end

local function metadata_charset(metadata)
    local charset = safe_field(metadata, "charset")
    if type(charset) ~= "string" then return nil end
    charset = charset:lower():match("^([%w._%-]+)$")
    if not charset or #charset > 40 then return nil end
    return charset
end

local function now_ms(clock)
    local value = safe_number(clock()) or 0
    return value * 1000
end

local function elapsed(clock, started)
    return math.max(0, math.floor(now_ms(clock) - started + 0.5))
end

local function skipped_steps()
    local steps = {}
    for index, name in ipairs(step_names) do
        steps[index] = { name = name, status = "pending", duration_ms = 0, field_counts = {} }
    end
    return steps
end

local function count_fields(value, names)
    local count = 0
    for _, name in ipairs(names) do
        local field = safe_field(value, name)
        if field ~= nil and field ~= "" then count = count + 1 end
    end
    return count
end

function Diagnostics.new(options)
    options = options or {}
    assert(options.book_service, "Diagnostics requires book_service")
    return setmetatable({
        service = options.book_service,
        scanner = options.scanner or Scanner,
        now = options.now or os.clock,
    }, Diagnostics)
end

function Diagnostics:run(source, keyword, callback)
    assert(type(callback) == "function", "Diagnostics callback must be a function")
    local report = {
        status = "running",
        compatibility = self.scanner and self.scanner.scan and self.scanner.scan(source) or nil,
        steps = skipped_steps(),
    }
    local state = { completed = false, cancelled = false, active = nil, step = 0 }
    local clock = self.now

    local function complete(status)
        if state.completed then return end
        state.completed = true
        report.status = status
        callback(report)
    end

    local function skip_after(index)
        for next_index = index + 1, #report.steps do
            if report.steps[next_index].status == "pending" then report.steps[next_index].status = "skipped" end
        end
    end

    local function begin(index)
        state.step = index
        local step = report.steps[index]
        step.status = "running"
        step._started = now_ms(clock)
        return step
    end

    local function finish_step(step, metadata)
        step.duration_ms = elapsed(clock, step._started)
        step._started = nil
        step.http_status = metadata_status(metadata)
        step.charset = metadata_charset(metadata)
    end

    local function fail(index, error_value, metadata, fallback_code)
        if state.completed or state.cancelled then return end
        local step = report.steps[index]
        finish_step(step, metadata)
        step.http_status = step.http_status or error_status(error_value)
        step.status = "failed"
        step.error = {
            code = safe_code(error_value, fallback_code or Errors.NETWORK_ERROR),
            message = "诊断步骤失败",
        }
        skip_after(index)
        complete("failed")
    end

    local function attach(index, factory, fallback_code)
        local ok, child = pcall(factory)
        if not ok then
            fail(index, nil, nil, fallback_code)
            return
        end
        if not state.completed and not state.cancelled and state.step == index then state.active = child end
    end

    local run_content, run_catalog
    run_content = function(book, chapter)
        local step = begin(4)
        attach(4, function()
            return self.service:getContent(source, book, chapter, function(result, err, metadata)
                if state.completed or state.cancelled then return end
                if err or type(result) ~= "table" then fail(4, err, metadata, "CONTENT_FAILED"); return end
                finish_step(step, metadata)
                step.status = "success"
                step.field_counts.pages = math.max(0, math.floor(safe_number(safe_field(result, "pages")) or 0))
                complete("completed")
            end)
        end, "CONTENT_FAILED")
    end

    run_catalog = function(book)
        local step = begin(3)
        attach(3, function()
            return self.service:getChapters(source, book, function(chapters, err, metadata)
                if state.completed or state.cancelled then return end
                if err or type(chapters) ~= "table" then fail(3, err, metadata, "CATALOG_FAILED"); return end
                local first_chapter = safe_field(chapters, 1)
                if #chapters == 0 or type(first_chapter) ~= "table" then
                    fail(3, Errors.new("NO_CHAPTER", "catalog returned no chapter"), metadata, "NO_CHAPTER")
                    return
                end
                finish_step(step, metadata)
                step.field_counts.chapters = #chapters
                step.status = "success"
                run_content(book, first_chapter)
            end)
        end, "CATALOG_FAILED")
    end

    local search_step = begin(1)
    attach(1, function()
        return self.service:search(keyword, { safe_field(source, "id") or safe_field(source, "bookSourceUrl") }, 1,
            function(result, err, metadata)
                if state.completed or state.cancelled then return end
                if err or type(result) ~= "table" then fail(1, err, metadata, "SEARCH_FAILED"); return end
                local groups = safe_field(result, "groups")
                if type(groups) ~= "table" then fail(1, nil, metadata, "SEARCH_FAILED"); return end
                finish_step(search_step, metadata)
                search_step.status = "success"
                search_step.field_counts.results = #groups

                local result_step = begin(2)
                local first = safe_field(groups, 1)
                local selected = type(first) == "table" and safe_field(first, "book") or nil
                finish_step(result_step, nil)
                if type(selected) ~= "table" then
                    result_step.status = "failed"
                    result_step.error = { code = "NO_SEARCH_RESULT", message = "诊断步骤失败" }
                    skip_after(2)
                    complete("failed")
                    return
                end
                result_step.status = "success"
                result_step.field_counts.fields = count_fields(selected, { "name", "author", "url", "cover_url", "intro", "kind", "last_chapter" })
                run_catalog(selected)
            end)
    end, "SEARCH_FAILED")

    local handle = {}
    function handle:cancel()
        if state.completed or state.cancelled then return false end
        state.cancelled = true
        if state.active and type(state.active.cancel) == "function" then pcall(state.active.cancel, state.active) end
        local step = report.steps[state.step]
        if step and step.status == "running" then
            step.duration_ms = elapsed(clock, step._started)
            step._started = nil
            step.status = "cancelled"
        end
        skip_after(state.step)
        complete("cancelled")
        return true
    end
    return handle
end

return Diagnostics
