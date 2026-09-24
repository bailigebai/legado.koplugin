local assertx = require("assertions")
local Fakes = require("support.network_fakes")
local RequestEngine = require("legado.lib.request_engine")
local silent_logger = { debug = function() end, warn = function() end }

local assertions = 0
local function equal(expected, actual, message)
    assertions = assertions + 1
    assertx.equal(expected, actual, message)
end
local function truthy(value, message)
    assertions = assertions + 1
    assertx.truthy(value, message)
end

local function run_fallback(script, request, options)
    options = options or {}
    local scheduler = options.scheduler or Fakes.scheduler()
    local transport = Fakes.transport(script)
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = transport,
        scheduler = scheduler,
        subprocess = Fakes.subprocess({ enabled = false }),
        charset_converter = options.charset_converter,
        cookie_store = options.cookie_store,
        logger = options.logger or silent_logger,
        settings = options.settings,
        concurrency = options.concurrency,
    })
    local handle = engine:execute(request, function(response, err)
        callbacks[#callbacks + 1] = { response = response, err = err }
    end)
    return engine, scheduler, transport, callbacks, handle
end

do
    local engine, scheduler, transport, callbacks, handle = run_fallback({
        { status = 200, headers = { ["Content-Type"] = "text/plain; charset=utf-8" }, chunks = { "hello" } },
    }, { url = "https://books.test/search?q=safe" })
    equal("table", type(handle), "execute returns a cancellation handle")
    equal("function", type(handle.cancel), "cancellation handle exposes cancel")
    equal(0, #callbacks, "synchronous fallback still defers completion")
    scheduler:runAll()
    equal(1, #callbacks, "completion callback fires once")
    equal(nil, callbacks[1].err, "successful request has no error")
    equal(200, callbacks[1].response.status, "response status")
    equal("hello", callbacks[1].response.body, "response body")
    equal("https://books.test/search?q=safe", callbacks[1].response.final_url, "response final URL")
    equal("utf-8", callbacks[1].response.charset, "response charset")
    equal(20, transport.requests[1].timeout, "default timeout")
    equal(4 * 1024 * 1024, transport.requests[1].max_bytes, "default byte limit")
    equal(2, engine:getConcurrencyLimit(), "default concurrency contract")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 302, headers = { location = "https://cdn.test/final" }, chunks = {} },
        { status = 200, chunks = { "final" } },
    }, {
        url = "https://books.test/start",
        headers = {
            Authorization = "one", authorization = "two",
            ["Proxy-Authorization"] = "three", ["proxy-authorization"] = "four",
            Cookie = "a=1", cookie = "b=2",
        },
    })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "duplicate sensitive headers redirect safely")
    for name in pairs(transport.requests[2].headers) do
        local lower = tostring(name):lower()
        truthy(lower ~= "authorization" and lower ~= "proxy-authorization" and lower ~= "cookie",
            "cross-origin redirect strips every sensitive header casing")
    end
end

do
    local engine, scheduler, transport, callbacks = run_fallback({
        { status = 200, chunks = { "json" } },
        { status = 200, chunks = { "form" } },
    }, {
        url = "https://books.test/json", method = "POST", body_type = "json",
        body = { q = "A b", page = 2 }, headers = { ["X-Custom"] = "yes" },
        timeout = 999, max_bytes = 99999999, max_redirects = 99,
    }, { concurrency = 99 })
    scheduler:runAll()
    equal(1, #callbacks, "JSON request completes")
    equal("application/json; charset=utf-8", transport.requests[1].headers["Content-Type"], "JSON content type")
    truthy(transport.requests[1].body:find('"q":"A b"', 1, true), "JSON body encoded")
    equal("yes", transport.requests[1].headers["X-Custom"], "custom header retained")
    equal(20, transport.requests[1].timeout, "timeout hard limit")
    equal(16 * 1024 * 1024, transport.requests[1].max_bytes, "byte hard limit matches source import")
    equal(5, transport.requests[1].max_redirects, "redirect hard limit")
    equal(3, engine:getConcurrencyLimit(), "concurrency contract clamps at three")

    local second_callbacks = {}
    engine:execute({
        url = "https://books.test/form", method = "POST", body_type = "form",
        body = { q = "A b", tag = "x/y" },
    }, function(response, err) second_callbacks[#second_callbacks + 1] = { response, err } end)
    scheduler:runAll()
    equal(1, #second_callbacks, "form request completes")
    equal("application/x-www-form-urlencoded", transport.requests[2].headers["Content-Type"], "form content type")
    equal("q=A%20b&tag=x%2Fy", transport.requests[2].body, "form body encoded deterministically")
end

do
    local _, scheduler, _, callbacks = run_fallback({
        { status = 200, headers = { ["X-Huge"] = string.rep("h", 40) }, chunks = {} },
    }, { url = "https://books.test/header-limit", max_bytes = 24 })
    scheduler:runAll()
    equal("RESPONSE_TOO_LARGE", callbacks[1].err.code, "headers count toward response bound")
    equal("response_metadata", callbacks[1].err.details.reason, "header overflow diagnostic")
end

do
    local deadline_scheduler = Fakes.scheduler()
    local _, scheduler, transport, callbacks = run_fallback({
        function(request)
            deadline_scheduler:advance(0.06)
            return { status = 302, headers = { location = "/second" }, chunks = {} }
        end,
        function(request)
            deadline_scheduler:advance(0.06)
            return { status = 200, chunks = { "late" } }
        end,
    }, { url = "https://books.test/first", timeout = 0.1 }, { scheduler = deadline_scheduler })
    scheduler:runAll()
    equal(1, #callbacks, "redirect deadline callback once")
    equal("TIMEOUT", callbacks[1].err.code, "one absolute deadline spans redirects")
    truthy(transport.requests[2].timeout < transport.requests[1].timeout,
        "each redirect receives only remaining timeout")
end

do
    local engine, scheduler, transport, callbacks = run_fallback({
        { status = 302, headers = { Location = "/next", ["Set-Cookie"] = "sid=alpha; Path=/; Secure" }, chunks = {} },
        { status = 200, headers = {}, chunks = { "done" } },
        { status = 200, headers = {}, chunks = { "isolated" } },
    }, { url = "https://books.test/start", source_id = "source-a" })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "redirect succeeds")
    equal("done", callbacks[1].response.body, "redirect response body")
    equal("https://books.test/next", callbacks[1].response.final_url, "relative redirect resolved")
    equal("https://books.test/next", transport.requests[2].url, "redirect target requested")
    equal("sid=alpha", transport.requests[2].headers.Cookie, "redirect receives source cookie")

    local isolated = {}
    engine:execute({ url = "https://books.test/other", source_id = "source-b" }, function(response, err)
        isolated[#isolated + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(nil, transport.requests[3].headers.Cookie, "cookie does not cross source boundary")
end

do
    local _, scheduler, transport, callbacks = run_fallback({}, {
        url = "https://books.test/form", method = "POST", body_type = "form", body = { [1] = "lost" },
    })
    scheduler:runAll()
    equal("INVALID_INPUT", callbacks[1].err.code, "form rejects non-string keys")
    equal(0, #transport.requests, "invalid form never reaches transport")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 301, headers = { location = "/loop" }, chunks = {} },
        { status = 301, headers = { location = "/loop" }, chunks = {} },
    }, { url = "https://books.test/loop", max_redirects = 5 })
    scheduler:runAll()
    equal(1, #callbacks, "redirect loop completes once")
    equal(nil, callbacks[1].response, "redirect loop has no response")
    equal("NETWORK_ERROR", callbacks[1].err.code, "redirect loop error code")
    equal("redirect_loop", callbacks[1].err.details.reason, "redirect loop diagnostic")
    equal(1, #transport.requests, "known redirect loop stops before duplicate request")
end

do
    local engine, scheduler, transport, callbacks = run_fallback({
        {
            status = 200,
            headers = { ["Set-Cookie"] = "a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/, b=2; Path=/" },
            chunks = { "first" },
        },
        { status = 200, chunks = { "second" } },
        { status = 200, chunks = { "isolated" } },
    }, { url = "https://books.test/first", source_id = "source-a" })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "combined Set-Cookie response succeeds")
    engine:execute({ url = "https://books.test/second", source_id = "source-a" }, function() end)
    scheduler:runAll()
    truthy(transport.requests[2].headers.Cookie:find("a=1", 1, true), "Expires comma remains in first cookie")
    truthy(transport.requests[2].headers.Cookie:find("b=2", 1, true), "combined second cookie is stored")
    engine:execute({ url = "https://books.test/third", source_id = "source-b" }, function() end)
    scheduler:runAll()
    equal(nil, transport.requests[3].headers.Cookie, "combined cookies remain source isolated")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 302, headers = { location = "/next" }, chunks = {} },
    }, { url = "https://books.test/no-redirect", max_redirects = 0 })
    scheduler:runAll()
    equal("NETWORK_ERROR", callbacks[1].err.code, "zero redirect budget is honored")
    equal("max_redirects", callbacks[1].err.details.reason, "zero redirect diagnostic")
    equal(1, #transport.requests, "zero redirect budget stops at first response")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ never_reap = true, polls_before_done = 1000 })
    local callbacks = {}
    local callback_at
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "late" } } }),
        scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/unreapable", timeout = 0.1 }, function(response, err)
        callback_at = scheduler:now()
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll(200)
    equal(1, #callbacks, "unreapable timeout callback once")
    equal(0.1, callback_at, "timeout callback fires exactly at deadline")
    equal("TIMEOUT", callbacks[1][2].code, "unreapable child reports timeout")
    equal(1, subprocess.terminated, "unreapable child terminated once")
    equal(1, subprocess.closed, "unreapable child pipe eventually closes")
    equal(0, #scheduler.queue, "bounded cleanup becomes idle")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ reaps_before_done = 2, polls_before_done = 1000 })
    local callbacks, callback_at = {}, nil
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "late" } } }),
        scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/delayed-reap", timeout = 0.1 }, function(response, err)
        callback_at = scheduler:now()
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(0.1, callback_at, "delayed reap cannot delay timeout callback")
    equal(1, #callbacks, "delayed reap callback once")
    equal(1, subprocess.reaped, "delayed child eventually reaped")
    equal(1, subprocess.closed, "delayed child pipe closes once")
    truthy(subprocess.reap_polls >= 3, "cleanup retries reap with backoff")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 303, headers = { location = "https://cdn.test/final" }, chunks = {} },
        { status = 200, chunks = { "final" } },
    }, {
        url = "https://books.test/post", method = "POST", body = "secret payload",
        headers = { Authorization = "Bearer secret", Cookie = "manual=secret", ["Content-Type"] = "text/plain" },
    })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "cross-origin 303 succeeds")
    equal("GET", transport.requests[2].method, "303 switches POST to GET")
    equal(nil, transport.requests[2].body, "303 never forwards request body")
    equal(nil, transport.requests[2].headers.Authorization, "cross-origin redirect strips authorization")
    equal(nil, transport.requests[2].headers.Cookie, "cross-origin redirect strips caller cookies")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 200, chunks = { "1234", "5678", "ignored" } },
    }, { url = "https://books.test/large", max_bytes = 6 })
    scheduler:runAll()
    equal(1, #callbacks, "oversize completes once")
    equal("RESPONSE_TOO_LARGE", callbacks[1].err.code, "oversize error code")
    equal(6, callbacks[1].err.details.max_bytes, "oversize diagnostic limit")
    equal(nil, callbacks[1].err.details.body, "oversize diagnostic excludes body")
    equal(1, transport.aborted, "transport is stopped at the first oversize chunk")
end

do
    local _, scheduler, _, callbacks = run_fallback({
        { status = 200, headers = { ["Content-Type"] = "text/html; charset=gb18030" }, chunks = { "\214\208" } },
    }, { url = "https://books.test/gb" }, { charset_converter = false })
    scheduler:runAll()
    equal("ENCODING_ERROR", callbacks[1].err.code, "missing charset capability maps explicitly")
    equal("gb18030", callbacks[1].err.details.charset, "encoding diagnostic preserves charset")
end

local function mapped_error(response, request)
    local _, scheduler, _, callbacks = run_fallback({ response }, request or { url = "https://books.test/fail" })
    scheduler:runAll()
    return callbacks[1].err
end

do
    equal("TIMEOUT", mapped_error({ error = "timeout" }).code, "transport timeout mapping")
    equal("NETWORK_ERROR", mapped_error({ error = "host not found" }).code, "DNS error mapping")
    local forbidden = mapped_error({ status = 403, chunks = { "private full chapter" } })
    equal("SITE_REJECTED", forbidden.code, "403 mapping")
    equal(403, forbidden.details.status, "403 status preserved")
    equal(nil, forbidden.details.body, "rejection details exclude response body")
    equal("SITE_REJECTED", mapped_error({ status = 429, chunks = { "slow down" } }).code, "429 mapping")
    equal("SITE_REJECTED", mapped_error({ status = 200, chunks = { "<title>Just a moment...</title> Cloudflare" } }).code, "Cloudflare page mapping")
    equal("SITE_REJECTED", mapped_error({ status = 200, chunks = { "Please complete the CAPTCHA challenge" } }).code, "captcha page mapping")
    equal(nil, mapped_error({ status = 200, chunks = {
        '<html><title>Book details</title><h1>Book</h1><script src="https://turing.captcha.qcloud.com/TCaptcha.js"></script></html>',
    } }), "optional SF login CAPTCHA script does not block public book details")
    equal(nil, mapped_error({ status = 200, chunks = {
        '<html><title>Book details</title><script src="https://cdnjs.cloudflare.com/ajax/libs/example.js"></script></html>',
    } }), "ordinary CDN assets are not a challenge page")
end

do
    local _, scheduler, _, callbacks = run_fallback({
        function() error("unexpected transport panic") end,
    }, { url = "https://books.test/panic" })
    scheduler:runAll()
    equal(1, #callbacks, "fallback panic callback once")
    equal("NETWORK_ERROR", callbacks[1].err.code, "fallback panic maps safely")
    equal("worker_failure", callbacks[1].err.details.reason, "fallback panic diagnostic")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({ { status = 200, chunks = { "child" } } })
    local subprocess = Fakes.subprocess({ polls_before_done = 1 })
    local callbacks = {}
    local engine = RequestEngine.new({ transport = transport, scheduler = scheduler, subprocess = subprocess, logger = silent_logger })
    engine:execute({ url = "https://books.test/child" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    equal(0, #callbacks, "child completion is asynchronous")
    scheduler:runAll()
    equal(1, #callbacks, "child success callback once")
    equal("child", callbacks[1][1].body, "child payload decoded")
    equal(nil, callbacks[1][2], "child success no error")
    equal(1, subprocess.reaped, "successful child reaped")
    equal(1, subprocess.closed, "successful child pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({ { error = "TLS handshake failed" } })
    local subprocess = Fakes.subprocess()
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/child-failure" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(1, #callbacks, "child failure callback once")
    equal("NETWORK_ERROR", callbacks[1][2].code, "child transport failure crosses pipe contract")
    equal(1, subprocess.reaped, "failed child reaped")
    equal(1, subprocess.closed, "failed child pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({ function() error("child panic") end })
    local subprocess = Fakes.subprocess()
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/child-panic" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(1, #callbacks, "child panic callback once")
    equal("NETWORK_ERROR", callbacks[1][2].code, "child panic maps safely")
    equal("worker_failure", callbacks[1][2].details.reason, "child panic diagnostic")
    equal(1, subprocess.reaped, "panicked child reaped")
    equal(1, subprocess.closed, "panicked child pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({ { status = 200, chunks = { "fallback" } } })
    local subprocess = Fakes.subprocess({ start_error = "fork failed" })
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/fork-fallback" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    equal(0, #callbacks, "failed child start still defers fallback")
    scheduler:runAll()
    equal("fallback", callbacks[1][1].body, "failed child start uses synchronous fallback")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({
        { status = 200, headers = { ["Set-Cookie"] = "persist=yes; Path=/" }, chunks = { "first" } },
        { status = 200, chunks = { "second" } },
    })
    local cookie_store = { values = {}, in_child = false }
    function cookie_store:header(source_id)
        return self.values[source_id]
    end
    function cookie_store:store(source_id, _, value)
        if not self.in_child then self.values[source_id] = tostring(value):match("^([^;]+)") end
    end
    local subprocess = Fakes.subprocess({
        before_job = function() cookie_store.in_child = true end,
        after_job = function() cookie_store.in_child = false end,
    })
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler, subprocess = subprocess,
        cookie_store = cookie_store, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/first", source_id = "source-a" }, function() end)
    scheduler:runAll()
    engine:execute({ url = "https://books.test/second", source_id = "source-a" }, function() end)
    scheduler:runAll()
    equal("persist=yes", transport.requests[2].headers.Cookie, "child cookie updates return to the parent jar")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ malformed = "not-a-wire-payload" })
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "unused" } } }),
        scheduler = scheduler,
        subprocess = subprocess,
        logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/malformed" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(1, #callbacks, "malformed child callback once")
    equal("NETWORK_ERROR", callbacks[1][2].code, "malformed child payload maps safely")
    equal("malformed_child_payload", callbacks[1][2].details.reason, "malformed payload diagnostic")
    equal(1, subprocess.reaped, "malformed child reaped")
    equal(1, subprocess.closed, "malformed child pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ poll_error = "pipe read failed" })
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "unused" } } }),
        scheduler = scheduler, subprocess = subprocess, logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/pipe-error" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(1, #callbacks, "pipe failure callback once")
    equal("NETWORK_ERROR", callbacks[1][2].code, "pipe failure maps safely")
    equal(1, subprocess.terminated, "pipe failure terminates possibly-running child")
    equal(1, subprocess.reaped, "pipe failure child reaped")
    equal(1, subprocess.closed, "pipe failure pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ polls_before_done = 1000 })
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "late" } } }),
        scheduler = scheduler,
        subprocess = subprocess,
        logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/timeout", timeout = 0.1 }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(1, #callbacks, "child timeout callback once")
    equal("TIMEOUT", callbacks[1][2].code, "parent timeout mapping")
    equal(1, subprocess.terminated, "timed out child terminated")
    equal(1, subprocess.reaped, "timed out child reaped")
    equal(1, subprocess.closed, "timed out child pipe closed")
end

do
    local scheduler = Fakes.scheduler()
    local subprocess = Fakes.subprocess({ polls_before_done = 1000 })
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = Fakes.transport({ { status = 200, chunks = { "late" } } }),
        scheduler = scheduler,
        subprocess = subprocess,
        logger = silent_logger,
    })
    local handle = engine:execute({ url = "https://books.test/cancel" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    equal(true, handle:cancel(), "first cancellation changes state")
    equal(false, handle:cancel(), "cancellation is idempotent")
    scheduler:runAll()
    equal(0, #callbacks, "cancellation is intentionally silent")
    equal(1, subprocess.terminated, "cancelled child terminated")
    equal(1, subprocess.reaped, "cancelled child reaped")
    equal(1, subprocess.closed, "cancelled child pipe closed")
end

do
    local _, scheduler, transport, callbacks, handle = run_fallback({
        { status = 200, chunks = { "must not run" } },
    }, { url = "https://books.test/cancel-fallback" })
    equal(true, handle:cancel(), "fallback can be cancelled before its scheduled run")
    scheduler:runAll()
    equal(0, #callbacks, "cancelled fallback has silent callback policy")
    equal(0, #transport.requests, "cancelled fallback performs no network work")
end

do
    local scheduler = Fakes.scheduler()
    local transport = Fakes.transport({ { status = 200, chunks = { "unsafe" } } })
    transport.total_deadline_safe = false
    local callbacks = {}
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler,
        subprocess = Fakes.subprocess({ enabled = false }), logger = silent_logger,
    })
    engine:execute({ url = "https://books.test/unsafe-fallback" }, function(response, err)
        callbacks[#callbacks + 1] = { response, err }
    end)
    scheduler:runAll()
    equal("NETWORK_ERROR", callbacks[1][2].code, "unsafe synchronous fallback fails closed")
    equal("deadline_unavailable", callbacks[1][2].details.reason, "fail-closed diagnostic is explicit")
    equal(0, #transport.requests, "unsafe fallback performs no blocking socket work")
end

do
    local logs = {}
    local logger = {
        debug = function(_, value) logs[#logs + 1] = value end,
        warn = function(_, value) logs[#logs + 1] = value end,
    }
    local _, scheduler = run_fallback({ { status = 200, chunks = { "full chapter secret" } } }, {
        url = "https://books.test/search?q=visible-query&appKey=app-secret&X-Amz-Credential=aws-secret&sign=s1&signature=s2&jwt=j1&na%6De=encoded-secret",
        headers = { Authorization = "Bearer credential", Cookie = "sid=secret", ["X-App-Key"] = "header-secret", ["X-Display"] = "ordinary-secret" },
        body = "request body secret",
    }, { logger = logger })
    scheduler:runAll()
    local rendered = ""
    local function flatten(value)
        if type(value) == "table" then for key, child in pairs(value) do flatten(key); flatten(child) end
        else rendered = rendered .. " " .. tostring(value) end
    end
    flatten(logs)
    truthy(rendered:find("%[REDACTED%]"), "diagnostics include redaction markers")
    equal(nil, rendered:find("visible-query", 1, true), "even ordinary query values never reach logger")
    equal(nil, rendered:find("app-secret", 1, true), "appKey query value never reaches logger")
    equal(nil, rendered:find("aws-secret", 1, true), "AWS credential query value never reaches logger")
    equal(nil, rendered:find("s1", 1, true), "sign query value never reaches logger")
    equal(nil, rendered:find("s2", 1, true), "signature query value never reaches logger")
    equal(nil, rendered:find("j1", 1, true), "jwt query value never reaches logger")
    equal(nil, rendered:find("encoded-secret", 1, true), "encoded query name value never reaches logger")
    equal(nil, rendered:find("Bearer credential", 1, true), "authorization never reaches logger")
    equal(nil, rendered:find("sid=secret", 1, true), "cookies never reach logger")
    equal(nil, rendered:find("header-secret", 1, true), "X-App-Key value never reaches logger")
    equal(nil, rendered:find("ordinary-secret", 1, true), "arbitrary header values never reach logger")
    equal(nil, rendered:find("request body secret", 1, true), "request body never reaches logger")
    equal(nil, rendered:find("full chapter secret", 1, true), "response body never reaches logger")
end

do
    local _, scheduler, _, callbacks = run_fallback({}, { url = "file:///etc/passwd" })
    scheduler:runAll()
    equal("INVALID_INPUT", callbacks[1].err.code, "only HTTP and HTTPS are accepted")
end

do
    local deceptive_urls = {
        "https://victim.test:pw@attacker.test/path",
        "https://us%65r:p%40ss@books.test/path",
        "https://victim.test%40attacker.test/path",
    }
    for _, url in ipairs(deceptive_urls) do
        local _, scheduler, transport, callbacks = run_fallback({
            { status = 200, chunks = { "must not run" } },
        }, { url = url })
        scheduler:runAll()
        truthy(callbacks[1].err, "userinfo request returns a structured rejection")
        equal("INVALID_INPUT", callbacks[1].err.code, "HTTP userinfo and encoded authority delimiters are rejected")
        equal("url_userinfo", callbacks[1].err.details.reason, "userinfo rejection is diagnostic")
        equal(0, #transport.requests, "rejected userinfo performs no network request")
    end
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 302, headers = { location = "https://victim.test:pw@attacker.test/final" }, chunks = {} },
        { status = 200, chunks = { "must not follow" } },
    }, { url = "https://books.test/start" })
    scheduler:runAll()
    truthy(callbacks[1].err, "userinfo redirect returns a structured rejection")
    equal("NETWORK_ERROR", callbacks[1].err.code, "redirect userinfo is rejected")
    equal("redirect_userinfo", callbacks[1].err.details.reason, "redirect userinfo rejection is diagnostic")
    equal(1, #transport.requests, "userinfo redirect is never requested")
end

do
    local _, scheduler, transport, callbacks = run_fallback({
        { status = 200, chunks = { "ipv6" } },
        { status = 200, chunks = { "port" } },
    }, { url = "https://[2001:db8::1]:8443/books" })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "IPv6 with port remains valid")
    equal("https://[2001:db8::1]:8443/books", transport.requests[1].url, "IPv6 authority is preserved")

    local second = {}
    local engine = RequestEngine.new({
        transport = transport, scheduler = scheduler,
        subprocess = Fakes.subprocess({ enabled = false }), logger = silent_logger,
    })
    engine:execute({ url = "https://books.test:8443/path" }, function(response, err)
        second[#second + 1] = { response, err }
    end)
    scheduler:runAll()
    equal(nil, second[1][2], "host with port remains valid")
    equal("https://books.test:8443/path", transport.requests[2].url, "port authority is preserved")
end

do
    local body = string.rep(" ", 8 * 1024 * 1024 + 256 * 1024) .. "[]"
    local _, scheduler, _, callbacks = run_fallback({
        { status = 200, headers = { ["Content-Type"] = "application/json; charset=utf-8" }, chunks = { body } },
    }, { url = "https://sources.test/collection.json", max_bytes = require('legado.lib.source_importer').DEFAULT_MAX_BYTES })
    scheduler:runAll()
    equal(nil, callbacks[1].err, "an 8.25 MiB source collection is accepted within the import limit")
    equal(#body, #callbacks[1].response.body, "the complete collection reaches the importer")
end

return assertions
