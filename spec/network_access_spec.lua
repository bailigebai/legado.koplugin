local A = require('assertions')
local Access = require('legado.lib.network_access')
local n = 0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local calls, ready, connected, wifi = 0, nil, false, false
local manager = {
    runWhenConnected=function(_,callback) calls=calls+1;ready=callback end,
    isConnected=function() return connected end,
    isWifiOn=function() return wifi end,
    turnOffWifi=function() error('must not disable wifi') end,
    afterWifiAction=function() error('must not alter user power preferences') end,
}
eq(0,calls,'loading network helper leaves wifi alone')
local results = {}
local function done(ok,reason) results[#results+1]={ok,reason} end
local first=Access.run(manager,done)
eq(1,calls,'explicit operation asks native network manager once')
first:cancel();connected=true;ready();ready()
eq(0,#results,'cancelled native connection callbacks cannot start a request')
Access.run(manager,done);ready();ready()
eq(1,#results,'duplicate connection callback is accepted once')
eq(true,results[1][1],'connected native callback proceeds')
connected=false;Access.run(manager,done);ready()
eq('wifi_off',results[2][2],'wireless off is distinct')
wifi=true;Access.run(manager,done);ready()
eq('offline',results[3][2],'wireless enabled without connection is distinct')
Access.run(nil,done)
eq('network_unavailable',results[4][2],'missing native API fails closed')
manager.runWhenConnected=function() error('native failure') end
Access.run(manager,done)
eq('offline',results[5][2],'native network failures remain safe')
return n
