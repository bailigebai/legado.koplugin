local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local License=require('legado.lib.license')
eq('ABCD-EFGH-JKMN',License.normalizeKey(' abcd-efgh-jkmn '),'short key normalization')
eq('AB22-EFGH-JKMN',License.normalizeKey('ab22efghjkmn'),'key without hyphens is normalized')
eq(nil,License.normalizeKey('0000-AAAA-AAAA'),'zero is rejected')
local values={license_receipt=nil,license_installation_id=nil}
local store={readSetting=function(_,key)return values[key] end,saveSetting=function(_,key,value)values[key]=value;return true end,flush=function()return true end}
local request=function(payload)
    eq('legado-receipt-shelf',payload.product,'activation uses independent product id')
    return {ok=true,receipt={version=1,product='legado-receipt-shelf',device_id=payload.device_id,
        key_id=string.rep('a',64),issued_at=1700000000,signature=string.rep('A',342)..'=='}}
end
local l=License.new{store=store,device_id=string.rep('b',64),request=request,verify=function()return true end}
eq(false,l:isAuthorized(),'receipt is locked before activation')
local activated,reason=l:activate('ABCD-EFGH-JKMN');eq(true,activated,'valid short key activates');eq(nil,reason,'activation has no error')
eq(true,l:isAuthorized(),'signed receipt works offline')
local blocked=License.new{store=store,device_id=string.rep('c',64),verify=function()return true end}
eq(false,blocked:isAuthorized(),'receipt is bound to one device')
-- Exercise the production JSON settings adapter, including a write which lies
-- about success. Activation must confirm the disk value before unlocking.
local Settings=require('legado.lib.settings')
local Store=require('legado.lib.license_store')
local Json=require('legado.lib.json_codec')
for _,preexisting in ipairs{false,true}do
for _,mode in ipairs{'ok','dropped','corrupt','error','rollback_failed'}do
    local disk,active_mode,active_writes=nil,'ok',0
    local fs={read=function()
        if active_mode=='error' or active_mode=='rollback_failed' then error('read failure')end
        return disk or nil,{details={reason='missing'}}
    end,atomicWrite=function(_,_,bytes)
        if active_mode=='rollback_failed' then
            active_writes=active_writes+1
            if active_writes>1 then return nil,{code='STORAGE_ERROR'}end
            disk=bytes
        end
        if active_mode=='ok' then disk=bytes end
        if active_mode=='corrupt' then disk='broken JSON'end
        return true
    end}
    local settings=Settings.new(nil,{data_dir='license-test',fs=fs})
    settings:set('prefetch',7)
    if preexisting then
        local previous=request{product='legado-receipt-shelf',device_id=string.rep('b',64)}.receipt
        previous.key_id=string.rep('c',64)
        settings:set('license_receipt',Json.encode(previous))
    end
    active_mode=mode
    local auth=License.new{store=Store.new(settings),device_id=string.rep('b',64),request=request,verify=function()return true end}
    local saved,why=auth:activate('ABCD-EFGH-JKMN')
    eq(mode=='ok' and true or nil,saved,'activation confirms durable settings: '..mode)
    if mode=='ok' then eq(nil,why,'successful readback has no error')
    else eq('save_failed',why,'readback errors fail closed: '..mode)end
    eq(mode=='ok' or preexisting,auth:isAuthorized(),'readback failure restores previous authorization: '..mode)
    local cached=Store.new(settings):readSetting('license_receipt')
    eq(mode=='ok' and string.rep('a',64) or preexisting and string.rep('c',64) or nil,
        cached and cached.key_id,'failed activation does not replace the previous receipt')
    eq(7,settings:get('prefetch'),'unrelated setting survives activation failure')
    if mode=='ok' then
        local restarted=Settings.new(nil,{data_dir='license-test',fs=fs})
        local offline=License.new{store=Store.new(restarted),device_id=string.rep('b',64),verify=function()return true end,
            request=function()error('offline check must not request')end}
        eq(true,offline:isAuthorized(),'receipt survives JSON reload without network')
        eq(7,Json.decode(disk).settings.prefetch,'disk retains unrelated settings')
    end
end
end

-- Kindle-like filesystems may allow the initial settings file creation but
-- reject replacing an existing file. License persistence must not be coupled
-- to that replacement path: keep a dedicated receipt file in the same
-- settings directory and verify it survives a fresh Settings instance.
do
    local files = {}
    local settings_path = 'kindle-root/settings/legado.json'
    local license_path = 'kindle-root/settings/legado-license.json'
    local kindle_fs = {}
    function kindle_fs:read(path)
        local value = files[path]
        if value == nil then return nil, {code='STORAGE_ERROR', details={reason='missing'}} end
        return value
    end
    function kindle_fs:atomicWrite(path, bytes)
        if path == settings_path and files[path] ~= nil then
            return nil, {code='STORAGE_ERROR', message='existing file replacement unsupported'}
        end
        files[path] = bytes
        return true
    end
    local kindle_settings = Settings.new(nil, {data_dir='kindle-root', fs=kindle_fs})
    local kindle_store = Store.new(kindle_settings)
    local kindle_license = License.new{store=kindle_store,device_id=string.rep('d',64),request=request,verify=function()return true end}
    local kindle_saved, kindle_reason = kindle_license:activate('ABCD-EFGH-JKMN')
    eq(true,kindle_saved,'authorization falls back when Kindle cannot replace settings')
    eq(nil,kindle_reason,'dedicated receipt persistence has no error')
    eq(true,files[license_path] ~= nil,'dedicated license file is created')
    local restarted_settings = Settings.new(nil,{data_dir='kindle-root',fs=kindle_fs})
    local restarted_license = License.new{store=Store.new(restarted_settings),device_id=string.rep('d',64),verify=function()return true end}
    eq(true,restarted_license:isAuthorized(),'dedicated receipt supports offline restart verification')
end

return n
