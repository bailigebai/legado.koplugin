local Scanner = require("legado.lib.compatibility_scanner")
local SourceImporter = require("legado.lib.source_importer")

local SourceManager = {}
SourceManager.__index = SourceManager

function SourceManager.new(options)
    options = options or {}
    assert(options.storage, "SourceManager requires storage")
    return setmetatable({
        kind = "source_manager",
        storage = options.storage, importer = options.importer, requests = options.request_engine,
        fs = options.fs, scanner = options.scanner or Scanner, confirm = options.confirm or function() return false end,
    }, SourceManager)
end

function SourceManager:list()
    local sources = self.storage:listSources() or {}
    table.sort(sources, function(left, right)
        local lg, rg = tostring(left.bookSourceGroup or ""), tostring(right.bookSourceGroup or "")
        if lg ~= rg then return lg < rg end
        return tostring(left.bookSourceName or "") < tostring(right.bookSourceName or "")
    end)
    return sources
end

function SourceManager:toggle(id)
    local source = self.storage:getSource(id)
    if not source then return nil end
    local updated, err = self.storage:updateSource(id, { enabled = source.enabled == false })
    if not updated then return nil, err end
    return updated.enabled, err
end

function SourceManager:importLocal(path)
    if not self.importer or not self.fs then return nil end
    local text = self.fs:read(path)
    if not text then return nil end
    return self.importer:importJson(text, path)
end

function SourceManager:importUrl(url, callback)
    assert(type(callback) == "function", "remote import callback must be a function")
    local validated = SourceImporter.validateRemoteUrl(url)
    if not validated.valid then callback(nil, validated.error); return { cancel = function() return false end } end
    if not self.requests or not self.importer then callback(nil, { code = "NETWORK_ERROR", message = "远程导入不可用" }); return { cancel = function() return false end } end
    return self.requests:execute({ url = validated.url, max_bytes = SourceImporter.DEFAULT_MAX_BYTES }, function(response, err)
        if err then callback(nil, err); return end
        callback(self.importer:importJson(response.body, response.final_url or validated.url), nil)
    end)
end

function SourceManager:compatibility(id)
    local source = self.storage:getSource(id)
    return source and self.scanner.scan(source) or nil
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
