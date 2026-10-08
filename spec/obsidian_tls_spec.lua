local A=require('assertions')
local Transport=require('legado.lib.socket_transport')
local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local sent,closed,params=0,0,nil
local pin=string.rep('a',64)
local actual=pin
local https={TIMEOUT=60,tcp=function(options)
 params=options
 return function()
   local conn={sock={close=function() closed=closed+1 end}}
   function conn:connect() return 1 end
   function conn:getpeercertificate() return {digest=function() return actual end} end
   return conn
 end
end}
local http={TIMEOUT=60,request=function(req)
 local conn=req.create();local ok,err=conn:connect('192.168.1.2',27124)
 if not ok then return nil,err end
 sent=sent+1;req.sink('ok');return 1,200,{}
end}
local transport=Transport.new{http=http,https=https,ltn12={}}
local request={url='https://192.168.1.2:27124/',tls_ca_file='ca.pem',tls_pin_sha256=pin,
 headers={Authorization='Bearer private'},timeout=8}
eq(200,transport:request(request,function() return true end).status,'pinned server accepted')
eq('peer',params.verify,'certificate chain verified during handshake')
eq('ca.pem',params.cafile,'user-approved receiver CA used')
eq(1,sent,'only verified server receives HTTP headers')
eq(60,https.TIMEOUT,'TLS module timeout restored')
actual=string.rep('b',64)
eq(nil,transport:request(request,function() return true end),'wrong certificate refused')
eq(1,sent,'no authorization or text sent to wrong certificate')
eq(1,closed,'rejected TLS connection closed')
https.tcp=nil
eq(nil,transport:request(request,function() return true end),'missing pin capability fails closed')
eq(1,sent,'missing capability never silently downgrades')
return n
