-- Tab actions shared by the native and independent reading surfaces.
local Sidebar={}

local function valid_mark(mark)
    return type(mark)=='table' and type(mark.source_id)=='string'
        and (type(mark.chapter_uid)=='string' or type(mark.chapter_url)=='string')
        and type(mark.fraction)=='number' and mark.fraction>=0 and mark.fraction<=1
end

local function bookmarks(app,state,document,side)
    local reader=document and document.reader
    if not state then
        if not reader or not reader.bookmark then return {{text='当前文档不支持书签',enabled=false}} end
        local items={{text='添加／移除当前位置书签',callback=function()
            reader.bookmark:onToggleBookmark();side:switchTab('bookmarks');return true
        end}}
        local annotations=reader.annotation and reader.annotation.annotations or {}
        for _,mark in ipairs(annotations) do
            local item={title=mark.text or mark.chapter or '书签',page=type(mark.page)=='number' and mark.page or nil,
                xpointer=type(mark.page)=='string' and mark.page or mark.xpointer}
            items[#items+1]={text=item.title,page=item.page,xpointer=item.xpointer,
                delete_callback=function()reader.bookmark:removeItem(mark);side:switchTab('bookmarks');return true end}
        end
        return items
    end
    if not app.storage then return {{text='书签存储暂不可用',enabled=false}} end
    local progress,err=app.storage:getProgress(state.book.id)
    if err then return {{text='书签读取失败，请稍后重试',enabled=false}} end
    local marks=progress and progress.reading_bookmarks or {}
    if type(marks)~='table' then return {{text='书签数据无法读取，已保留原数据',enabled=false}} end
    local chapter=state.chapters[state.index]
    local fraction=document:getProgressFraction()
    local function same(mark)
        return valid_mark(mark) and mark.source_id==state.book.source_id and mark.chapter_uid==chapter.uid and math.abs(mark.fraction-fraction)<.001
    end
    local found=false
    for _,mark in ipairs(marks) do if same(mark) then found=true end end
    local items={{text=found and '移除当前位置书签' or '添加当前位置书签',callback=function()
        local saved,save_error=document:flushProgress()
        if saved==nil or save_error then return nil,save_error end
        local current,read_error=app.storage:getProgress(state.book.id)
        if read_error then return nil,read_error end
        local candidate={};for k,v in pairs(current or {})do candidate[k]=v end
        local updated={}
        for _,mark in ipairs(candidate.reading_bookmarks or {}) do if not same(mark) then updated[#updated+1]=mark end end
        if not found then updated[#updated+1]={source_id=state.book.source_id,chapter_uid=chapter.uid,
            chapter_url=chapter.url,chapter_index=state.index,title=chapter.title,fraction=fraction} end
        candidate.book_id,candidate.reading_bookmarks=state.book.id,updated
        local result,write_error=app.storage:putProgress(candidate)
        if not result then return nil,write_error end
        side:switchTab('bookmarks');return true
    end}}
    for _,mark in ipairs(marks) do
        if not valid_mark(mark) then
            items[#items+1]={text='书签位置不完整，已保留原数据',enabled=false}
        else
            -- The saved index is only a demand hint. Session verifies the stable
            -- identity after lazy catalog loading before committing any jump.
            items[#items+1]={text=mark.title or '书签',mandatory=string.format('%d%%',100*mark.fraction),
                index=mark.chapter_index,fraction=mark.fraction,bookmark=mark,delete_callback=function()
                    local flushed,flush_error=document:flushProgress()
                    if flushed==nil or flush_error then return nil,flush_error end
                    local current,read_error=app.storage:getProgress(state.book.id)
                    if read_error then return nil,read_error end
                    local candidate={};for k,v in pairs(current or {})do candidate[k]=v end
                    local updated={}
                    for _,entry in ipairs(candidate.reading_bookmarks or {}) do
                        if not (type(entry)=='table' and entry.chapter_uid==mark.chapter_uid and entry.source_id==mark.source_id and entry.fraction==mark.fraction) then
                            updated[#updated+1]=entry
                        end
                    end
                    candidate.book_id,candidate.reading_bookmarks=state.book.id,updated
                    local saved,save_error=app.storage:putProgress(candidate)
                    if not saved then return nil,save_error end
                    side:switchTab('bookmarks');return true
                end}
        end
    end
    return items
end

local function fonts(document,side)
    local view=document and document.backend=='immersive' and document.widget
    if view then
        local choices=require('legado.ui.leko_font_selection').buildItems(view.style)
        local items={}
        local function add(choice)
            if choice.variants then for _,variant in ipairs(choice.variants) do add(variant) end;return end
            items[#items+1]={text=choice.text,bold=choice.bold,callback=function()
                local ok,err=view:applyStyle{body_font=choice.font_path,body_font_index=choice.face_index,body_font_display_name=choice.display_name,
                    title_font=choice.font_path,title_font_index=choice.face_index,title_font_display_name=choice.display_name}
                if not ok then return nil,err end
                side:switchTab('fonts');return true
            end}
        end
        for _,choice in ipairs(choices) do add(choice) end
        return items
    end
    local font=document and document.reader and document.reader.font
    if not font or not font.setupFaceMenuTable then return {{text='当前文档不支持字体切换',enabled=false}} end
    font:setupFaceMenuTable()
    local items={}
    for _,entry in ipairs(font.face_table or {}) do
        if entry.callback and entry.menu_item_id then
            items[#items+1]={text=entry.text_func and entry.text_func() or entry.text,
                bold=entry.checked_func and entry.checked_func(),callback=function()
                    entry.callback();side:switchTab('fonts');return true
                end}
        end
    end
    return items
end

function Sidebar.items(app,state,document,side,tab)
    if tab=='bookmarks' then return bookmarks(app,state,document,side) end
    if tab=='fonts' then return fonts(document,side) end
    if tab=='config' then
        return {
            {text='阅读排版与设置',callback=function()side:close();return app:openSettings(document)end},
            {text='页眉页脚设置',callback=function()side:close();return app:openSettings(document,true)end},
            {text='侧栏位置：'..(side.position=='left' and '左侧' or '右侧'),callback=function()
                local saved,err=app.settings:set('side_toc_position',side.position=='left' and 'right' or 'left')
                if not saved then return nil,err end
                side:close();return app:openReadingSideToc(state,document)
            end},
        }
    end
    return {}
end
return Sidebar
