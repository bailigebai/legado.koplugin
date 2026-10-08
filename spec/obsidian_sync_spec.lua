local A=require('assertions')
local Json=require('legado.lib.json_codec')
local Storage=require('legado.lib.storage')
local Client=require('legado.lib.obsidian_client')
local Service=require('legado.lib.excerpt_service')
local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local files={['config.json']=Json.encode{endpoint='https://192.168.1.2:27124',api_key='private-token',
 certificate_sha256=string.rep('a',64),ca_file='obsidian-ca.pem',folder='阅读摘录/不亦阅乎'},['obsidian-ca.pem']='-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----'}
local fail=false
local fs={read=function(_,p) return files[p] end,readBounded=function(_,p,max)
 local data=files[p];return data and #data<=max and data or nil end,atomicWrite=function(_,p,v)
 if fail then return nil,{code='STORAGE_ERROR'} end;files[p]=v;return true end}
local values={obsidian_config_file='config.json'}
local settings={get=function(_,k) return values[k] end,set=function(_,k,v) values[k]=v;return v end}
local pending={}
local requests={execute=function(_,req,cb) local r={req=req,cb=cb};pending[#pending+1]=r;return {cancel=function() r.cancelled=true end} end}
local client=Client.new{fs=fs,settings=settings,requests=requests}
local config=client:config()
eq('https://192.168.1.2:27124',config.endpoint,'explicit HTTPS server accepted')
eq('obsidian-ca.pem',config.ca_file,'CA file resolves beside connection JSON')
eq(nil,Client.validate{endpoint='http://192.168.1.2:27123'},'cleartext credentials disallowed')
eq(nil,Client.validate{endpoint='https://name:27124/?key=secret'},'URL query/userinfo disallowed')
local store=Storage.new{path='storage',fs=fs,sqlite_loader=function() return nil end}
local jobs={}
local scheduler={scheduleIn=function(_,delay,job) jobs[#jobs+1]=job end}
local service=Service.new{storage=store,client=client,scheduler=scheduler,now=function() return '2026-10-08T12:00:00+0800' end}
local input={quote='优秀句子',book_key='b1',title='书名',author='作者',source='书源',chapter='第一章',location='段落 3'}
local saved=service:capture(input)
eq('pending',saved.status,'local quote is saved before network IO')
eq(0,#pending,'capture does not start blocking network IO')
eq(1,#jobs,'capture schedules background synchronization')
local duplicate=service:capture(input)
eq(saved.id,duplicate.id,'repeated capture deduplicates same location and text')
eq(1,#store:listExcerpts(),'double click does not duplicate local records')
table.remove(jobs,1)()
eq('GET',pending[1].req.method,'sync checks existing note before upload')
eq(0,pending[1].req.max_redirects,'credentials never follow redirects')
eq(string.rep('a',64),pending[1].req.tls_pin_sha256,'TLS verifies pinned receiving server')
eq('Bearer private-token',pending[1].req.headers.Authorization,'token carried only in header')
local largest={id='excerpt-largest',quote=string.rep('&',65536),title='边界',book_key='boundary'}
eq(true,pending[1].req.max_bytes>=#require('legado.lib.excerpt_markdown').render(largest)+512*1024,
 'recovery GET can read the largest escaped quote and annotation space')
pending[1].cb(nil,{details={status=404}})
eq('PUT',pending[2].req.method,'missing note is created')
eq(true,pending[2].req.body:find(saved.quote,1,true)~=nil,'selected quotation is uploaded')
pending[2].cb(nil,{code='TIMEOUT'})
eq('pending',store:getExcerpt(saved.id).status,'lost upload response keeps retry queue')
eq(false,service.busy,'network failure releases service so reader remains usable')
local restarted=Service.new{storage=store,client=client,scheduler=scheduler}
restarted:sync()
pending[3].cb({status=200,body='<!-- legado-excerpt:'..saved.id..' -->\n我已修改自己的笔记'})
eq(3,#pending,'retry recognizes existing note and never overwrites user annotations')
eq('synced',store:getExcerpt(saved.id).status,'already arrived quote becomes synced')
local next_input={quote='第二句',book_key='b1',title='书名',source='书源',chapter='第一章',location='段落 4'}
local next_row=service:capture(next_input)
service:sync();pending[4].cb({status=200,body='other personal note'})
eq('pending',store:getExcerpt(next_row.id).status,'conflicting personal note preserved')
eq(4,#pending,'conflict never triggers PUT')
eq(true,service.last_error:find('同名',1,true)~=nil,'conflict explained')
local original=files['config.json'];local changed=Json.decode(original);changed.endpoint='https://192.168.1.3:27124';files['config.json']=Json.encode(changed)
service:sync()
eq(4,#pending,'queued notes are not silently sent to a changed destination')
files['config.json']=original
fail=true
eq(nil,service:capture{quote='不能保存',book_key='b1',title='书名',source='书源',location='段落 5'},'storage failure is not reported as captured')
eq(2,#store:listExcerpts(),'failed capture does not leak in-memory state')
fail=false
jobs={};pending={}
local stream_store=Storage.new{path='streaming',fs=fs,sqlite_loader=function() return nil end}
local streaming=Service.new{storage=stream_store,client=client,scheduler=scheduler}
local first=streaming:capture{quote='第一条新摘录',book_key='b2',title='新书',chapter='章',location='1'}
streaming:sync()
local request_number=#pending
streaming:capture{quote='同步中的另一条',book_key='b2',title='新书',chapter='章',location='2'}
-- Simulate an existing note reaching the server, then drain the scheduled queue.
pending[request_number].cb({status=200,body='<!-- legado-excerpt:'..first.id..' -->'})
for _=1,20 do local job=table.remove(jobs,1);if not job then break end;job() end
eq(true,#pending>request_number,'capture during a sync starts a subsequent batch automatically')
return n
