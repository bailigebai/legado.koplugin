local Capabilities = require("legado.lib.rule_capabilities")
local Scanner = require("legado.lib.compatibility_scanner")

local CompatibilityReport = {}
CompatibilityReport.__index = CompatibilityReport

function CompatibilityReport.new(options)
    options = options or {}
    assert(type(options.source) == "table", "CompatibilityReport requires source")
    local scanner = options.scanner or Scanner
    local report = scanner.scan(options.source)
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
        diagnostic = nil,
    }, CompatibilityReport)
end

function CompatibilityReport:run(keyword, callback)
    assert(type(callback) == "function", "diagnostic callback must be a function")
    if not self.alive or not self.diagnostics then return nil end
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = self.diagnostics:run(self.source, keyword, function(report)
        if not self.alive then return end
        self.diagnostic = report
        callback(report)
    end)
    return self.request
end

function CompatibilityReport:close()
    if not self.alive then return false end
    self.alive = false
    if self.request and type(self.request.cancel) == "function" then self.request:cancel() end
    self.request = nil
    return true
end

return CompatibilityReport
