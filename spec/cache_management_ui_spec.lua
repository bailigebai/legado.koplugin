require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
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
return count
