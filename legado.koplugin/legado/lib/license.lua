local License={}
License.__index=License
License.RECEIPT_KEY="license_receipt"
License.INSTALLATION_KEY="license_installation_id"
local function plain(v)return type(v)=="table" and getmetatable(v)==nil end
local function hex(v)return type(v)=="string" and #v==64 and not v:find("[^0-9a-f]") end
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out
end
local function same(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~="table"then return a==b end
    for k,v in pairs(a)do if not same(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
function License.normalizeKey(key)
    if type(key)~="string" or #key>128 then return nil end
    key=key:match("^%s*(.-)%s*$"):upper()
    local compact=key
    if #key==14 and key:sub(5,5)=="-" and key:sub(10,10)=="-" then
        compact=key:sub(1,4)..key:sub(6,9)..key:sub(11,14)
    end
    if #compact==12 and not compact:find("[^2-9A-HJKMNP-Z]")then
        return compact:sub(1,4).."-"..compact:sub(5,8).."-"..compact:sub(9,12)
    end
    return nil
end
function License.new(options)
    options=options or {}
    return setmetatable({store=options.store,request=options.request,verify=options.verify,
        device_id=options.device_id,activation_options=options.activation_options},License)
end
function License:_read(key)
    if not self.store or type(self.store.readSetting)~="function" then return nil,"storage_unavailable" end
    local ok,value=pcall(self.store.readSetting,self.store,key)
    if not ok then return nil,"storage_unavailable" end
    return value
end
function License:_persist(key,value)
    local old,reason=self:_read(key)
    if reason then return nil,"save_failed" end
    local ok=pcall(function()
        assert(self.store:saveSetting(key,copy(value))~=false)
        assert(self.store:flush()~=false)
        local written=self.store:readSetting(key)
        if self.store.file then
            local root=dofile(self.store.file)
            assert(type(root)=="table");written=root[key]
        end
        assert(same(value,written))
    end)
    if not ok then
        -- A failed flush must not leave an unconfirmed receipt in LuaSettings.data.
        pcall(self.store.saveSetting,self.store,key,old)
        if type(self.store.restoreSetting)=="function" then pcall(self.store.restoreSetting,self.store,key,old) end
        if type(self.store.data)=="table"then self.store.data[key]=old end
        -- Readback may fail after a successful write; restore disk best-effort too.
        pcall(self.store.flush,self.store)
        return nil,"save_failed"
    end
    return true
end
function License:_deviceId(create)
    if self.device_id~=nil then
        local value=self.device_id
        if type(value)=="function"then
            local ok,result=pcall(value);value=ok and result or nil
        end
        return hex(value) and value or nil,"invalid_device_id"
    end
    local Crypto=require("legado.lib.license_crypto")
    local id,reason=Crypto.hardwareId()
    if id then return id end
    if reason~="no_hardware_id"then return nil,reason end
    local saved,read_error=self:_read(License.INSTALLATION_KEY)
    if read_error then return nil,read_error end
    if saved~=nil then return hex(saved) and saved or nil,"invalid_device_id" end
    if not create then return nil,"no_device_id" end
    id,reason=Crypto.randomId()
    if not id then return nil,reason end
    local written;written,reason=self:_persist(License.INSTALLATION_KEY,id)
    if not written then return nil,reason end
    return id
end
local receipt_fields={version=true,product=true,device_id=true,key_id=true,issued_at=true,signature=true}
function License:_validate(receipt,id)
    if not plain(receipt) then return nil,"invalid_receipt" end
    for k in pairs(receipt)do if not receipt_fields[k]then return nil,"invalid_receipt" end end
    if receipt.version~=1 or receipt.product~="legado-receipt-shelf" or not hex(receipt.device_id)
        or not hex(receipt.key_id) or type(receipt.issued_at)~="number" or receipt.issued_at<1
        or receipt.issued_at>9007199254740991 or receipt.issued_at%1~=0
        or not require("legado.lib.license_crypto").validSignature(receipt.signature) then return nil,"invalid_receipt" end
    if receipt.device_id~=id then return nil,"wrong_device" end
    local message="LEGADO-RECEIPT-SHELF-LICENSE-1\n"..id.."\n"..receipt.key_id.."\n"..("%.0f"):format(receipt.issued_at)
    local verify=self.verify or require("legado.lib.license_crypto").verify
    local ok,valid=pcall(verify,message,receipt.signature)
    if not ok or valid~=true then return nil,"invalid_signature" end
    return true
end
function License:isAuthorized()
    local receipt=self:_read(License.RECEIPT_KEY)
    if receipt==nil then return false end
    local id=self:_deviceId(false)
    return id~=nil and self:_validate(receipt,id)==true
end
function License:prepareActivation(key)
    key=License.normalizeKey(key)
    if not key then return nil,"invalid_key" end
    if self.activating then return nil,"activation_busy" end
    local id,reason=self:_deviceId(true)
    if not id then return nil,reason end
    return {product="legado-receipt-shelf",key=key,device_id=id}
end
function License:acceptActivation(response,id,request_error)
    if not response then return nil,request_error or "network_error" end
    if not plain(response)then return nil,"invalid_response" end
    if response.ok~=true then
        local reasons={invalid_key=true,key_not_found=true,bound_to_other_device=true,wrong_device=true,rate_limited=true}
        local code=response.error or response.reason
        return nil,reasons[code] and code or "activation_rejected"
    end
    for k in pairs(response)do if k~="ok" and k~="receipt"then return nil,"invalid_response"end end
    local valid,reason=self:_validate(response.receipt,id)
    if not valid then return nil,reason end
    return self:_persist(License.RECEIPT_KEY,response.receipt)
end
function License:activate(key)
    local payload,reason=self:prepareActivation(key)
    if not payload then return nil,reason end
    local request=self.request or require("legado.lib.license_transport").request
    self.activating=true
    local ok,response,request_error=pcall(request,payload)
    self.activating=nil
    if not ok then return nil,"network_error" end
    return self:acceptActivation(response,payload.device_id,request_error)
end
function License:activateAsync(key,callback)
    return require("legado.lib.license_activation").start(self,key,callback,self.activation_options)
end
return License
