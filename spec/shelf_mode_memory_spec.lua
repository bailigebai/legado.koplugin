require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local Settings=require('legado.lib.settings')
local Json=require('legado.lib.json_codec')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local files,fail_write={},false
local fs={read=function(_,path)
    if files[path] then return files[path] end
    return nil,{code='STORAGE_ERROR',details={reason='missing'}}
end,atomicWrite=function(_,path,bytes)
    if fail_write then return nil,{code='STORAGE_ERROR'} end
    files[path]=bytes;return true
end}
local shown={}
local function create()
    local settings,err=Settings.new(nil,{data_dir='shelf-memory-fixture',fs=fs})
    eq(nil,err,'persisted shelf selection is a valid settings file')
    local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,close=function() end},
        menu={new=function(_,options) return options end},
        info_message={new=function(_,options) return options end}}
    local app=App.new{settings=settings,storage={listShelf=function() return {} end,listProgress=function() return {} end},
        local_library={scan=function() return {} end,directories=function() return {} end},
        weread_auth={hasSession=function() return true end,session=function() return {vid='account'} end},
        fs={readBounded=function() return Json.encode{account_id='account',books={},read_time_schema=2} end},
        weread_shelf_path='fixture-shelf.json',show=function(view) return presenter:show(view) end}
    presenter.app=app
    return app,presenter,settings
end
local function last() return shown[#shown] end
local function choose(index)
    last().header_action.callback()
    return last().items[index].callback()
end
local app,presenter,settings=create()
app:openHome()
choose(2)
eq('微信读书',last().title,'top-right choice enters WeRead')
eq('weread',settings:get('home_shelf_mode'),'top-right choice persists the default homepage shelf')
local restarted,_,restarted_settings=create()
eq('weread',restarted:openHome().kind,'reconstructed app restores WeRead after restart')
restarted:openBookshelf('sources')
eq('weread',restarted_settings:get('home_shelf_mode'),'temporary explicit source entry does not replace saved homepage')
restarted:openHome()
choose(3)
eq('本地书架',last().title,'WeRead top-right menu selects local bookshelf')
local local_app,_,local_settings=create()
eq('local',local_app:openBookshelf().source_mode,'public shelf launch restores local mode')
choose(1)
local source_app,source_presenter,source_settings=create()
eq('sources',source_app:openHome().source_mode,'selecting sources replaces remembered local mode')
source_app:openBookshelf('local')
choose(3)
eq('local',source_settings:get('home_shelf_mode'),'selecting already visible temporary local shelf remembers it')

local before=files['shelf-memory-fixture/settings/legado.json']
fail_write=true
choose(1)
eq('sources',source_presenter.library_view.source_mode,
    'failed persistence does not prevent current-run switch')
eq('书架记忆',last().title,'failed settings write is reported to the user')
eq(before,files['shelf-memory-fixture/settings/legado.json'],'failed save preserves previous settings bytes')
eq('sources',source_app:openHome().source_mode,'current run remembers choice even if persistence failed')
source_app:openSettings()
local temporary_default,failed_legacy_default
for _,item in ipairs(last().item_table) do
    if item.text:find('默认书架来源：',1,true)==1 then failed_legacy_default=item end
    if item.text=='首页书架：书源书架（仅本次运行；右上角切换）' then temporary_default=item end
end
eq(nil,failed_legacy_default,'temporary default cannot expose an ineffective legacy selector')
eq(false,temporary_default and temporary_default.enabled,'settings distinguish the temporary choice from the saved default')
fail_write=false
local after_failure=create()
eq('local',after_failure:openHome().source_mode,'restart uses last successful selection after save failure')
after_failure:openSettings()
local legacy_default,remembered_default
for _,item in ipairs(last().item_table) do
    if item.text:find('默认书架来源：',1,true)==1 then legacy_default=item end
    if item.text=='首页书架：本地书架（右上角切换）' then remembered_default=item end
end
eq(nil,legacy_default,'settings cannot expose a default that saved shelf selection would ignore')
eq(false,remembered_default and remembered_default.enabled,'settings explain the effective remembered homepage')
source_app:openHome()
choose(1)
source_app:openSettings()
local retried_default
for _,item in ipairs(last().item_table) do
    if item.text=='首页书架：书源书架（右上角切换）' then retried_default=item end
end
eq(false,retried_default and retried_default.enabled,'successful retry clears the temporary default warning')
eq('sources',create():openHome().source_mode,'successful retry persists across restart')

local invalid=Json.decode(files['shelf-memory-fixture/settings/legado.json'])
invalid.settings.home_shelf_mode='unknown-shelf'
files['shelf-memory-fixture/settings/legado.json']=Json.encode(invalid)
local recovered,recovery_error=Settings.new(nil,{data_dir='shelf-memory-fixture',fs=fs})
eq('RECOVERY_REQUIRED',recovery_error and recovery_error.code,'invalid persisted mode cannot enter a broken page')
eq('sources',App.new{settings=recovered,storage={listShelf=function() return {} end}}:openHome().source_mode,
    'invalid mode uses safe default while existing recovery protects file')

files={}
local mixed_app,mixed_presenter,mixed_settings=create()
mixed_settings:set('shelf_source','mixed')
mixed_app.storage.listShelf=function() return {{id='source',name='书源书'}} end
mixed_app.local_library.scan=function() return {{id='local',name='本地书',is_local=true}} end
eq('mixed',mixed_app:openHome().source_mode,'unselected homepage retains the original mixed setting')
eq(2,#last().items,'mixed homepage starts with both kinds of books')
choose(1)
eq('sources',mixed_presenter.library_view.source_mode,'choosing sources must immediately leave mixed mode')
eq(1,#last().items,'visible shelf matches the mode that was saved')
eq('sources',create():openHome().source_mode,'restart uses the same type as the selected visible shelf')
return count
