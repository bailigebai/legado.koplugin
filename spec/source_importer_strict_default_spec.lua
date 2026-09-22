local assertx = require("assertions")
local SourceImporter = require("legado.lib.source_importer")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local function storage_double()
    local storage = { replace_calls = 0, sources = {} }
    function storage:listSources() return self.sources end
    function storage:replaceSources(sources)
        self.replace_calls = self.replace_calls + 1
        self.sources = sources
        return true
    end
    return storage
end

local function loose_result()
    return {
        bookSourceName = "Loose native result",
        bookSourceUrl = "https://loose.example/source",
        searchUrl = "https://loose.example/search?key={{key}}",
        ruleSearch = ".result", ruleBookInfo = ".info", ruleToc = ".chapter", ruleContent = "#content",
    }
end

local previous_preload, previous_loaded = package.preload["json"], package.loaded["json"]
local loose_calls = 0
package.loaded["json"] = nil
package.preload["json"] = function()
    return { decode = function()
        loose_calls = loose_calls + 1
        return loose_result()
    end }
end

for _, payload in ipairs({
    '{"bookSourceName":"X","bookSourceUrl":"https://a","bookSourceUrl":"https://b"}',
    '{"bookSourceName":"X","bookSourceUrl":"https://a","header":"A","header":"B"}',
    '{"bookSourceName":"X","bookSourceUrl":"https://a","header":{"Authorization":"A","Authorization":"B"}}',
    '{"bookSourceName":"X","bookSourceUrl":"https://a","ruleSearch":{"bookList":".a","bookList":".b"}}',
    '{"bookSourceName":"X","bookSourceUrl":"https://a",}',
    '{bookSourceName:"X","bookSourceUrl":"https://a"}',
    '{"bookSourceName":"X","bookSourceUrl":"https://a","weight":01}',
}) do
    local storage = storage_double()
    local importer = SourceImporter:new({ storage = storage })
    local report = assert(importer:importJson(payload, "C:/sources/strict.json"))
    equal(1, report.rejected, "production default rejects JSON syntax accepted by a loose native decoder")
    equal("PARSE_ERROR", report.error and report.error.code, "strict default returns a structured parse error")
    equal(0, storage.replace_calls, "invalid source JSON performs zero persistence writes")
end
equal(0, loose_calls, "production default never consults KOReader's loose native json module")

local valid_object = [[{"bookSourceName":"Strict","bookSourceUrl":"https://strict.example/one",
"searchUrl":"https://strict.example/search?key={{key}}","ruleSearch":".result","ruleBookInfo":".info",
"ruleToc":".chapter","ruleContent":"#content"}]]
local valid_storage = storage_double()
local valid_importer = SourceImporter:new({ storage = valid_storage })
equal(1, assert(valid_importer:importJson(valid_object, "C:/sources/one.json")).imported,
    "strict production default imports a legal single source")
local second_object = valid_object:gsub("/one", "/two")
equal(1, assert(valid_importer:importJson("[" .. valid_object .. "," .. second_object .. "]",
    "C:/sources/list.json")).imported, "strict production default imports a legal source array")
equal(2, #valid_storage.sources, "legal source arrays retain both entries")

local injected_calls = 0
local injected_storage = storage_double()
local injected = SourceImporter:new({ storage = injected_storage, json = { decode = function(text)
    injected_calls = injected_calls + 1
    equal("controlled payload", text, "explicit injected decoder receives the original text")
    return loose_result()
end } })
equal(1, assert(injected:importJson("controlled payload", "C:/sources/injected.json")).imported,
    "explicit options.json remains available for controlled tests")
equal(1, injected_calls, "explicit decoder is invoked exactly once")

package.preload["json"], package.loaded["json"] = previous_preload, previous_loaded

local plugin_root = assert(os.getenv("LEGADO_PLUGIN_ROOT")):gsub("\\", "/")
local function read(relative)
    local handle = assert(io.open(plugin_root .. "/" .. relative, "rb"))
    local text = handle:read("*a")
    handle:close()
    return text
end
local importer_source = read("legado/lib/source_importer.lua")
equal(nil, importer_source:find('require("json")', 1, true),
    "source importer has no external native JSON fallback")
local bootstrap_source = read("legado/ui/bootstrap.lua")
truthy(bootstrap_source:find("json = Json", 1, true),
    "Bootstrap explicitly injects the strict bundled decoder into source imports")

return count
