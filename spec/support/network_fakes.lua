local Fakes = {}

function Fakes.scheduler()
    local scheduler = { queue = {}, now_value = 0 }

    function scheduler:scheduleIn(delay, action)
        self.queue[#self.queue + 1] = {
            at = self.now_value + (delay or 0),
            action = action,
        }
        table.sort(self.queue, function(left, right) return left.at < right.at end)
        return action
    end

    function scheduler:unschedule(action)
        local removed = false
        for index = #self.queue, 1, -1 do
            if self.queue[index].action == action then
                table.remove(self.queue, index)
                removed = true
            end
        end
        return removed
    end

    function scheduler:now()
        return self.now_value
    end

    function scheduler:advance(seconds)
        self.now_value = self.now_value + seconds
    end

    function scheduler:runNext()
        local item = table.remove(self.queue, 1)
        if not item then return false end
        if item.at > self.now_value then self.now_value = item.at end
        item.action()
        return true
    end

    function scheduler:runAll(limit)
        local count = 0
        while #self.queue > 0 do
            count = count + 1
            if count > (limit or 100) then error("scheduler did not become idle") end
            self:runNext()
        end
    end

    return scheduler
end

function Fakes.transport(script)
    local transport = { script = script or {}, requests = {}, aborted = 0 }

    function transport:request(request, sink)
        self.requests[#self.requests + 1] = request
        local response = table.remove(self.script, 1)
        if type(response) == "function" then response = response(request) end
        response = response or { status = 200, headers = {}, chunks = { "" } }
        if response.error then return nil, response.error end
        for _, chunk in ipairs(response.chunks or { response.body or "" }) do
            local accepted, sink_error = sink(chunk)
            if accepted == nil or accepted == false then
                self.aborted = self.aborted + 1
                return nil, sink_error or "sink rejected response"
            end
        end
        return {
            status = response.status or 200,
            headers = response.headers or {},
            final_url = response.final_url or request.url,
        }, nil
    end

    return transport
end

function Fakes.subprocess(options)
    options = options or {}
    local adapter = {
        enabled = options.enabled ~= false,
        children = {},
        terminated = 0,
        reaped = 0,
        closed = 0,
        malformed = options.malformed,
        polls_before_done = options.polls_before_done or 0,
        start_error = options.start_error,
        before_job = options.before_job,
        after_job = options.after_job,
        poll_error = options.poll_error,
    }

    function adapter:available()
        return self.enabled
    end

    function adapter:start(job)
        if self.start_error then return nil, self.start_error end
        local child = {
            job = job,
            polls = 0,
            terminated = false,
            closed = false,
            reaped = false,
        }
        self.children[#self.children + 1] = child
        return child
    end

    function adapter:poll(child)
        child.polls = child.polls + 1
        if child.polls <= self.polls_before_done then return false end
        if self.poll_error then return true, nil, self.poll_error end
        if not child.payload and not child.terminated then
            if self.before_job then self.before_job() end
            local ok, payload = pcall(child.job)
            child.payload = self.malformed or (ok and payload or { panic = tostring(payload) })
            if self.after_job then self.after_job() end
        end
        return true, child.payload
    end

    function adapter:terminate(child)
        if not child.terminated then
            child.terminated = true
            self.terminated = self.terminated + 1
        end
    end

    function adapter:reap(child)
        if not child.reaped then
            child.reaped = true
            self.reaped = self.reaped + 1
        end
        return true
    end

    function adapter:close(child)
        if not child.closed then
            child.closed = true
            self.closed = self.closed + 1
        end
    end

    return adapter
end

return Fakes
