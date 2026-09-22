local SearchView = {}
SearchView.__index = SearchView

function SearchView.new(options)
    options = options or {}
    assert(options.service, "SearchView requires service")
    return setmetatable({ kind = "search", service = options.service, source_provider = options.source_provider,
        explore_source = options.explore_source, category_index = options.category_index, title = options.title,
        alive = true, loading = false, results = {}, errors = {}, request = nil, onUpdate = options.onUpdate,
        generation = 0, page = 1, has_more = false, cancelled = false, progress = {} }, SearchView)
end

function SearchView:sourceChoices()
    if type(self.source_provider) ~= "function" then return {} end
    local choices = {}
    for _, source in ipairs(self.source_provider() or {}) do
        if source.enabled ~= false then choices[#choices + 1] = { id = source.id, name = source.bookSourceName or source.name or "书源" } end
    end
    return choices
end

function SearchView:submit(keyword, source_ids, page)
    if not self.alive then return false end
    self.generation = self.generation + 1
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = nil
    local generation = self.generation
    page = math.max(1, math.floor(tonumber(page) or 1))
    self.previous_query = self.previous_query or { keyword = self.keyword, source_ids = self.source_ids, page = self.page,
        progress = self.progress, error = self.error }
    self.keyword, self.source_ids, self.page = keyword, source_ids, page
    self.loading = true
    self.cancelled, self.error, self.progress = false, nil, {}
    local function update(result, err, finished)
        if not self.alive or generation ~= self.generation then return end
        self.keyword, self.source_ids, self.page = keyword, source_ids, page
        self.previous_query = nil
        self.loading = not finished
        self.results = result and result.groups or {}
        self.errors = result and result.errors or {}
        self.error = err
        self.progress = result and { total = result.total, completed = result.completed, succeeded = result.succeeded, failed = result.failed } or {}
        self.has_more = not err and #self.results > 0
        if result and result.has_more ~= nil then self.has_more = not err and result.has_more == true end
        if type(self.onUpdate) == "function" then self.onUpdate(self) end
    end
    local function complete(result, err) update(result, err, true) end
    local request
    if self.explore_source then
        request = self.service:explore(self.explore_source, self.category_index, page, complete)
    else
        request = self.service:search(keyword, source_ids, page, complete, function(result) update(result, nil, false) end)
    end
    if not self.alive or generation ~= self.generation then
        if request and type(request.cancel) == "function" then request:cancel() end
    else self.request = request end
    return true
end

function SearchView:changePage(delta)
    if not self.alive or self.loading or (delta > 0 and not self.has_more) or self.page + delta < 1 then return false end
    return self:submit(self.keyword, self.source_ids, self.page + delta)
end

function SearchView:cancel()
    if not self.alive or not self.loading then return false end
    self.generation = self.generation + 1
    self.loading = false
    self.cancelled = true
    if self.previous_query then
        self.keyword, self.source_ids, self.page = self.previous_query.keyword, self.previous_query.source_ids, self.previous_query.page
        self.progress, self.error = self.previous_query.progress, self.previous_query.error
        self.previous_query = nil
    end
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = nil
    if type(self.onUpdate) == "function" then self.onUpdate(self) end
    return true
end

function SearchView:close()
    if not self.alive then return false end
    self.alive = false
    self.generation = self.generation + 1
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    return true
end

function SearchView:selectAlternative(group_index, alternative_index)
    local group = self.results[group_index]
    return group and group.alternatives and group.alternatives[alternative_index] or nil
end

return SearchView
