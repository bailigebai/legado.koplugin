local h=require('native_library_harness').install()
package.loaded['ffi/util']={}
package.loaded.device.hasKeyboard=function() return false end
package.loaded['ui/bidi'].rtlUIText=function() return false end
package.loaded['ui/bidi'].ltr=function(text) return text end
local NativeMenu=require('ui/widget/menu')
local Menu=NativeMenu:extend{init=function(self) self.item_table_stack={} end,onCloseWidget=function() end}
local ButtonTable=require('ui/widget/buttontable')
local Presenter=require('legado.ui.presenter')
local A=require('assertions')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local keyboards,hidden,sent=0,0,0
local p=Presenter.new{menu=Menu,ui_manager=h.ui,input_dialog={new=function(_,o)
    o.button_table=ButtonTable:new{buttons=o.buttons,width=550}
    o.onShowKeyboard=function() keyboards=keyboards+1 end
    o.onCloseKeyboard=function() hidden=hidden+1 end
    o.getInputText=function(self) return self.input end
    return o
end},info_message={new=function(_,o) return o end}}
local service={explain=function(_,text,extra,done,template)
    sent=sent+1;eq('原生选区',text,'official menu preserves original selection')
    eq('保留自填',extra,'official menu preserves typed supplement')
    eq('literary',template,'official menu commits chosen template')
    done('赏析结果')
end}
local input=assert(p:explainSelection(service,'原生选区',{closed=false}))
input.input='保留自填'
local button=input.button_table:getButtonById('ai_template')
local initial_width=button.width
local initial_size=button:getSize().w
eq('提示词模板：通俗解释',button.text,'official ButtonTable locates template action by ID')
button.callback()
local menu=h.shown
eq(1,hidden,'opening native menu hides the input keyboard')
menu:onMenuSelect(menu.item_table[5])
eq('提示词模板：文学赏析',button.text,'official Button.setText updates selected label in place')
eq(initial_width,button.width,'template label changes preserve the allocated full-row button width')
eq(initial_size,button:getSize().w,'template label changes preserve the original clickable area')
eq(input,p.ai_selection_dialog,'official menu retains one original input')
eq(nil,p.ai_template_menu,'natural native selection close releases template menu owner')
eq(2,keyboards,'keyboard resumes exactly once after template selection')
eq(0,sent,'native template choice never sends a request')
input.buttons[1][2].callback()
eq(1,sent,'explicit confirmation starts one explanation')
input=assert(p:explainSelection(service,'另一个选区',{closed=false}))
input.button_table:getButtonById('ai_template').callback()
menu=h.shown
local closes_before=#h.closed
menu:onCloseAllMenus()
eq(closes_before+1,#h.closed,'native close icon sends exactly one CloseWidget event, without reentering UIManager.close')
eq(nil,p.ai_template_menu,'native close icon releases child menu')
eq(false,p.closed_widgets[input]==true,'native close icon retains parent input')
return n
