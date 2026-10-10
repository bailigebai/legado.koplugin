local A=require('assertions')
local Json=require('legado.lib.json_codec')
local AI=require('legado.lib.ai_service')
local Settings=require('legado.lib.settings')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local files,values,requests={}, {ai_provider='deepseek'}, {}
local fail_write,fail_save=false,false
local fs={readBounded=function(_,p) return files[p] end,
    atomicWrite=function(_,p,raw) if fail_write then return nil end;files[p]=raw;return true end}
local settings={get=function(_,k) return values[k] end,
    set=function(_,k,v) if fail_save then return nil end;values[k]=v;return v end}
local service=AI.new{fs=fs,settings=settings,key_dir='/private/ai-keys',requests={execute=function(_,spec,done)
    requests[#requests+1]=spec;return {cancel=function() end}
end}}
eq(true,service:setManualKey('deepseek','  secret-one  '),'manual key is accepted and activated')
eq('/private/ai-keys/deepseek.json',values.ai_deepseek_key_file,'only private path is saved in settings')
eq('secret-one',Json.decode(files[values.ai_deepseek_key_file]).api_key,'manual key is trimmed in a separate private JSON')
eq(false,Json.encode(values):find('secret-one',1,true)~=nil,'settings never contain the raw secret')
eq('manual',service:keySource('deepseek'),'manual source is identifiable without displaying the key')
eq(true,service:setManualKey('mimo','secret-two'),'second provider has its own key')
eq('secret-one',service:_key('deepseek'),'saving MiMo does not replace DeepSeek key')
eq(nil,service:setManualKey('deepseek','invalid key'),'internal whitespace is rejected')
fail_write=true
eq(nil,service:setManualKey('deepseek','new-secret'),'private write failure is visible')
eq('secret-one',service:_key('deepseek'),'failed write keeps the working key')
fail_write=false
files['import.json']=Json.encode{api_key='imported-key'}
eq(true,service:setKeyFile('deepseek','import.json'),'JSON import remains supported')
eq('file',service:keySource('deepseek'),'import source is identifiable')
fail_save=true
eq(nil,service:setManualKey('deepseek','unused-secret'),'activation failure is reported')
eq('imported-key',service:_key('deepseek'),'activation failure keeps imported key active')
fail_save=false
settings.recovery_required=true
eq(nil,service:setManualKey('deepseek','locked-secret'),'settings recovery lock prevents key changes')
eq('unused-secret',Json.decode(files['/private/ai-keys/deepseek.json']).api_key,'recovery lock writes no new secret')
settings.recovery_required=false
eq(true,service:setModel('deepseek','deepseek-v4-pro'),'common model is saved')
eq(true,service:setModel('mimo','my-model/v1:reading'),'custom model ID is supported')
eq(nil,service:setModel('mimo','bad model'),'model whitespace is rejected')
service:explain('原文保持不变','额外要求',function() end,'summary')
eq('deepseek-v4-pro',requests[1].body.model,'request uses saved provider model')
eq('原文保持不变',requests[1].body.messages[2].content,'template choice never replaces selected text')
eq(true,requests[1].body.messages[1].content:find('总结',1,true)~=nil,'selected reading template controls the system prompt')
eq(true,requests[1].body.messages[1].content:find('额外要求',1,true)~=nil,'supplement stays attached to selected template')
local err
service:explain('原文','',function(_,e) err=e end,'missing-template')
eq(1,#requests,'unknown template starts no request')
eq(true,type(err)=='string','unknown template has a useful error')
values.ai_provider='mimo'
service:testConnection(function() end)
eq('my-model/v1:reading',requests[2].body.model,'connection test also uses selected model')
eq('disabled',requests[2].body.thinking.type,'MiMo selected model preserves thinking control')
-- Use the production atomic settings store to prove reload validation.
local disk={}
local diskfs={read=function(_,p)
    if disk[p]==nil then return nil,{code='STORAGE_ERROR',details={cause='No such file or directory'}} end
    return disk[p]
end,atomicWrite=function(_,p,r) disk[p]=r;return true end}
local persisted=Settings.new(nil,{data_dir='config-spec',fs=diskfs})
eq('deepseek-v4-pro',persisted:set('ai_deepseek_model','deepseek-v4-pro'),'model saves through strict settings store')
persisted:set('ai_mimo_model','mimo-v2.6-flash')
local restarted,reload_error=Settings.new(nil,{data_dir='config-spec',fs=diskfs})
eq(nil,reload_error,'saved models pass JSON validation after restart')
eq('mimo-v2.6-flash',restarted:get('ai_mimo_model'),'MiMo model survives restart')
eq('deepseek-v4-pro',restarted:get('ai_deepseek_model'),'DeepSeek model survives restart independently')
return n
