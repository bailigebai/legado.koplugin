local Scanner = require("legado.lib.compatibility_scanner")
local SourceImporter = require("legado.lib.source_importer")
local Sanitizer = require("legado.lib.diagnostic_sanitizer")
local Models = require("legado.lib.models")

local SourceManager = {}
SourceManager.__index = SourceManager

function SourceManager.new(options)
    options = options or {}
    assert(options.storage, "SourceManager requires storage")
    return setmetatable({
        kind = "source_manager",
        storage = options.storage, importer = options.importer, requests = options.request_engine,
        diagnostics = options.diagnostics,
        fs = options.fs, scanner = options.scanner or Scanner, confirm = options.confirm or function() return false end,
        on_search = options.on_search, on_import = options.on_import,
        alive = true, generation = 0, request = nil,
    }, SourceManager)
end

function SourceManager:list()
    local sources = {}
    for _, source in ipairs(self.storage:listSources() or {}) do
        sources[#sources + 1] = source
    end
    table.sort(sources, function(left, right)
        local lg, rg = tostring(left.bookSourceGroup or ""), tostring(right.bookSourceGroup or "")
        if lg ~= rg then return lg < rg end
        return tostring(left.bookSourceName or "") < tostring(right.bookSourceName or "")
    end)
    return sources
end

function SourceManager:bookCount(source_id)
    local count = 0
    local book_source_id = Models.sourceId({ id = source_id })
    for _, book in ipairs(self.storage:listShelf() or {}) do
        if book.source_id == book_source_id or book.source_id == source_id then count = count + 1 end
    end
    return count
end

function SourceManager:viewModel()
    local sources = self:list()
    local counts = {}
    for _, book in ipairs(self.storage:listShelf() or {}) do
        if book.source_id then counts[book.source_id] = (counts[book.source_id] or 0) + 1 end
    end
    for _, source in ipairs(sources) do
        local id = Models.sourceId(source)
        source.shelf_count = (counts[id] or 0) + (id ~= source.id and (counts[source.id] or 0) or 0)
    end
    return {
        kind = "source_manager", sources = sources, empty_text = #sources == 0 and "暂无自行导入的书源" or nil,
        empty_actions = #sources == 0 and {
            { text = "搜索添加", callback = self.on_search },
            { text = "导入书源", callback = self.on_import },
        } or nil,
    }
end

function SourceManager:toggle(id)
    local source = self.storage:getSource(id)
    if not source then return nil end
    local updated, err = self.storage:updateSource(id, { enabled = source.enabled == false })
    if not updated then return nil, err end
    return updated.enabled, err
end

function SourceManager:importLocal(path, origin, options)
    if not self.importer or not self.fs then return nil end
    local text, read_error
    if type(self.fs.readBounded) == "function" then text, read_error = self.fs:readBounded(path, SourceImporter.DEFAULT_MAX_BYTES)
    elseif type(self.fs.read) == "function" then
        text, read_error = self.fs:read(path)
        if type(text) == "string" and #text > SourceImporter.DEFAULT_MAX_BYTES then
            text, read_error = nil, { code = "RESPONSE_TOO_LARGE", message = "书源文件超过 5 MiB" }
        end
    end
    if not text then return { imported = 0, updated = 0, rejected = 1, warnings = {}, compatibility = {}, error = read_error or { code = "STORAGE_ERROR", message = "无法读取书源文件" } } end
    return self.importer:importJson(text, origin or path, options)
end

function SourceManager:importUrl(url, callback)
    assert(type(callback) == "function", "remote import callback must be a function")
    local validated = SourceImporter.validateRemoteUrl(url)
    if not validated.valid then callback(nil, validated.error); return { cancel = function() return false end } end
    if not self.requests or not self.importer then callback(nil, { code = "NETWORK_ERROR", message = "远程导入不可用" }); return { cancel = function() return false end } end
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.generation = self.generation + 1
    local generation = self.generation
    self.request = self.requests:execute({ url = validated.url, max_bytes = SourceImporter.DEFAULT_MAX_BYTES }, function(response, err)
        if not self.alive or generation ~= self.generation then return end
        self.request = nil
        if err then callback(nil, err); return end
        callback(self.importer:importJson(response.body, response.final_url or validated.url), nil)
    end)
    return self.request
end

function SourceManager:close()
    if not self.alive then return false end
    self.alive = false
    self.generation = self.generation + 1
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = nil
    return true
end

function SourceManager:reopen()
    if self.alive then return false end
    self.alive = true
    self.generation = self.generation + 1
    self.request = nil
    return true
end

function SourceManager:compatibility(id)
    local source = self.storage:getSource(id)
    return source and Sanitizer.compatibility(self.scanner.scan(source)) or nil
end

function SourceManager:compatibilityReport(id)
    local source = self.storage:getSource(id)
    if not source then return nil end
    return require("legado.ui.compatibility_report").new({
        source = source,
        scanner = self.scanner,
        diagnostics = self.diagnostics,
    })
end

function SourceManager:update(id, callback)
    local source = self.storage:getSource(id)
    if not source or type(source.import_origin) ~= "string" then callback(nil, { code = "INVALID_INPUT", message = "没有可更新地址" }); return { cancel = function() return false end } end
    if source.import_origin:match("^[Hh][Tt][Tt][Pp][Ss]?://") then return self:importUrl(source.import_origin, callback) end
    local report = self:importLocal(source.import_origin)
    if report then callback(report, nil)
    else callback(nil, { code = "STORAGE_ERROR", message = "无法读取原书源文件" }) end
    return { cancel = function() return false end }
end

function SourceManager:delete(id)
    local source = self.storage:getSource(id)
    if not source then return false end
    local deleted = false
    local function accepted()
        if deleted then return false end
        deleted = self.storage:deleteSource(id) and true or false
        return deleted
    end
    local decision = self.confirm("删除书源“" .. tostring(source.bookSourceName or "") .. "”？", accepted)
    if decision == true then return accepted() end
    if decision == "pending" then return "pending" end
    return deleted
end

return SourceManager
