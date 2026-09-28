require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local App=require('legado.ui.app')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
package.loaded['ui/widget/confirmbox']={new=function(_,options) return options end}
local shown,removed={},false
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,
    close=function() end},menu={new=function(_,options) return options end},
    info_message={new=function(_,options) return options end}}
local usage={bytes=10485760,files=10,reading={bytes=1048576,files=2},
    offline={bytes=7340032,files=6},covers={bytes=2097152,files=2}}
local view={plugin_cache_usage=function() return usage end,
    plugin_cache_clear=function() removed=true;return {removed=9} end}
local page=presenter:_cacheSettings(view)
eq('全部插件缓存：10.0 MiB（10 个文件）',page.item_table[1].text,'total plugin cache is visible')
eq('离线章节缓存：7.0 MiB（6 个文件）',page.item_table[3].text,'offline chapter cache is separate')
page.item_table[5].callback()
eq(false,removed,'cache is untouched until explicit confirmation')
shown[#shown].ok_callback()
eq(true,removed,'confirmation starts cache cleanup')
local task={status='cancelling'}
local plugin_clears,reading_clears,policy_cleans=0,0,0
local app=App.new{storage={listDownloadTasks=function() return {task} end},
    settings={all=function() return {} end,get=function(_,key)
        return ({cache_limit_mb=500,cache_cleanup_threshold_mb=300,cache_retain_mb=200})[key]
    end},
    cache_management={clear=function() plugin_clears=plugin_clears+1;return {removed=0} end},
    reader_session={cache={clear=function() reading_clears=reading_clears+1;return 0 end,
        enforceLimit=function() policy_cleans=policy_cleans+1;return {removed=0,bytes=0} end}}}
local settings_view=app:openSettings()
local plugin_result,plugin_error=settings_view.plugin_cache_clear()
eq(nil,plugin_result,'plugin cache cannot clear while cancellation is still in progress')
eq('DOWNLOAD_ACTIVE',plugin_error.code,'cancelling download is reported as active')
local reading_result,reading_error=settings_view.clear_cache()
eq(nil,reading_result,'reading cache cannot clear while cancellation is still in progress')
eq('DOWNLOAD_ACTIVE',reading_error.code,'reading cache sees the same active download')
local policy_result,policy_error=settings_view.cache_cleanup()
eq(nil,policy_result,'policy cleanup cannot run while cancellation is still in progress')
eq('DOWNLOAD_ACTIVE',policy_error.code,'policy cleanup sees the same active download')
eq(0,plugin_clears+reading_clears+policy_cleans,'no cache is touched during cancellation')
task.status='cancelled'
eq(0,settings_view.plugin_cache_clear().removed,'plugin cache can clear after cancellation finishes')
eq(0,settings_view.clear_cache(),'reading cache can clear after cancellation finishes')
eq(0,settings_view.cache_cleanup().removed,'policy cleanup can run after cancellation finishes')
app.storage.listDownloadTasks=function() return nil,{code='STORAGE_ERROR',message='下载任务读取失败'} end
local failed_plugin,plugin_list_error=settings_view.plugin_cache_clear()
eq(nil,failed_plugin,'plugin cache stays intact when download tasks cannot be read')
eq('STORAGE_ERROR',plugin_list_error.code,'plugin cache exposes the download listing error')
local failed_reading,reading_list_error=settings_view.clear_cache()
eq(nil,failed_reading,'reading cache stays intact when download tasks cannot be read')
eq('STORAGE_ERROR',reading_list_error.code,'reading cache exposes the download listing error')
local failed_policy,policy_list_error=settings_view.cache_cleanup()
eq(nil,failed_policy,'policy cleanup stays intact when download tasks cannot be read')
eq('STORAGE_ERROR',policy_list_error.code,'policy cleanup exposes the download listing error')
eq(3,plugin_clears+reading_clears+policy_cleans,'failed listing does not invoke cache deletion')
app.storage.listDownloadTasks=function() error('synthetic download storage failure') end
local thrown_plugin,thrown_error=settings_view.plugin_cache_clear()
eq(nil,thrown_plugin,'plugin cache stays intact when download listing throws')
eq('STORAGE_ERROR',thrown_error.code,'thrown listing failure is reported safely')
eq(3,plugin_clears+reading_clears+policy_cleans,'thrown listing failure does not clear cache')
return count
