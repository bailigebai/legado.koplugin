local SearchView = {}
SearchView.__index = SearchView

function SearchView.new(options)
    options = options or {}
    assert(options.service, "SearchView requires service")
    return setmetatable({ kind = "search", service = options.service, source_provider = options.source_provider, alive = true, loading = false, results = {}, errors = {}, request = nil, onUpdate = options.onUpdate, generation = 0 }, SearchView)
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
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.generation = self.generation + 1
    local generation = self.generation
    self.loading, self.error = true, nil
    self.request = self.service:search(keyword, source_ids, page, function(result, err)
        if not self.alive or generation ~= self.generation then return end
        self.loading = false
        self.results = result and result.groups or {}
        self.errors = result and result.errors or {}
        self.error = err
        if type(self.onUpdate) == "function" then self.onUpdate(self) end
    end)
    return true
end

function SearchView:cancel()
    if not self.alive or not self.loading then return false end
    self.generation = self.generation + 1
    self.loading = false
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = nil
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
