local A = require("assertions")
local Json = require("legado.lib.json_codec")
local Probe = dofile(os.getenv("LEGADO_PLUGIN_ROOT").."/../scripts/probe_sources.lua")
local source = {bookSourceUrl="https://fiction.test",bookSourceName="Probe",enabled=true,
    exploreUrl="分类::/category",ruleExplore={bookList="$.books[*]",name="$.name",bookUrl="$.url"},
    ruleBookInfo={name="id.info@tag.h1.0@text##\\(.*"}}
local probe = Probe.new(Json.encode({source}),function(request,sink)
    sink(request.url:find("category",1,true) and '{"books":[{"name":"Sample","url":"/one"}]}'
        or '<div id="info"><h1>Sample</h1></div>')
    return {status=200,headers={}},nil
end,function(value) return value end,function() return 0 end,10)
local report=Json.decode(probe.explore(1))
A.equal("failed",report.status,"invalid detail rule fails discovery")
A.truthy(report.rule_errors,"discovery reports the failing source field")
A.equal("ruleBookInfo.name",report.rule_errors[1].field,"diagnostic identifies the exact field")
A.equal("PARSE_ERROR",report.rule_errors[1].code,"diagnostic keeps only structured failure")
report=Json.decode(probe.explore(1))
A.equal(1,#report.rule_errors,"each discovery run resets rule failures")
return 5
