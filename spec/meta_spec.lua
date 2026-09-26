local assertx = require("assertions")
local plugin_root = assert(os.getenv("LEGADO_PLUGIN_ROOT"), "missing plugin root")

local meta = dofile(plugin_root .. "/_meta.lua")

assertx.type("table", meta, "metadata is a table")
assertx.equal("legado", meta.name, "plugin name")
assertx.equal("书源阅读", meta.fullname, "Chinese full name")
assertx.type("string", meta.description, "description type")
assertx.truthy(#meta.description > 0, "description is present")
assertx.equal("0.10.34", meta.version, "version")

return 6
