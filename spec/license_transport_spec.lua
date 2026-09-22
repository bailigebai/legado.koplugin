local A=require('assertions')
local Transport=require('legado.lib.license_transport')
local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
eq('https://legado-receipt-shelf-gateway.pages.dev/activate',Transport.ENDPOINT,'uses the independently verified Legado Pages entry')
local payload={product='legado-receipt-shelf',key='ABCD-EFGH-JKMN',device_id=string.rep('b',64)}
local function fixture()
    local f={closed=0,code=200,body='{}',response={ok=true},now=0}
    local sock={settimeout=function()return true end,close=function()f.closed=f.closed+1 end,
        connect=function()if f.connect_error then return nil,f.connect_error end;return true end,
        sni=function(_,host)eq(true,Transport.ENDPOINT:find(host,1,true)~=nil,'TLS uses fixed origin')end,
        dohandshake=function()if f.tls_error then return nil,f.tls_error end;return true end,
        getpeercertificate=function()return {checkhost=function()return not f.bad_host end}end}
    f.deps={socket={gettime=function()return f.now end,tcp=function()return sock end},
        ssl={wrap=function(_,options)
            eq('peer',options.verify,'TLS peer verification retained');eq('test-ca',options.cafile,'trusted CA retained')
            return sock
        end},json={encode=function()return f.encoded or '{}'end,decode=function()if f.bad_json then error('bad body')end;return f.response end},
        ltn12={source={string=function(value)return value end}},ca_file='test-ca',read_file=function()return not f.no_ca end,
        http={request=function(options)
            f.sent=options
            eq(false,options.redirect,'activation never follows redirects')
            local connection=options.create()
            local ok,reason=connection:connect('legado-receipt-shelf-gateway.pages.dev',443)
            if not ok then return nil,reason end
            if f.receive_timeout then return nil,'timeout' end
            local received,error_code=options.sink(f.body)
            return received,received and f.code or error_code
        end}}
    function f:request()return Transport.request(payload,self.deps)end
    return f
end
for _,case in ipairs{
    {'host not found','dns_error'}, {'Temporary failure in name resolution','dns_error'},
    {'connection refused','tcp_error'}, {'timeout','tcp_timeout'}, {'Network is unreachable','offline'},
}do
    local f=fixture();f.connect_error=case[1];local result,reason=f:request()
    eq(nil,result,'failed connection returns no receipt');eq(case[2],reason,'connection stage distinguished')
    eq(1,f.closed,'failed socket closed exactly once')
end
for _,case in ipairs{{'certificate verify failed','tls_error'},{'timeout','tls_timeout'}}do
    local f=fixture();f.tls_error=case[1];local _,reason=f:request()
    eq(case[2],reason,'TLS stage distinguished');eq(1,f.closed,'TLS failure closes socket')
end
local f=fixture();f.bad_host=true;local _,reason=f:request();eq('tls_error',reason,'wrong hostname rejected')
f=fixture();f.no_ca=true;_,reason=f:request();eq('tls_unavailable',reason,'missing CA fails closed');eq(nil,f.sent,'missing CA sends nothing')
f=fixture();f.code=302;_,reason=f:request();eq('redirect_refused',reason,'redirect response rejected')
f=fixture();f.code=503;_,reason=f:request();eq('server_error',reason,'server error distinguished')
f=fixture();f.code=403;f.response={ok=false,error='bound_to_other_device'}
local result=f:request();eq('bound_to_other_device',result.error,'server rejection preserves safe structured reason')
f=fixture();f.body=string.rep('x',8193);_,reason=f:request();eq('response_too_large',reason,'8192-byte response limit preserved')
f=fixture();f.encoded=string.rep('x',513);_,reason=f:request();eq('invalid_request',reason,'512-byte request limit preserved')
eq(nil,f.sent,'oversized payload never sends')
f=fixture();f.bad_json=true;_,reason=f:request();eq('invalid_response',reason,'malformed server response distinguished')
f=fixture();f.receive_timeout=true;_,reason=f:request();eq('timeout',reason,'response deadline distinct from handshake')
f=fixture();f.deps.http.PROXY='http://proxy';_,reason=f:request();eq('proxy_not_supported',reason,'implicit proxy refused')
return n
