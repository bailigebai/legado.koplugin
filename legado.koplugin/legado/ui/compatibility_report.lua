local Capabilities = require("legado.lib.rule_capabilities")
local Scanner = require("legado.lib.compatibility_scanner")
local Sanitizer = require("legado.lib.diagnostic_sanitizer")

local CompatibilityReport = {}
CompatibilityReport.__index = CompatibilityReport

function CompatibilityReport.new(options)
    options = options or {}
    assert(type(options.source) == "table", "CompatibilityReport requires source")
    local scanner = options.scanner or Scanner
    local report = Sanitizer.compatibility(scanner.scan(options.source))
    local capabilities = {}
    for _, name in ipairs(Capabilities.CORE) do
        capabilities[#capabilities + 1] = { name = name, supported = report.capabilities[name] == true }
    end
    return setmetatable({
        kind = "compatibility_report",
        title = "兼容性报告",
        source = options.source,
        diagnostics = options.diagnostics,
        status = report.status,
        capabilities = capabilities,
        issues = report.issues or {},
        alive = true,
        request = nil,
        generation = 0,
        diagnostic = nil,
    }, CompatibilityReport)
end

function CompatibilityReport:cancel()
    local request = self.request
    if request == nil then return false end
    self.request = nil
    self.generation = self.generation + 1
    if type(request.cancel) == "function" then
        local ok, result = pcall(request.cancel, request)
        return ok and result ~= false
    end
    return true
end

function CompatibilityReport:run(keyword, callback)
    assert(type(callback) == "function", "diagnostic callback must be a function")
    if not self.alive or not self.diagnostics then return nil end
    self:cancel()
    self.generation = self.generation + 1
    local generation = self.generation
    local completed = false
    local request = self.diagnostics:run(self.source, keyword, function(report)
        if not self.alive or generation ~= self.generation then return end
        completed = true
        self.request = nil
        self.diagnostic = report
        callback(report)
    end)
    if not completed and generation == self.generation then self.request = request end
    return request
end

function CompatibilityReport:close()
    if not self.alive then return false end
    self.alive = false
    self:cancel()
    return true
end

return CompatibilityReport
