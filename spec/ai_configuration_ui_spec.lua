require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local AI=require('legado.lib.ai_service')
local Json=require('legado.lib.json_codec')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local function item(page,text)
    for _,v in ipairs(page.item_table or {}) do if v.text:find(text,1,true) then return v end end
    error('Missing item '..text)
end
local shown,files,requests={}, {},{}
local values={ai_provider='deepseek',ai_prompt_extra='默认要求'}
local settings={get=function(_,k) return values[k] end,all=function() return values end,
    set=function(_,k,v) values[k]=v;return v end}
local service=AI.new{settings=settings,key_dir='/private',fs={readBounded=function(_,p) return files[p] end,
    atomicWrite=function(_,p,s) files[p]=s;return true end},requests={execute=function(_,spec,done)
        requests[#requests+1]={spec=spec,done=done};return {cancel=function() end}
    end}}
local p=Presenter.new{menu={new=function(_,o) return o end},input_dialog={new=function(_,o)
    o.getInputText=function(self) return self.input or '' end
    return o
end},info_message={new=function(_,o) return o end},
ui_manager={show=function(_,w) shown[#shown+1]=w end,close=function(_,w) if w.onCloseWidget then w:onCloseWidget() end end}}
local view={refresh=function() return values end,set=function(_,k,v) return settings:set(k,v) end,
    settings=settings,ai_service=service}
local page=p:_aiSettings(view)
item(page,'手动输入 AI 密钥').callback()
local input=shown[#shown]
eq('password',input.text_type,'manual key input is masked')
eq('',input.input,'key never prefills raw secret')
input.buttons[1][2].callback('secret-ui')
page=shown[#shown]
eq('secret-ui',service:_key('deepseek'),'manual key activates the current provider')
eq(true,item(page,'密钥：手动输入')~=nil,'page identifies configured source without displaying key')
item(page,'JSON 格式说明').callback()
eq(true,shown[#shown].text:find('"api_key"',1,true)~=nil,'help shows the real supported JSON field')
eq(false,shown[#shown].text:find('secret-ui',1,true)~=nil,'JSON help never exposes stored key')
item(page,'切换模型').callback()
local models=shown[#shown]
item(models,'deepseek-v4-pro').callback()
eq('deepseek-v4-pro',service:model(),'model choice is used by service')
page=shown[#shown]
item(page,'切换模型').callback()
item(shown[#shown],'自定义模型 ID').callback()
shown[#shown].buttons[1][2].callback('my-reader-v1')
eq('my-reader-v1',service:model(),'custom model can be entered manually')
eq(0,#requests,'configuring models never calls a paid API')

local document={closed=false}
local selection=p:explainSelection(service,'准确拖选出的原文',document)
selection.input='临时补充要求'
selection.buttons[2][1].callback()
local templates=shown[#shown]
eq(8,#templates.item_table,'selection offers eight reading templates')
eq(0,#requests,'opening templates sends no request')
item(templates,'段落总结').callback()
local updated=p.ai_selection_dialog
eq(selection,updated,'template selection reuses the original input without reopening its keyboard')
eq('临时补充要求',updated.input,'template change keeps typed supplementary content')
eq(true,updated.description:find('准确拖选出的原文',1,true)~=nil,'template change keeps exact original preview')
eq(true,updated.buttons[2][1].text:find('段落总结',1,true)~=nil,'selected template is visible')
local natural_before=#shown
templates.close_callback() -- Native Menu closes after item callback.
eq(natural_before,#shown,'natural menu close never opens a duplicate input')
updated.buttons[1][2].callback('临时补充要求')
eq(1,#requests,'only explicit confirmation sends AI request')
eq('my-reader-v1',requests[1].spec.body.model,'reading request uses the chosen model')
eq('准确拖选出的原文',requests[1].spec.body.messages[2].content,'template request preserves selected original')
eq(true,requests[1].spec.body.messages[1].content:find('总结',1,true)~=nil,'request really contains selected template')
selection.buttons[1][2].callback('旧窗口')
eq(1,#requests,'old input cannot submit after template replacement')
requests[1].done({status=200,body=Json.encode{choices={{message={content='总结结果'}}}}})
eq('总结结果',shown[#shown].text,'new template request still displays response')

selection=p:explainSelection(service,'取消菜单后继续',document)
selection.input='保留内容'
selection.buttons[2][1].callback()
templates=shown[#shown]
templates.close_callback()
eq(false,p.closed_widgets[selection]==true,'cancelling template menu retains parent input')
eq('保留内容',selection.input,'cancelling menu retains typed supplement')
selection.buttons[2][1].callback()
templates=shown[#shown]
document.closed=true
local before=#shown
item(templates,'人物心理').callback()
eq(before,#shown,'closed document cannot reopen the template input')
eq(1,#requests,'closed document/template choice starts no request')
document.closed=false
selection=p:explainSelection(service,'再次选区',document)
selection.buttons[2][1].callback()
eq(true,shown[#shown].item_table~=nil,'new selection can open templates after an earlier menu is dismissed')
local interrupted=shown[#shown]
selection=p:explainSelection(service,'替换上一选区',document)
before=#shown
selection.buttons[2][1].callback()
eq(before+1,#shown,'replacement selection really displays a new template menu')
eq(false,interrupted==shown[#shown],'replacing a selection cleans up its old template menu owner')
shown[#shown].close_callback()
p.ui_manager:close(selection) -- Native titlebar / Back bypasses Presenter:_closeWidget.
selection.buttons[1][2].callback('已关闭的输入')
eq(1,#requests,'a naturally dismissed selection cannot submit a queued old confirmation')
page=p:_aiSettings(view)
item(page,'手动输入 AI 密钥').callback()
input=shown[#shown]
p.ui_manager:close(input)
before=#shown
input.buttons[1][2].callback('dismissed-secret')
eq('secret-ui',service:_key('deepseek'),'a naturally dismissed key input never saves a queued old secret')
eq(before,#shown,'a dismissed key input never reopens settings via an old save')
return n
