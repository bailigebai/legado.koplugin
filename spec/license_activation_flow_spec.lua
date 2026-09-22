local A=require('assertions')
local License=require('legado.lib.license')
local Wire=require('legado.lib.wire_codec')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local function fixture()
    local f={queue={},results={},values={},forks=0,requests=0,closed=0,killed=0,holds=0,verifies=0}
    f.scheduler={scheduleIn=function(_,delay,fn) f.queue[#f.queue+1]={delay=delay,fn=fn} end,
        unschedule=function(_,fn) for i=#f.queue,1,-1 do if f.queue[i].fn==fn then table.remove(f.queue,i) end end end}
    function f:tick(delay)
        for i,item in ipairs(self.queue) do if item.delay==delay then table.remove(self.queue,i);item.fn();return true end end
        error('missing scheduled delay '..tostring(delay))
    end
    f.network={runWhenConnected=function(_,cb) f.ready=cb end,isConnected=function() return true end,isWifiOn=function()return true end}
    f.worker={available=function()return true end,
        start=function(_,job)f.forks=f.forks+1;f.job=job;f.child={};return f.child end,
        poll=function()return f.done,f.payload,f.poll_error end,
        terminate=function()f.killed=f.killed+1 end,
        reap=function()return true end,close=function()f.closed=f.closed+1 end}
    f.guard={acquire=function()f.holds=f.holds+1;return true end,release=function()f.holds=f.holds-1 end}
    f.store={readSetting=function(_,k)return f.values[k] end,
        saveSetting=function(_,k,v)f.values[k]=v;return true end,flush=function()return not f.save_failure end}
    f.license=License.new{store=f.store,device_id=string.rep('b',64),
        request=function(payload)
            f.requests=f.requests+1
            eq(true,f.in_child,'HTTPS executes only in the worker')
            return {ok=true,receipt={version=1,product=payload.product,device_id=payload.device_id,
                key_id=string.rep('a',64),issued_at=1700000000,signature=string.rep('A',342)..'=='}}
        end,
        verify=function()eq(false,f.in_child==true,'signature verified in parent');f.verifies=f.verifies+1;return not f.bad_signature end,
        activation_options={scheduler=f.scheduler,network_manager=f.network,subprocess=f.worker,standby=f.guard}}
    function f:start(key)
        return self.license:activateAsync(key or 'ABCD-EFGH-JKMN',function(ok,reason)self.results[#self.results+1]={ok,reason}end)
    end
    function f:connect()self:tick(0);self.ready()end
    function f:respond()
        self.in_child=true;local result=self.job();self.in_child=false
        eq(nil,self.values.license_receipt,'child cannot persist receipt')
        eq(0,self.verifies,'child cannot verify receipt')
        self.payload=assert(Wire.encode(result));self.done=true;self:tick(0)
    end
    return f
end
local f=fixture();local handle=f:start()
eq(0,f.requests,'activation returns without doing network I/O')
eq(1,f.holds,'network operation holds standby')
f:connect();f.ready();eq(1,f.forks,'native duplicate callback starts only one child')
f:respond();eq(true,f.results[1][1],'valid child response activates in parent')
eq(0,f.holds,'success releases standby');eq(1,f.closed,'success closes child descriptor')
eq(false,handle:cancel(),'completed handle cannot cancel twice')
local restart=License.new{store=f.store,device_id=string.rep('b',64),verify=function()return true end}
eq(true,restart:isAuthorized(),'persisted receipt remains authorized after restart without network')

f=fixture();handle=f:start();f:tick(0);local stale=f.ready;handle:cancel();stale()
eq(0,f.forks,'cancel before connecting prevents activation');eq(0,f.holds,'preflight cancel releases guard')
eq(0,#f.results,'cancel never invokes UI completion');eq(0,#f.queue,'cancel removes connection timeout')
f:start();f:connect();stale();eq(1,f.forks,'old connection callback cannot start replacement request')

f=fixture();handle=f:start();f:connect();local late_poll=f.queue[#f.queue].fn;handle:cancel();late_poll()
eq(1,f.killed,'closing active dialog terminates child');eq(1,f.closed,'cancel closes child descriptor')
eq(nil,f.values.license_receipt,'late poll cannot save cancelled response');eq(0,f.holds,'active cancel balances guard')
eq(0,#f.results,'late callback cannot reopen UI')

f=fixture();f:start();f:connect();f:tick(11)
eq('timeout',f.results[1][2],'parent deadline terminates hung child')
eq(1,f.killed,'deadline kills child');eq(0,f.holds,'timeout releases guard')
f:start();f:connect();f:respond();eq(true,f.results[2][1],'same key can retry after timeout')

f=fixture();f:start();f:tick(0);f:tick(60);f.ready()
eq('offline',f.results[1][2],'native prompt without connection reaches bounded failure')
eq(0,f.forks,'late native callback after timeout cannot consume key');eq(0,f.holds,'connection timeout releases guard')

f=fixture();f.bad_signature=true;f:start();f:connect();f:respond()
eq('invalid_signature',f.results[1][2],'invalid signature remains locked');eq(nil,f.values.license_receipt,'bad receipt is not saved')
f=fixture();f.save_failure=true;f:start();f:connect();f:respond()
eq('save_failed',f.results[1][2],'save failure reported');eq(false,f.license:isAuthorized(),'failed persistence never unlocks')

f=fixture();f.worker.available=function()return false end;f:start();f:tick(0)
eq('background_unavailable',f.results[1][2],'missing subprocess never falls back to blocking UI')
eq(0,f.requests,'unavailable background transport does not send');eq(0,f.holds,'unsupported runtime releases guard')

f=fixture();f:start('bad');eq('invalid_key',f.results[1][2],'bad key rejected before network')
eq(0,#f.queue,'invalid key schedules no work');eq(0,f.holds,'invalid key acquires no guard')
f=fixture();f:start();f:start();eq('activation_busy',f.results[1][2],'duplicate activation rejected')
eq(1,f.holds,'busy request cannot leak another guard')

f=fixture();f:start();f:connect();f.done=true;f.payload='malformed';f:tick(0)
eq('invalid_response',f.results[1][2],'invalid IPC is rejected');eq(0,f.holds,'bad IPC releases guard')
f=fixture();f.worker.start=function()error('private payload must not escape')end;f:start();f:connect()
eq('background_unavailable',f.results[1][2],'fork failure becomes safe fixed error');eq(0,f.holds,'fork failure releases guard')

f=fixture();f.worker.poll=function()error('private response must not escape')end;f:start();f:connect();f:tick(0)
eq('network_error',f.results[1][2],'poll failure is contained');eq(1,f.killed,'poll failure kills child')
eq(0,f.holds,'poll failure releases guard')
f=fixture();f.scheduler.scheduleIn=function()error('scheduler stopped')end;f:start()
eq('background_unavailable',f.results[1][2],'scheduler failure is contained');eq(0,f.holds,'schedule failure releases guard')

f=fixture();local reaps=0
f.worker.reap=function()reaps=reaps+1;return reaps>=3 end
handle=f:start();f:connect();handle:cancel();f:tick(0.1);f:tick(0.1)
eq(3,reaps,'cancel keeps reaping a killed worker until collected')
eq(1,f.closed,'delayed reaping closes pipe once');eq(0,#f.queue,'successful reaping leaves no timer')

f=fixture();f:start();f:connect();f.done=true;f.payload='T1:D3:nanN';f:tick(0)
eq('invalid_response',f.results[1][2],'malformed numeric IPC key cannot crash UI')
eq(0,f.holds,'decode exception releases guard')
return n
