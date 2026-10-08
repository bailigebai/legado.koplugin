local Identity=require('legado.lib.identity')
local Context={BUTTON='13_legado_excerpt'}
local function str(value) return type(value)=='string' and value or '' end
local function plain(value) return str(value):gsub('[%z\1-\8\11\12\14-\31]',''):match('^%s*(.-)%s*$') end
local function call(object,key)
    if object and type(object[key])=='function' then local ok,value=pcall(object[key],object);if ok then return value end end
end
local function point(value)
    if type(value)=='string' then return value:sub(1,2048) end
    if type(value)=='table' then
        if value.paragraph then return tostring(value.paragraph)..':'..tostring(value.char or 1) end
        if value.page then return '页 '..tostring(value.page) end
    end
    return ''
end
function Context.build(text,document,selection)
    if not document or document.closed then return nil,'阅读页面已关闭。' end
    text=plain(text)
    if text=='' or #text>65536 then return nil,'请选择不超过 64 KiB 的文字。' end
    selection=selection or {}
    local state=document.reading_state
    local row={quote=text,title='',author='',source='',chapter='',location=''}
    if state and state.book then
        local book=state.book
        local chapter=state.chapters and state.chapters[state.index] or state.chapter or {}
        row.title=plain(book.name or book.title);row.author=plain(book.author)
        row.source=book.source_id=='weread' and '微信读书' or '书源'
        row.book_key=str(book.id)~='' and book.id or Identity.book(book.source_id,book.url or row.title)
        row.chapter=plain(chapter.title or chapter.name)
        row.location='章节 '..tostring(state.index or 1)
    else
        local reader=document.reader or document
        local props=reader.doc_props or {}
        local file=reader.document and reader.document.file or ''
        row.title=plain(props.title)
        if row.title=='' then row.title=plain(file:match('([^/\\]+)$')) end
        row.author=plain(props.authors or props.author);row.source='本地书籍'
        row.book_key=Identity.book('local',file~='' and file or row.title)
        row.chapter=plain(call(reader.toc,'getTocTitleOfCurrentPage'))
        row.location='页 '..tostring(call(reader,'getCurrentPage') or call(reader.document,'getCurrentPage') or '')
    end
    if row.title=='' then row.title='未命名书籍' end
    local first,last=point(selection.first or selection.pos0),point(selection.last or selection.pos1)
    if first~='' then row.location=row.location..' · '..first..(last~='' and (' — '..last) or '') end
    return row
end

-- One key is shared by ordinary local books and generated chapter documents.
-- Resolve the current document at click time, before clearing KOReader's selection.
function Context.attach(reader,capture,document)
    if not reader or not reader.highlight or not reader.highlight.addToHighlightDialog then return false end
    local token={};reader.legado_excerpt_token=token
    reader.highlight:addToHighlightDialog(Context.BUTTON,function(highlight)
        return {text='摘录到 Obsidian',callback=function()
            if reader.legado_excerpt_token~=token then return false end
            local selected=highlight.selected_text
            if not selected or type(selected.text)~='string' then return false end
            local target=document or reader.legado_reading_document or {reader=reader}
            if not target.reading_state and not reader.document then return false end
            local saved,err=capture(selected.text,target,{pos0=selected.pos0,pos1=selected.pos1})
            if saved and highlight.onClose then highlight:onClose() end
            return saved,err
        end}
    end)
    return true
end
function Context.detach(reader)
    if reader then reader.legado_excerpt_token=nil end
    if reader and reader.highlight and reader.highlight.removeFromHighlightDialog then
        reader.highlight:removeFromHighlightDialog(Context.BUTTON)
    end
end
return Context
