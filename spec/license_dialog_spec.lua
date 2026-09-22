local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local shown,callbacks,attempts,cancels,continued={}, {},0,0,0
local authorized=false
local license={isAuthorized=function()return authorized end,
    normalizeKey=require('legado.lib.license').normalizeKey,
    activate=function()error('UI must not use synchronous activation')end,
    activateAsync=function(_,_,callback)
        attempts=attempts+1;callbacks[#callbacks+1]=callback
        return {cancel=function()cancels=cancels+1 end}
    end}
local ctor={new=function(_,opts)
    opts.getInputText=function()return 'ABCD-EFGH-JKMN'end
    opts.onCloseWidget=function(self)self.freed=(self.freed or 0)+1 end
    return opts
end}
local p=Presenter.new{app={license=license},menu=ctor,info_message=ctor,input_dialog=ctor,
    ui_manager={show=function(_,w)shown[#shown+1]=w end,close=function(_,w)if w.onCloseWidget then w:onCloseWidget()end end}}
local function open()p:showLicenseDialog(function()continued=continued+1 end);return shown[#shown]end
local dialog=open();dialog.buttons[1][2].callback();dialog.buttons[1][2].callback()
eq(1,attempts,'repeated click starts one async activation')
local busy=shown[#shown];p.ui_manager:close(busy)
eq(1,cancels,'tapping visible waiting message cancels request')
eq(1,busy.freed,'native close frees waiting widget exactly once')
callbacks[1](true);eq(0,continued,'dismissed wait ignores late success')
dialog.buttons[1][2].callback();dialog:onSuspend()
eq(2,cancels,'suspend cancels active request')
callbacks[2](true);eq(0,continued,'suspend ignores late response')
dialog.buttons[1][2].callback();dialog:onCloseWidget()
eq(3,cancels,'dialog close cancels active request')
local before=#shown;callbacks[3](nil,'dns_error');eq(before,#shown,'closed page cannot reopen failure UI')

dialog=open();dialog.buttons[1][2].callback();callbacks[4](nil,'tls_error')
eq('授权失败',shown[#shown].title,'TLS error shown in foreground')
eq(true,shown[#shown].text:find('安全连接',1,true)~=nil,'TLS failure distinguished')
dialog.buttons[1][2].callback();authorized=true;callbacks[5](true)
eq(1,continued,'successful parent persistence continues original action once')
callbacks[5](true);eq(1,continued,'duplicate result never continues twice')
eq(3,cancels,'successful completion does not call active cancellation')
return n
