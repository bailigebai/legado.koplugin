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
eq(2,#closed,'input and waiting state close before showing the result')

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
    local before_late=#late_shown
    document.closed=true
    pending('迟到的解释')
    eq(before_late,#late_shown,'answer arriving after the reader closes opens no popup')

    document={closed=false}
    late_presenter:explainSelection(late_service,'另一章内容',document)
    late_shown[#late_shown].buttons[1][2].callback('')
    before_late=#late_shown
    document.closed=true
    pending(nil,'迟到的错误')
    eq(before_late,#late_shown,'error arriving after the reader closes opens no popup')

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
do
    local displays,requests,cancelled={},0,0
    local callback
    local p=Presenter.new{ui_manager={show=function(_,w) displays[#displays+1]=w end,
        close=function(_,w) if w.onCloseWidget then w:onCloseWidget() end end},
        input_dialog={new=function(_,o) return o end},info_message={new=function(_,o) return o end}}
    local s={explain=function(_,text,_,done)
        requests=requests+1;selected=text;callback=done
        return {cancel=function() cancelled=cancelled+1 end}
    end}
    p:explainSelection(s,'滑动选出的准确原文',{closed=false})
    local input=displays[#displays]
    eq(true,type(input.description)=='string' and input.description:find('滑动选出的准确原文',1,true)~=nil,
        'confirmation identifies the actual selected text before sending')
    input.buttons[1][2].callback('')
    local waiting=displays[#displays]
    eq(true,type(waiting.text)=='string' and waiting.text:find('正在分析',1,true)~=nil,
        'submitting AI analysis displays a waiting state immediately')
    eq('滑动选出的准确原文',selected,'analysis sends the captured selection exactly')
    input.buttons[1][2].callback('')
    eq(1,requests,'repeated confirmation never sends twice')
    waiting:onCloseWidget()
    eq(1,cancelled,'dismissing analysis cancels its request')
    local before=#displays;callback('迟到结果')
    eq(before,#displays,'cancelled analysis cannot reopen a late answer')
    p:explainSelection(s,'下一次选中的文字',{closed=false})
    displays[#displays].buttons[1][2].callback('')
    callback('下一次的分析')
    eq('下一次的分析',displays[#displays].text,'a new analysis works after cancellation')
    local rejected,reason=p:explainSelection(s,('字'):rep(1400),{closed=false})
    eq(nil,rejected,'oversized native selection is rejected so the caller can retain its highlight')
    eq('INVALID_INPUT',reason and reason.code,'selection validation returns a structured failure after showing its explanation')
    eq(2,requests,'invalid selection never starts another request')
end
return count
