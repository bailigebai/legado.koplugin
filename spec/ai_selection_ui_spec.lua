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

do
    local late_shown, requests, pending = {}, 0, nil
    local late_presenter = Presenter.new{ui_manager={
        show=function(_,widget) late_shown[#late_shown+1]=widget end,
        close=function() end},
        input_dialog={new=function(_,options) return options end},
        info_message={new=function(_,options) return options end}}
    local late_service={explain=function(_,_,_,done) requests=requests+1;pending=done end}
    local document={closed=false}
    late_presenter:explainSelection(late_service,'旧章节内容',document)
    late_shown[#late_shown].buttons[1][2].callback('')
    eq(1,requests,'open reading document sends the AI request')
    document.closed=true
    pending('迟到的解释')
    eq(1,#late_shown,'answer arriving after the reader closes opens no popup')

    document={closed=false}
    late_presenter:explainSelection(late_service,'另一章内容',document)
    late_shown[#late_shown].buttons[1][2].callback('')
    document.closed=true
    pending(nil,'迟到的错误')
    eq(2,#late_shown,'error arriving after the reader closes opens no popup')

    document={closed=false}
    late_presenter:explainSelection(late_service,'未提交内容',document)
    document.closed=true
    late_shown[#late_shown].buttons[1][2].callback('')
    eq(2,requests,'a closed document cannot submit the old AI dialog')

    document={closed=false}
    late_presenter:explainSelection(late_service,'当前内容',document)
    late_shown[#late_shown].buttons[1][2].callback('')
    pending('当前解释')
    eq('当前解释',late_shown[#late_shown].text,'an open document still shows its AI answer')
end
return count
