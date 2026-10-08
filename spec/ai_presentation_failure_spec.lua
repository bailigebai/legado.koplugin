require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Context=require('legado.lib.ai_selection_context')
local n,failures=0,{}
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local function scenario(label,fn)
    local ok,err=pcall(fn)
    if not ok then failures[#failures+1]=label..': '..tostring(err) end
end
local function selection(presenter)
    local factory,clears=nil,0
    local reader={document={},highlight={addToHighlightDialog=function(_,_,f) factory=f end,
        removeFromHighlightDialog=function() end}}
    Context.attach(reader,function(text,doc) return presenter:explainSelection({},text,doc) end)
    local button=factory({selected_text={text='需要保留的原句'},onClose=function() clears=clears+1 end})
    return button,function() return clears end
end
scenario('input display failure',function()
    local keyboards,closed=0,0
    local p=Presenter.new{input_dialog={new=function(_,o)
        o.onShowKeyboard=function() keyboards=keyboards+1 end;return o
    end},ui_manager={show=function() error('display failed') end,close=function() closed=closed+1 end}}
    local action,clears=selection(p)
    local ok,result,err=pcall(action.callback)
    eq(true,ok,'input display failure is returned without raising out of the highlight action')
    eq(nil,result,'real Presenter does not report a failed display as a successful opening')
    eq('UI_ERROR',err and err.code,'display failure stays inspectable')
    eq(0,clears(),'failed display preserves the original native selection')
    eq(0,keyboards,'failed input display never opens a stray keyboard')
    eq(1,closed,'failed input display performs one real cleanup even if the window was partly inserted')
end)
scenario('keyboard failure',function()
    local shown,closed=0,0
    local p=Presenter.new{input_dialog={new=function(_,o)
        o.onShowKeyboard=function() error('keyboard failed') end;return o
    end},ui_manager={show=function() shown=shown+1 end,close=function() closed=closed+1 end}}
    local action,clears=selection(p)
    local ok,result,err=pcall(action.callback)
    eq(true,ok,'keyboard failure is returned without raising out of the highlight action')
    eq(nil,result,'partly opened input is not treated as a successful selection handoff')
    eq('UI_ERROR',err and err.code,'keyboard failure stays inspectable')
    eq(1,shown,'fixture really displays the input before keyboard failure')
    eq(1,closed,'keyboard failure cleans up the partially opened input window')
    eq(0,clears(),'keyboard failure preserves original selected text')
end)
scenario('waiting display failure and retry',function()
    local inputs,closed={},{}
    local fail_wait,sends,pending=true,0,nil
    local p=Presenter.new{input_dialog={new=function(_,o) return o end},info_message={new=function(_,o) return o end},
        ui_manager={show=function(_,w)
            if w.text and fail_wait then error('waiting display failed') end
            inputs[#inputs+1]=w
        end,close=function(_,w) closed[w]=true;if w.onCloseWidget then w:onCloseWidget() end end}}
    local service={explain=function(_,_,_,done) sends=sends+1;pending=done;return {cancel=function() end} end}
    local input=assert(p:explainSelection(service,'准确的原文',{closed=false}))
    local ok,result,err=pcall(input.buttons[1][2].callback,'原先的补充要求')
    eq(true,ok,'waiting display failure never raises out of the confirm button')
    eq(nil,result,'waiting window must exist before the analysis starts')
    eq('UI_ERROR',err and err.code,'waiting failure is structured')
    eq(nil,closed[input],'failed waiting display keeps the input available with its text')
    eq(0,sends,'failed waiting display sends no request')
    eq(nil,p.ai_operation,'failed waiting display leaves no phantom active request')
    fail_wait=false
    eq(true,type(input.buttons[1][2].callback('原先的补充要求'))=='table','the same input can retry after a display failure')
    eq(true,closed[input],'successful waiting setup closes the input exactly once')
    eq(1,sends,'retry sends one request')
    input.buttons[1][2].callback('原先的补充要求')
    eq(1,sends,'old confirm cannot duplicate a successfully submitted request')
    pending('完整解释')
    eq('完整解释',inputs[#inputs].text,'retry still delivers the answer')
end)
if #failures>0 then error(table.concat(failures,'\n'),0) end
return n
