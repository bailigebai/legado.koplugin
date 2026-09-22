local assertx = require("assertions")
local Fakes = require("support.network_fakes")
local RequestEngine = require("legado.lib.request_engine")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local logger = { debug = function() end, warn = function() end }

local function engine_with(options)
    local scheduler = options.scheduler or Fakes.scheduler()
    local subprocess = options.subprocess or Fakes.subprocess({ polls_before_done = options.polls_before_done or 2 })
    local transport = options.transport or Fakes.transport(options.script or {})
    local engine = RequestEngine.new({
        scheduler = scheduler, subprocess = subprocess, transport = transport,
        concurrency = options.concurrency, logger = logger,
    })
    return engine, scheduler, subprocess, transport
end

do
    local engine, scheduler, subprocess = engine_with({ concurrency = 2, polls_before_done = 2 })
    local callbacks, handles = {}, {}
    for index = 1, 20 do
        handles[index] = engine:execute({ url = "https://books.test/" .. index }, function(response, err)
            callbacks[#callbacks + 1] = { index = index, response = response, err = err }
        end)
    end
    equal(2, #subprocess.children, "twenty-style eager loads start only the default two slots")
    equal(true, handles[20]:cancel(), "queued request can be cancelled")
    equal(2, #subprocess.children, "queued cancellation never starts a child")
    scheduler:runAll(200)
    equal(19, #subprocess.children, "slot release drains all non-cancelled queued requests")
    equal(19, #callbacks, "queued cancellation has no callback")
    for index = 1, 19 do equal(index, callbacks[index].index, "pending requests complete in FIFO order") end
end

do
    local engine, scheduler, subprocess = engine_with({ concurrency = 3, polls_before_done = 3 })
    for index = 1, 6 do engine:execute({ url = "https://books.test/three/" .. index }, function() end) end
    equal(3, #subprocess.children, "configured concurrency three starts at most three children")
    scheduler:runAll(300)
    equal(6, #subprocess.children, "concurrency three eventually drains all requests")
end

do
    local engine, scheduler, subprocess = engine_with({ concurrency = 1, polls_before_done = 5 })
    local callbacks = 0
    local first = engine:execute({ url = "https://books.test/active" }, function() callbacks = callbacks + 1 end)
    engine:execute({ url = "https://books.test/next" }, function() callbacks = callbacks + 1 end)
    equal(1, #subprocess.children, "second request waits behind the active request")
    equal(true, first:cancel(), "active request cancellation succeeds")
    equal(1, subprocess.terminated, "active cancellation terminates its child")
    equal(2, #subprocess.children, "active cancellation releases the slot to the next request")
    scheduler:runAll(300)
    equal(1, callbacks, "active cancellation has no callback and successor completes once")
end

do
    local subprocess = Fakes.subprocess({ polls_before_done = 5 })
    function subprocess:terminate() error("terminate panic") end
    local engine, _, active = engine_with({ concurrency = 1, subprocess = subprocess })
    local first = engine:execute({ url = "https://books.test/cancel-panic" }, function() end)
    engine:execute({ url = "https://books.test/after-cancel-panic" }, function() end)
    local ok = pcall(first.cancel, first)
    equal(true, ok, "active cancellation contains subprocess termination panic")
    equal(2, #active.children, "termination panic still releases the slot")
end

do
    local subprocess = Fakes.subprocess({ polls_before_done = 0 })
    function subprocess:reap() error("reap panic") end
    local engine, scheduler, active = engine_with({ concurrency = 1, subprocess = subprocess })
    local callbacks = 0
    engine:execute({ url = "https://books.test/reap-panic" }, function() callbacks = callbacks + 1 end)
    engine:execute({ url = "https://books.test/after-reap-panic" }, function() callbacks = callbacks + 1 end)
    local ok = pcall(scheduler.runAll, scheduler, 50)
    equal(true, ok, "child reap panic is contained")
    equal(2, #active.children, "reap panic releases the slot to the next request")
    equal(2, callbacks, "reap panic does not duplicate or lose completed callbacks")
end

do
    local subprocess = Fakes.subprocess({ polls_before_done = 0 })
    function subprocess:poll() error("poll panic") end
    local engine, scheduler, active = engine_with({ concurrency = 1, subprocess = subprocess })
    local codes = {}
    engine:execute({ url = "https://books.test/poll-panic" }, function(_, err) codes[#codes + 1] = err.code end)
    engine:execute({ url = "https://books.test/after-poll-panic" }, function(_, err) codes[#codes + 1] = err.code end)
    local ok = pcall(scheduler.runAll, scheduler, 50)
    equal(true, ok, "child poll panic is contained")
    equal(2, #active.children, "poll panic releases the slot to the next request")
    equal("NETWORK_ERROR", codes[1], "poll panic becomes a structured error")
end

do
    local engine, scheduler, subprocess = engine_with({ concurrency = 1, polls_before_done = 100 })
    local codes = {}
    engine:execute({ url = "https://books.test/timeout", timeout = 0.1 }, function(_, err) codes[#codes + 1] = err.code end)
    engine:execute({ url = "https://books.test/after-timeout", timeout = 0.1 }, function(_, err) codes[#codes + 1] = err.code end)
    equal(1, #subprocess.children, "queued request deadline does not begin while waiting")
    local timeout_steps = 0
    while #codes == 0 and timeout_steps < 10 do timeout_steps = timeout_steps + 1; scheduler:runNext() end
    equal("TIMEOUT", codes[1], "active timeout completes once")
    equal(2, #subprocess.children, "timeout releases a slot and starts the queued request")
end

do
    local subprocess = Fakes.subprocess({ polls_before_done = 100 })
    function subprocess:terminate() error("timeout terminate panic") end
    local engine, scheduler, active = engine_with({ concurrency = 1, subprocess = subprocess })
    local codes = {}
    engine:execute({ url = "https://books.test/timeout-panic", timeout = 0.1 }, function(_, err) codes[#codes + 1] = err.code end)
    engine:execute({ url = "https://books.test/after-timeout-panic", timeout = 0.1 }, function(_, err) codes[#codes + 1] = err.code end)
    local ok, steps = true, 0
    while ok and #codes == 0 and steps < 10 do steps = steps + 1; ok = pcall(scheduler.runNext, scheduler) end
    equal(true, ok, "timeout contains subprocess termination panic")
    equal("TIMEOUT", codes[1], "timeout panic still produces the hard timeout callback")
    equal(2, #active.children, "timeout panic still releases the slot")
end

do
    local immediate = { now_value = 0 }
    function immediate:scheduleIn(_, action) action(); return action end
    function immediate:unschedule() return false end
    function immediate:now() return self.now_value end
    local transport = Fakes.transport({
        { status = 200, chunks = { "one" } },
        { status = 200, chunks = { "two" } },
    })
    local engine = RequestEngine.new({ scheduler = immediate, subprocess = Fakes.subprocess({ enabled = false }), transport = transport, concurrency = 1, logger = logger })
    local callbacks = {}
    engine:execute({ url = "https://books.test/one" }, function()
        callbacks[#callbacks + 1] = "one"
        engine:execute({ url = "https://books.test/two" }, function() callbacks[#callbacks + 1] = "two" end)
    end)
    equal(2, #transport.requests, "synchronous scheduler and callback reentrant execute drain safely")
    equal("one", callbacks[1], "first synchronous callback occurs once")
    equal("two", callbacks[2], "reentrant callback occurs once")
end

do
    local scheduler = Fakes.scheduler()
    function scheduler:unschedule() error("unschedule completion panic") end
    local engine, runner, subprocess = engine_with({ concurrency = 1, scheduler = scheduler, polls_before_done = 0 })
    local callbacks = 0
    engine:execute({ url = "https://books.test/unschedule-complete" }, function() callbacks = callbacks + 1 end)
    engine:execute({ url = "https://books.test/after-unschedule-complete" }, function() callbacks = callbacks + 1 end)
    local ok = pcall(runner.runAll, runner, 50)
    equal(true, ok, "completion contains scheduler unschedule panic")
    equal(2, #subprocess.children, "completion unschedule panic releases the slot FIFO")
    equal(2, callbacks, "completion unschedule panic preserves exactly-once callbacks")
end

do
    local scheduler = Fakes.scheduler()
    function scheduler:unschedule() error("unschedule cancel panic") end
    local engine, _, subprocess = engine_with({ concurrency = 1, scheduler = scheduler, polls_before_done = 5 })
    local callbacks = 0
    local first = engine:execute({ url = "https://books.test/unschedule-cancel" }, function() callbacks = callbacks + 1 end)
    engine:execute({ url = "https://books.test/after-unschedule-cancel" }, function() callbacks = callbacks + 1 end)
    local ok, cancelled = pcall(first.cancel, first)
    equal(true, ok, "active cancel contains scheduler unschedule panic")
    equal(true, cancelled, "active cancel still reports success")
    equal(2, #subprocess.children, "cancel unschedule panic releases the slot FIFO")
    equal(0, callbacks, "cancelled request never calls back before successor runs")
end

do
    local engine, scheduler, _, transport = engine_with({ concurrency = 1, polls_before_done = 1 })
    engine:execute({ url = 'https://books.test/active' }, function() end)
    engine:execute({ url = 'https://books.test/background', priority = 'background' }, function() end)
    engine:execute({ url = 'https://books.test/next', priority = 'next' }, function() end)
    engine:execute({ url = 'https://books.test/foreground', priority = 'foreground' }, function() end)
    scheduler:runAll(100)
    equal('https://books.test/foreground', transport.requests[2].url, 'explicit reading overtakes queued prefetch')
    equal('https://books.test/next', transport.requests[3].url, 'next chapter overtakes background work')
    equal('https://books.test/background', transport.requests[4].url, 'background work eventually completes')
end

do
    local engine, scheduler, subprocess, transport = engine_with({ concurrency = 1, polls_before_done = 1 })
    engine:execute({ url = 'https://books.test/active' }, function() end)
    local promoted = engine:execute({ url = 'https://books.test/promoted', priority = 'background' }, function() end)
    engine:execute({ url = 'https://books.test/next', priority = 'next' }, function() end)
    equal(true, promoted:promote('foreground'), 'queued chapter can be raised to reading priority')
    equal(false, promoted:promote('background'), 'promotion cannot lower priority')
    equal(1, #subprocess.children, 'promotion does not create another worker')
    scheduler:runAll(100)
    equal('https://books.test/promoted', transport.requests[2].url, 'promotion changes actual dispatch order')
    equal(false, promoted:promote('foreground'), 'completed handle cannot be promoted')
end

do
    local engine, scheduler, _, transport = engine_with({ concurrency = 1, polls_before_done = 1 })
    engine:execute({ url = 'https://books.test/active' }, function() end)
    engine:execute({ url = 'https://books.test/background', priority = 'background' }, function() end)
    for index = 1, 10 do engine:execute({ url = 'https://books.test/reading/' .. index, priority = 'foreground' }, function() end) end
    scheduler:runAll(200)
    equal('https://books.test/background', transport.requests[6].url, 'oldest background request runs after at most four overtakes')
    equal(12, #transport.requests, 'fair scheduling drains every request')
end

return count
