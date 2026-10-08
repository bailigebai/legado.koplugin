local Text=require('legado.lib.leko_text')
local Excerpts={}
local function optional(name) local ok,value=pcall(require,name);return ok and value or nil end
function Excerpts.show(presenter,service,document,view)
    view=view or {};local widget
    local function alive() return not view.closed and (not document or not document.closed) end
    local function redraw() if alive() then return Excerpts.show(presenter,service,document,view) end end
    local function operation(message,start)
        local progress=presenter:_info(message..'\n关闭此窗口可返回阅读；已保存的摘录继续保留。','Obsidian 摘录')
        local active=true
        local close=progress.onCloseWidget
        progress.onCloseWidget=function(instance,...)
            active=false
            if close then return close(instance,...) end
        end
        return start(function(result,error_text)
            if not active or not alive() then return end
            active=false;presenter:_closeWidget(progress)
            presenter:_info(error_text or message..'成功'..(type(result)=='number' and ('，已同步 '..result..' 条摘录。') or '。'),'Obsidian 摘录')
        end)
    end
    local rows=service:list()
    if not rows then return presenter:_info('摘录列表无法读取，请检查设备存储。','Obsidian 摘录') end
    local config=service.client:config()
    local pending=0;for _,row in ipairs(rows) do if row.status~='synced' then pending=pending+1 end end
    local items={{text=string.format('已保存 %d 条 · 待同步 %d 条',#rows,pending),enabled=false},
        {text=config and ('目标：'..config.folder) or '尚未配置 Obsidian 接收连接',enabled=false}}
    items[#items+1]={text='配置连接（选择 JSON 文件）',callback=function()
        local Picker=optional('ui/widget/pathchooser')
        if not Picker then return presenter:_info('文件选择器不可用，请检查 KOReader 版本。') end
        return presenter:_show(Picker:new{title='选择 Obsidian 连接文件',select_file=true,select_directory=false,show_files=true,
            path='/mnt/us',file_filter=function(path) return tostring(path):lower():match('%.json$')~=nil end,
            onConfirm=function(path)
                if not alive() then return false end
                local saved,error_text=service.client:setConfigFile(path)
                if not saved then return presenter:_info(error_text,'Obsidian 摘录') end
                service:schedule();return redraw()
            end})
    end}
    items[#items+1]={text='测试连接',callback=function()
        return operation('测试 Obsidian 连接',function(done) return service.client:testConnection(done) end)
    end}
    items[#items+1]={text=service.busy and '正在后台同步' or '同步待传摘录',enabled=not service.busy,callback=function()
        return operation('同步摘录',function(done) return service:sync(done) end)
    end}
    items[#items+1]={text='刷新列表',callback=redraw}
    if service.last_error then items[#items+1]={text=service.last_error,enabled=false} end
    for _,row in ipairs(rows) do
        local quote=row
        local preview,_,more=Text.utf8Window(quote.quote or '',1,28)
        items[#items+1]={text=(quote.status=='synced' and '已同步 · ' or '待同步 · ')..quote.title..'\n'
            ..preview:gsub('%s+',' ')..(more and '…' or ''),callback=function()
            local Viewer=optional('ui/widget/textviewer')
            local content=quote.quote..'\n\n'..quote.title..' · '..quote.author..'\n'..quote.chapter
                ..'\n'..quote.location..'\n'..quote.captured_at
            if Viewer then return presenter:_show(Viewer:new{title='阅读摘录',text=content}) end
            return presenter:_info(content,'阅读摘录')
        end}
    end
    widget=presenter:_modelMenu(view,{title='Obsidian 摘录',item_table=items,
        close_callback=function()
            view.closed=true
            presenter:_closeWidget(widget)
            if document and not document.closed and document.widget and document.widget.resumeReading then document.widget:resumeReading() end
            return true
        end})
    service:schedule()
    return widget
end
return Excerpts
