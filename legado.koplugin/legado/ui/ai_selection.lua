local Presets=require('legado.lib.ai_presets')
local UI={}
local function new(class,options) return class and class.new and class:new(options) or options end

function UI.show(host,service,selected_text,document)
    if type(selected_text)~='string' or selected_text=='' or #selected_text>4000 then
        local message='请选择不超过 4000 字节的阅读内容。'
        host:_info(message,'AI 解释')
        return nil,{code='INVALID_INPUT',message=message}
    end
    host.ai_generation=(host.ai_generation or 0)+1
    local generation=host.ai_generation
    if host.ai_operation then host.ai_operation:cancel() end
    host:_closeWidget(host.ai_template_menu)
    host:_closeWidget(host.ai_selection_dialog)
    local template_id='explain'
    local extra=service.settings and service.settings:get('ai_prompt_extra') or ''
    local function current() return generation==host.ai_generation and (not document or document.closed~=true) end
    local function live(input) return current() and not host.closed_widgets[input] end
    local choose
    local preview,_,more=require('legado.lib.leko_text').utf8Window(selected_text,1,120)
    local function accepted(input,value)
        if not live(input) then return false end
        if value==nil and input.getInputText then value=input:getInputText() end
        if type(value)~='string' or #value>2000 then return host:_info('补充提示词不能超过 2000 字节。','AI 解释') end
        return host:_aiRequest('正在分析所选内容，请稍候…',function(done)
            if not host:_closeWidget(input) then done(nil,'分析窗口切换失败，请重新选择文字后重试。');return nil end
            return service:explain(selected_text,value,done,template_id)
        end,current,function(answer,err)
            if not answer then return host:_info(err or 'AI 解释失败','AI 解释') end
            local ok,TextViewer=pcall(require,'ui/widget/textviewer')
            return host:_show(new(ok and TextViewer or host.info_message,{title='AI 解释',text=answer}))
        end)
    end
    choose=function(input)
        if not live(input) or host.ai_template_menu then return false end
        if input.onCloseKeyboard then
            local ok=pcall(input.onCloseKeyboard,input)
            if not ok then return nil,{code='UI_ERROR',message='输入键盘切换失败，请重试。'} end
        end
        local menu,closed=nil,false
        local function close()
            if closed then return false end
            closed=true
            if host.ai_template_menu==menu then host.ai_template_menu=nil end
            host:_closeWidget(menu)
            if live(input) and input.onShowKeyboard then pcall(input.onShowKeyboard,input) end
            return true
        end
        local items={}
        for _,template in ipairs(Presets.templates) do
            items[#items+1]={text=(template_id==template.id and '✓ ' or '')..template.label,callback=function()
                if closed or not live(input) then return close() end
                local label='提示词模板：'..template.label
                local button=input.button_table and input.button_table:getButtonById('ai_template')
                if button then
                    local ok=pcall(button.setText,button,label,button.width)
                    if not ok then close();return host:_info('模板切换失败，请重试。','AI 解释') end
                end
                template_id=template.id
                input.buttons[2][1].text=label
                close()
                return input
            end}
        end
        menu=new(host.menu,{title='选择读书提示词',item_table=items,close_callback=close})
        local original=menu.onCloseWidget
        menu.onCloseWidget=function(instance,...)
            host.closed_widgets[instance]=true
            close()
            if original then return original(instance,...) end
        end
        host.ai_template_menu=menu
        local shown,err=host:_show(menu)
        if not shown then host.closed_widgets[menu]=nil;close();return nil,err end
        return shown
    end
    local function render()
        local input
        input=new(host.input_dialog,{title='AI 解释 · 补充要求',input=extra,
            description='已选文字：'..preview..(more and '…' or ''),input_hint='可留空，按所选模板分析',multiline=true,
            buttons={{{text='取消',callback=function() return host:_closeWidget(input) end},
                {text='解释',is_enter_default=true,callback=function(value) return accepted(input,value) end}},
                {{id='ai_template',text='提示词模板：'..Presets.template(template_id).label,callback=function() return choose(input) end}}}})
        local original=input.onCloseWidget
        input.onCloseWidget=function(instance,...)
            host.closed_widgets[instance]=true
            if host.ai_selection_dialog==instance then host:_closeWidget(host.ai_template_menu) end
            if original then return original(instance,...) end
        end
        local shown,err=host:_showInput(input)
        if not shown then return nil,err end
        host.ai_selection_dialog=input
        return shown
    end
    return render()
end
return UI
