local Presets=require('legado.lib.ai_presets')
local UI={}
local function new(class,options) return class and class.new and class:new(options) or options end
local function optional(name) local ok,value=pcall(require,name);if ok then return value end end

function UI.show(host,view)
    local values=view:refresh()
    local provider=values.ai_provider=='mimo' and 'mimo' or 'deepseek'
    local service=view.ai_service
    local config=Presets.providers[provider]
    local widget,test_generation=nil,0
    local function refresh() return UI.show(host,view) end
    local function show_error(message) return host:_info(message,'AI 服务') end
    local function input(title,value,accept,options)
        local dialog
        local function accepted(text)
            if host.closed_widgets[dialog] then return false end
            if text==nil and dialog.getInputText then text=dialog:getInputText() end
            local saved,err=accept(text)
            if not saved then return show_error(err or '设置保存失败，请重试。') end
            host:_closeWidget(dialog)
            return refresh()
        end
        options=options or {}
        options.title,options.input=title,value
        options.buttons={{{text='取消',callback=function()
            if not host:_closeWidget(dialog) then return false end
            return refresh()
        end},{text='保存',is_enter_default=true,callback=accepted}}}
        dialog=new(host.input_dialog,options)
        local original=dialog.onCloseWidget
        dialog.onCloseWidget=function(instance,...)
            host.closed_widgets[instance]=true
            if original then return original(instance,...) end
        end
        return host:_showInput(dialog)
    end
    local function models()
        local chosen=service.model and service:model(provider) or config.model
        local items={}
        for _,model in ipairs(config.models) do
            items[#items+1]={text=(model.id==chosen and '✓ ' or '□ ')..model.label..' · '..model.id,callback=function()
                local saved,err=service:setModel(provider,model.id)
                if not saved then return show_error(err) end
                return refresh()
            end}
        end
        items[#items+1]={text='自定义模型 ID',callback=function()
            return input('自定义模型 ID',chosen,function(value) return service:setModel(provider,value) end,
                {description='填写该服务商支持的完整模型 ID；不要填写显示名称。',input_type='string'})
        end}
        return host:_modelMenu(view,{title=config.label..' · 切换模型',item_table=items,close_callback=refresh})
    end
    local items={}
    for _,choice in ipairs{{'DeepSeek','deepseek'},{'小米 MiMo','mimo'}} do
        items[#items+1]={text=(choice[2]==provider and '✓ ' or '□ ')..choice[1],callback=function()
            if view:set('ai_provider',choice[2])==nil then return show_error('设置保存失败，请重试。') end
            return refresh()
        end}
    end
    local source=service.keySource and service:keySource(provider) or 'unset'
    items[#items+1]={text='密钥：'..({manual='手动输入',file='JSON 文件',unset='未设置'})[source],select_enabled=false}
    items[#items+1]={text='手动输入 AI 密钥',callback=function()
        return input(config.label..' · 输入 AI 密钥','',function(value) return service:setManualKey(provider,value) end,
            {input_type='string',text_type='password',description='填写 API Key。保存到设备独立密钥文件，不写入普通设置。'})
    end}
    local function save_file(path)
        local saved,err=service:setKeyFile(provider,path)
        if not saved then return show_error(err or '密钥文件无效') end
        return refresh()
    end
    items[#items+1]={text='选择密钥 JSON 文件',callback=function()
        local PathChooser=optional('ui/widget/pathchooser')
        if PathChooser then return host:_show(PathChooser:new{title='选择密钥 JSON 文件',select_file=true,
            select_directory=false,show_files=true,file_filter=function(path) return tostring(path):lower():match('%.json$')~=nil end,
            path=(G_reader_settings and G_reader_settings.readSetting and G_reader_settings:readSetting('home_dir')) or '/mnt/us/documents',
            onConfirm=save_file}) end
        return input('密钥 JSON 文件路径','',function(path) return service:setKeyFile(provider,path) end,{input_type='string'})
    end}
    items[#items+1]={text='JSON 格式说明',callback=function()
        local text='方法一：一个文件保存当前服务商的密钥。\n\n{\n  "api_key": "替换成你的AI密钥"\n}\n\n'
            ..'方法二：两个服务商共用一个文件。\n\n{\n  "deepseek": {"api_key": "DeepSeek密钥"},\n  "mimo": {"api_key": "MiMo密钥"}\n}\n\n'
            ..'保存为 UTF-8 的 ai-key.json，复制到 Kindle，然后先选择服务商，再选择此文件。密钥用英文双引号；模型在“切换模型”里选择。'
        local TextViewer=optional('ui/widget/textviewer')
        if TextViewer then return host:_show(new(TextViewer,{title='AI 密钥 JSON 格式',text=text})) end
        return host:_info(text,'AI 密钥 JSON 格式')
    end}
    items[#items+1]={text='切换模型：'..(service.model and service:model(provider) or config.model),callback=models}
    items[#items+1]={text='补充提示词',callback=function()
        return input('补充提示词',values.ai_prompt_extra or '',function(value)
            if type(value)~='string' or #value>2000 then return nil,'补充提示词不能超过 2000 字节。' end
            if view:set('ai_prompt_extra',value)==nil then return nil,'设置保存失败，请重试。' end
            return true
        end,{multiline=true})
    end}
    items[#items+1]={text='测试连接',callback=function()
        test_generation=test_generation+1
        local generation=test_generation
        return host:_aiRequest('正在测试 AI 连接，请稍候…',function(done) return service:testConnection(done) end,function()
            return generation==test_generation and host.view_widgets[view]==widget and view.settings:get('ai_provider')==provider
        end,function(answer,err) host:_info(answer and 'AI 连接成功' or (err or 'AI 连接失败'),'AI 服务') end)
    end}
    widget=host:_modelMenu(view,{title='AI 服务',item_table=items,close_callback=function()
        test_generation=test_generation+1
        if host.ai_operation then host.ai_operation:cancel() end
        if not host:_closeWidget(widget) then return false end
        if view.section=='ai' and view.on_close then return view.on_close(view.local_directories_changed) end
        return host:_settings(view)
    end})
    return widget
end
return UI
