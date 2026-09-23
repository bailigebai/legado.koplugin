require('library_screen_stub')
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local stack,tasks={},{}
local ui={show=function(_,w) stack[#stack+1]=w end,
    close=function(_,w)
        if w.onCloseWidget then w:onCloseWidget() end -- Real KOReader notifies before removal.
        for i=#stack,1,-1 do if stack[i]==w then table.remove(stack,i) end end
    end,
    scheduleIn=function(_,_,fn) tasks[#tasks+1]=fn end,
    getTopmostVisibleWidget=function() return stack[#stack] end,setDirty=function() end}
local function drain() while #tasks>0 do table.remove(tasks,1)() end end
local paused,resumes=false,0
local doc={backend='immersive',widget={},pauseReading=function() paused=true;return true end,
    resumeReading=function() paused=false;resumes=resumes+1;return true end}
local session={active={document=doc},ui={current_document=doc}}
local ctor={new=function(_,o) return o end}
local Presenter=require('legado.ui.presenter')
local p=Presenter.new{ui_manager=ui,menu=ctor,info_message=ctor,app={reader_session=session}}
ui:show(doc.widget)
local parent=p:_show({item_table={}})
eq(true,paused,'showing an owned overlay pauses independent reading')
local original=0
local child=p:_show({item_table={},onCloseWidget=function() original=original+1 end})
ui:close(child)
eq(0,resumes,'CloseWidget cannot resume before native stack removal')
drain();eq(1,original,'owned close preserves original cleanup')
eq(0,resumes,'closing a child leaves the parent overlay paused')
ui:close(parent);drain();eq(1,resumes,'closing the last overlay resumes visible reader once')
local first=p:_show({item_table={}})
ui:close(first);local replacement=p:_show({item_table={}});drain()
eq(1,resumes,'same-tick overlay replacement cannot resume behind the replacement')
ui:close(replacement);drain();eq(2,resumes,'replacement closing restores reading')
local stats={}
function stats:onShowTimeRange()
    local root={kv_pairs={}}
    root.kv_pairs[1]={callback=function()
        ui:close(root)
        self.kv={kv_pairs={}};ui:show(self.kv)
    end}
    self.kv=root;ui:show(root)
end
eq('table',type(p:showNativeStatistics(stats,doc)),'statistics handoff returns its native widget')
eq(true,paused,'native statistics keeps independent reading paused')
local root=stats.kv;root.kv_pairs[1].callback();drain()
eq(2,resumes,'replacing the root statistics page with a native child cannot resume early')
ui:close(stats.kv);drain();eq(3,resumes,'closing the final native statistics child resumes reading')
local stale=p:_show({item_table={}});doc.closed=true;ui:close(stale);drain()
eq(3,resumes,'old overlay cannot resume a reader closed during mode switch')
local mode=true
local view=require('legado.ui.settings').new{settings={all=function() return {immersive_reader=mode} end,
    set=function(_,key,value) eq('immersive_reader',key,'shelf settings save the reader-mode preference');mode=value;return value end}}
local widget=p:_settings(view)
local toggle
for _,item in ipairs(widget.item_table) do if item.text:find('无感阅读',1,true) then toggle=item end end
eq('table',type(toggle),'shelf settings describe the default reading mode')
eq(false,toggle.enabled,'shelf does not offer a persisted toggle overridden by new-entry default')
eq(nil,toggle.callback,'only the active reader offers a session mode toggle')
view.document={backend='immersive'};view.values.immersive_reader=false
local switches=0;view.on_toggle_reader=function() switches=switches+1 end
widget=p:_settings(view)
for _,item in ipairs(widget.item_table) do if item.text:find('无感阅读',1,true) then toggle=item end end
eq('无感阅读（本次）：开启',toggle.text,'settings show actual backend even if old persisted preference is false')
toggle.callback();eq(1,switches,'current reading mode can still be switched')
doc.closed=false;doc.pauseReading=function() return nil,{code='STORAGE_ERROR'} end
local error_info=p:_info('保存失败。')
eq(error_info,ui:getTopmostVisibleWidget(),'save failure information remains visible when pausing itself fails')
local before=resumes;ui:close(error_info);drain()
eq(before,resumes,'failed pause does not manufacture a resume callback')
doc.closed=true
package.loaded['ui/widget/confirmbox']=ctor
session.close=function() return nil,{code='STORAGE_ERROR'} end
local left=0;p._leaveLibrary=function() left=left+1 end
p:_confirmExit();p.exit_dialog.ok_callback()
eq(0,left,'failed session save prevents leaving the plugin through its exit confirmation')
return n
