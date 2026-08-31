local assertx = require("assertions")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

local plugin_root = assert(os.getenv("LEGADO_PLUGIN_ROOT")):gsub("\\", "/")
local repository_root = plugin_root:gsub("/legado%.koplugin$", "")

local function read(relative)
    local file = assert(io.open(repository_root .. "/" .. relative, "rb"), "missing release document: " .. relative)
    local text = file:read("*a")
    file:close()
    return text
end

local readme = read("README.md")
truthy(readme:find("KPW6", 1, true), "README names the target Kindle")
truthy(readme:find("5.19.5", 1, true), "README states the tested firmware target")
truthy(readme:find("KOReader v2026.07.1", 1, true), "README states the compatibility baseline")
truthy(readme:find("不附带书源", 1, true), "README says no sources are bundled")
truthy(readme:find("不执行", 1, true) and readme:find("JavaScript", 1, true), "README documents the JavaScript safety boundary")
truthy(readme:find("AGPL%-3%.0"), "README states the project license")
truthy(readme:find("legado.koplugin", 1, true), "README contains installation location guidance")
truthy(readme:find("## 故障排查", 1, true), "README has troubleshooting guidance")
truthy(readme:find("## 卸载与清理", 1, true), "README has uninstall guidance")
truthy(readme:find("DataStorage:getDataDir()", 1, true), "README identifies the actual KOReader data root")
truthy(readme:find("${DataStorage:getDataDir()}/settings/legado.json", 1, true),
    "README identifies the actual KOReader settings file")
truthy(readme:find("同时删除", 1, true), "README says full cleanup removes both data locations")
for _, token in ipairs({ "/legado/cache/", "/legado/covers/", "/legado/downloads/", "/legado/legado.sqlite" }) do
    truthy(readme:find(token, 1, true), "README documents cleanup location " .. token)
end

local rules = read("docs/rule-compatibility.md")
for _, token in ipairs({ "CSS", "JSONPath", "XPath", "{{", "&&", "||", "##", "@js:", "WebView" }) do
    truthy(rules:find(token, 1, true), "rule compatibility document covers " .. token)
end

local privacy = read("docs/privacy-and-copyright.md")
for _, token in ipairs({ "Cookie", "日志", "书源", "版权", "JavaScript", "4 MB", "20 秒" }) do
    truthy(privacy:find(token, 1, true), "privacy document covers " .. token)
end
truthy(privacy:find("退出 KOReader", 1, true), "privacy document gives an executable safe deletion procedure")
truthy(privacy:find("Cookie Jar 只驻留内存", 1, true), "privacy document accurately states cookie persistence")
truthy(privacy:find("Header", 1, true) and privacy:find("legado.sqlite", 1, true),
    "privacy document explains persisted source headers and credentials")
truthy(privacy:find("${DataStorage:getDataDir()}/settings/legado.json", 1, true),
    "privacy document identifies the separately persisted settings file")
truthy(privacy:find("同时删除", 1, true), "privacy full-cleanup procedure removes data and settings")

local testing = read("docs/testing.md")
for _, token in ipairs({ "run-specs.ps1", "package.ps1", "verify-package.ps1", "check-koreader-compat.ps1", "未连接" }) do
    truthy(testing:find(token, 1, true), "testing document covers " .. token)
end

local checklist = read("docs/kpw6-checklist.md")
local unchecked = 0
for _ in checklist:gmatch("%- %[ %]") do unchecked = unchecked + 1 end
truthy(unchecked >= 10, "KPW6 checklist contains the required manual scenarios")
equal(nil, checklist:lower():find("%- %[x%]"), "no physical-device item is claimed as passed")
truthy(checklist:find("尚未执行", 1, true), "checklist explicitly says hardware testing is pending")

return count
