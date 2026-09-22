local A=require("assertions")
local ffi=require("ffi")
local old=ffi.loadlib
ffi.loadlib=function() return ffi.load(os.getenv("LEGADO_ZLIB") or "C:/Program Files/Git/mingw64/bin/zlib1.dll") end
local Requests=require("legado.lib.request_engine")
local body,encoding="\031\139\008\000\243\097\162\106\002\255\179\201\040\201\205\177\179\201\048\180\115\202\207\207\182\209\007\050\128\004\072\012\000\177\231\241\248\026\000\000\000","gzip"
local engine=Requests.new({scheduler={scheduleIn=function() end},logger={},transport={request=function(_,_,sink)
    sink(body); return {status=200,headers={["Content-Encoding"]=encoding,["Content-Type"]="text/html"}}
end}})
local function run(limit)
    local request=assert(engine:_normalize({url="https://site.test",max_bytes=limit or 1024}))
    return engine:_run_work(request,engine.now()+20)
end
A.equal("\060\104\116\109\108\062\060\104\049\062\066\111\111\107\060\047\104\049\062\060\047\104\116\109\108\062",run().response.body,"real zlib decodes gzip before HTML parser")
body,encoding="\120\156\179\201\040\201\205\177\179\201\048\180\115\202\207\207\182\209\007\050\128\004\072\012\000\114\254\008\110","deflate"
A.equal("\060\104\116\109\108\062\060\104\049\062\066\111\111\107\060\047\104\049\062\060\047\104\116\109\108\062",run().response.body,"HTTP deflate decoding uses same bounded native path")
body,encoding="\031\139\008\000\243\097\162\106\002\255\171\168\024\005\163\096\020\140\130\081\048\010\070\193\072\003\000\207\052\082\111\000\008\000\000","gzip"
A.equal("RESPONSE_TOO_LARGE",run(256).error.code,"expanded size is bounded")
body="broken"
A.equal("ENCODING_ERROR",run().error.code,"invalid compressed response fails explicitly")
body=("\031\139\008\000\243\097\162\106\002\255\179\201\040\201\205\177\179\201\048\180\115\202\207\207\182\209\007\050\128\004\072\012\000\177\231\241\248\026\000\000\000"):sub(1,-2)
A.equal("ENCODING_ERROR",run().error.code,"truncated gzip fails checksum/end validation")
body,encoding="\031\139\008\000\243\097\162\106\002\255\179\201\040\201\205\177\179\201\048\180\115\202\207\207\182\209\007\050\128\004\072\012\000\177\231\241\248\026\000\000\000","br"
A.equal("ENCODING_ERROR",run().error.code,"unknown encoding cannot reach parser as gibberish")
ffi.loadlib=old
return 6
