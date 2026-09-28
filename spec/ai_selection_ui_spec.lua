require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local shown,closed={},{}
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,
    close=function(_,widget) closed[#closed+1]=widget end},
    input_dialog={new=function(_,options) return options end},
    info_message={new=function(_,options) return options end}}
local selected,extra
local service={settings={get=function() return '默认补充' end},
    explain=function(_,text,request_extra,callback)
        selected,extra=text,request_extra
        callback('可读的解释')
    end}
presenter:explainSelection(service,'庄周梦蝶')
eq('默认补充',shown[1].input,'saved supplemental prompt prefills the selection dialog')
shown[1].buttons[1][2].callback('解释典故')
eq('庄周梦蝶',selected,'selected text is sent to AI')
eq('解释典故',extra,'one-time prompt can override saved prompt')
eq('可读的解释',shown[#shown].text,'AI answer is shown to the reader')
eq(1,#closed,'input closes before showing the result')
return count
