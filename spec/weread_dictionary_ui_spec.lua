require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local shown,closed={},{}
package.loaded['ui/widget/textviewer']={new=function(_,options) return options end}
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,
    close=function(_,widget) closed[#closed+1]=widget;if widget.onCloseWidget then widget:onCloseWidget() end end}}
local pending,sends,cancelled=nil,0,0
local client={dictionary=function(_,word,callback)
    sends=sends+1;pending=callback
    return {cancel=function() cancelled=cancelled+1 end}
end}
local alive=true
local lookup=presenter:showDictionary(client,'纽约时报',nil,function() return alive end)
eq(1,sends,'opening dictionary performs a single explicit query')
eq(true,shown[1].text:find('正在',1,true)~=nil,'query has an immediately visible loading panel')
pending({text='详细背景说明',source='微信读书词典 · 搜狗百科'})
eq('微信读书词典 · 搜狗百科\n\n详细背景说明',shown[2].text,'background is displayed in a scrollable text viewer')
eq(false,lookup.closed==true,'programmatic loading replacement does not cancel the panel')
shown[2].buttons_table[1][1].callback()
eq(true,lookup.closed,'close ends the lookup owner')
lookup=presenter:showDictionary(client,'再次',nil,function() return alive end)
local callback=pending
shown[#shown].onCloseWidget(shown[#shown])
eq(true,lookup.closed,'host-driven close cancels a loading lookup immediately')
eq(1,cancelled,'closing loading panel cancels network IO')
local before=#shown;callback({text='迟到的内容',source='词典'})
eq(before,#shown,'late success cannot resurrect a closed dictionary')
lookup=presenter:showDictionary(client,'重试',nil,function() return alive end)
pending(nil,'网络失败')
eq('网络失败',shown[#shown].text,'query failure is visible')
shown[#shown].buttons_table[1][2].callback()
eq(4,sends,'retry starts one new query')
alive=false;before=#shown;pending({text='旧章节',source='词典'})
eq(before,#shown,'changing document/account prevents a stale response popup')
eq(true,lookup.closed,'account/document change closes the loading panel owner')
eq(nil,lookup.request,'account/document change releases the request handle')
local stack,failed_closes={},0
local failing=Presenter.new{ui_manager={show=function(_,widget) stack[1]=widget;error('Show failed') end,
    close=function(_,widget) failed_closes=failed_closes+1;if stack[1]==widget then stack[1]=nil end end}}
local failed,error_value=failing:showDictionary(client,'展示失败')
eq(nil,failed,'failed dictionary presentation is returned as an error')
eq('UI_ERROR',error_value.code,'presentation error stays structured')
eq(1,failed_closes,'partially inserted failed panel receives one actual close')
eq(nil,stack[1],'failed dictionary cannot leave an orphan window over the reader')
local constructor_calls=0
local normal_new=package.loaded['ui/widget/textviewer'].new
package.loaded['ui/widget/textviewer'].new=function(self,options)
    constructor_calls=constructor_calls+1
    if constructor_calls==2 then error('native constructor failure') end
    return normal_new(self,options)
end
local constructing=presenter:showDictionary(client,'构造失败')
local ok=pcall(pending,{text='实际背景',source='词典'})
eq(true,ok,'asynchronous native constructor failure cannot escape the network callback')
eq(true,constructing.closed,'failed native construction closes the lookup owner')
eq('UI_ERROR',constructing.error.code,'constructor failure remains structured and inspectable')
package.loaded['ui/widget/textviewer'].new=normal_new
return count
