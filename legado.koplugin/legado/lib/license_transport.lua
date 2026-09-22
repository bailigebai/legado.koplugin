-- Narrow adaptation of the project's vetted manga TLS transport. No dependency
-- on the manga plugin; activation has a fixed origin and never follows redirects.
local Transport={}
local HOST="legado-receipt-shelf-gateway.pages.dev"
Transport.ENDPOINT="https://"..HOST.."/activate"
Transport.TIMEOUT=10
local function matches(host,name)
    if type(name)~="string" then return false end
    name=name:lower():gsub("%.$","")
    if name==host then return true end
    if name:sub(1,2)~="*." or name:find("*",2,true)then return false end
    local suffix=name:sub(2)
    local prefix=host:sub(1,#host-#suffix)
    return host:sub(-#suffix)==suffix and prefix~="" and not prefix:find(".",1,true)
end
function Transport.certificateMatches(certificate,host)
    if not certificate or type(host)~="string" then return false end
    host=host:lower():gsub("%.$","")
    if type(certificate.checkhost)=="function"then
        local ok,result=pcall(certificate.checkhost,certificate,host)
        return ok and result==true
    end
    local ok,extensions=pcall(certificate.extensions,certificate)
    if not ok or type(extensions)~="table"then return false end
    local san=extensions["2.5.29.17"]
    if san~=nil then
        if type(san)~="table" or type(san.dNSName)~="table"then return false end
        for _,name in ipairs(san.dNSName)do if matches(host,name)then return true end end
        return false
    end
    local valid,subject=pcall(certificate.subject,certificate)
    for _,field in ipairs(valid and type(subject)=="table" and subject or {})do
        if (field.oid=="2.5.4.3" or field.name=="commonName") and matches(host,field.value)then return true end
    end
    return false
end

function Transport.request(payload,deps)
    local connections,stage={},"network_error"
    local called,result,reason=pcall(function()
        deps=deps or {}
        local http=deps.http or require("socket.http")
        local socket=deps.socket or require("socket")
        local ssl=deps.ssl or require("ssl")
        local json=deps.json or require("json")
        local ltn12=deps.ltn12 or require("ltn12")
        local ca=deps.ca_file or require("datastorage"):getDataDir().."/data/ca-bundle.crt"
        if http.PROXY then return nil,"proxy_not_supported"end
        local has_ca
        if deps.read_file then has_ca=deps.read_file(ca)
        else local f=io.open(ca,"rb");if f then has_ca=true;f:close()end end
        if not has_ca then return nil,"tls_unavailable"end
        if type(payload)~="table" or payload.product~="legado-receipt-shelf" or type(payload.key)~="string"
            or #payload.key>128 or type(payload.device_id)~="string" or #payload.device_id~=64 then
            return nil,"invalid_request"
        end
        local body=json.encode(payload)
        if type(body)~="string" or #body>512 then return nil,"invalid_request"end
        local deadline=socket.gettime()+Transport.TIMEOUT
        local chunks,size,overflow,expired={},0,false,false
        local function create()
            local connection={sock=assert(socket.tcp())}
            connections[#connections+1]=connection
            function connection:close()
                if self.sock then pcall(self.sock.close,self.sock);self.sock=nil end
                return true
            end
            function connection:settimeout()
                local left=deadline-socket.gettime()
                if left<=0 then return nil,"timeout"end
                self.sock:settimeout(math.min(5,left),"b")
                return self.sock:settimeout(left,"t")
            end
            function connection:connect(host,port)
                if host~=HOST or tonumber(port)~=443 then self:close();return nil,"wrong_origin"end
                if not self:settimeout()then self:close();return nil,"timeout"end
                stage="tcp_error"
                local connected,err=self.sock:connect(host,443)
                if not connected then
                    err=tostring(err):lower()
                    if err=="timeout"then stage="tcp_timeout"
                    elseif err:find("host not found",1,true) or err:find("name resolution",1,true)
                        or err:find("name or service not known",1,true) or err:find("nodename nor servname",1,true)
                        or err:find("no address associated",1,true)then stage="dns_error"
                    elseif err:find("network is unreachable",1,true) or err:find("network unreachable",1,true)
                        or err:find("network is down",1,true)then stage="offline"end
                    self:close();return nil,stage
                end
                stage="tls_error"
                local wrapped=ssl.wrap(self.sock,{mode="client",protocol="any",verify="peer",cafile=ca,
                    options={"all","no_sslv2","no_sslv3","no_tlsv1","no_tlsv1_1"}})
                if not wrapped then self:close();return nil,"tls_error"end
                self.sock=wrapped
                if not self:settimeout()then self:close();return nil,"timeout"end
                if not self.sock.sni then self:close();return nil,"tls_error"end
                self.sock:sni(HOST)
                local secured,ssl_reason=self.sock:dohandshake()
                if not secured and ssl_reason=="timeout"then stage="tls_timeout";self:close();return nil,stage end
                if not secured or not Transport.certificateMatches(self.sock:getpeercertificate(),HOST)then
                    self:close();return nil,"tls_error"
                end
                stage="network_error"
                return 1
            end
            return setmetatable(connection,{__index=function(self,name)
                local sock=rawget(self,"sock")
                local method=sock and sock[name]
                if type(method)=="function"then return function(_, ...)
                    if not self:settimeout()then return nil,"timeout"end
                    return method(self.sock,...)
                end end
            end})
        end
        local received,code=http.request{url=Transport.ENDPOINT,method="POST",redirect=false,create=create,
            headers={["Content-Type"]="application/json",["Accept"]="application/json",["Content-Length"]=#body,
                ["User-Agent"]="Legado (KOReader)"},
            source=ltn12.source.string(body),sink=function(chunk)
                if socket.gettime()>deadline then expired=true;return nil,"timeout"end
                if chunk then
                    size=size+#chunk
                    if size>8192 then overflow=true;return nil,"response_too_large"end
                    chunks[#chunks+1]=chunk
                end
                return 1
            end}
        if overflow then return nil,"response_too_large"end
        if expired or socket.gettime()>deadline then
            return nil,stage=="tls_timeout" and "tls_timeout" or stage=="tcp_timeout" and "tcp_timeout" or "timeout"
        end
        if not received then return nil,code=="timeout" and "timeout" or stage end
        code=tonumber(code)
        if not code then return nil,"network_error"end
        if code>=300 and code<400 then return nil,"redirect_refused"end
        if code~=200 and (code<400 or code>=500)then return nil,"server_error"end
        local decoded_ok,decoded=pcall(json.decode,table.concat(chunks))
        if not decoded_ok then return nil,"invalid_response"end
        if type(decoded)~="table" or code~=200 and decoded.ok~=false then return nil,"invalid_response"end
        return decoded
    end)
    for _,connection in ipairs(connections)do connection:close()end
    if not called then return nil,stage end
    return result,reason
end
return Transport
