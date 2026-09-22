-- UTF-8 windows/positions adapted from Leko/Util.lua at
-- jnjnnjzch/leko-reader 57dff8958dd43a5d95cb2dac22ca363d874de29b (AGPL-3.0-or-later).
-- The HTML-to-paragraph boundary uses this plugin's existing entity decoder.
local Text = {}
local function valid_utf8(value)
    local i=1
    while i<=#value do
        local b=value:byte(i);local size
        if b<0x80 then size=1
        elseif b>=0xC2 and b<=0xDF then size=2
        elseif b>=0xE0 and b<=0xEF then size=3
        elseif b>=0xF0 and b<=0xF4 then size=4
        else return false end
        for j=1,size-1 do local c=value:byte(i+j);if not c or c<0x80 or c>0xBF then return false end end
        local c=value:byte(i+1)
        if (b==0xE0 and c<0xA0) or (b==0xED and c>=0xA0) or (b==0xF0 and c<0x90) or (b==0xF4 and c>=0x90) then return false end
        i=i+size
    end
    return true
end
local function bytes(byte)
    if byte < 0x80 then return 1 elseif byte < 0xE0 then return 2 elseif byte < 0xF0 then return 3 end
    return 4
end
function Text.utf8Chars(value)
    return require('util').splitToChars(value or '')
end
function Text.utf8Length(value)
    local i,n=1,0
    while i<=#value do i=i+bytes(value:byte(i));n=n+1 end
    return n
end
function Text.utf8Window(value,first,limit,hint_char,hint_byte)
    local i,c=1,1
    if hint_char and hint_byte and hint_char<=first and hint_byte>=1 and hint_byte<=#value+1 then i,c=hint_byte,hint_char end
    while c<first and i<=#value do i=i+bytes(value:byte(i));c=c+1 end
    local start,n=i,0
    while n<limit and i<=#value do i=i+bytes(value:byte(i));n=n+1 end
    return value:sub(start,i-1),n,i<=#value,i
end
function Text.positionCopy(position)
    return {chapter=tonumber(position and position.chapter) or 1,chapter_id=position and position.chapter_id,
        paragraph=tonumber(position and position.paragraph) or 1,char=tonumber(position and position.char) or 1}
end
function Text.positionEqual(a,b)
    return a and b and a.chapter==b.chapter and a.paragraph==b.paragraph and a.char==b.char
end
function Text.positionLess(a,b)
    if a.chapter~=b.chapter then return a.chapter<b.chapter end
    if a.paragraph~=b.paragraph then return a.paragraph<b.paragraph end
    return a.char<b.char
end
function Text.parse(body,title)
    if type(body)~='string' or #body>8*1024*1024 or body=='' then
        return nil,{code='INVALID_INPUT',message='章节正文为空或超过 8 MB。'}
    end
    if not valid_utf8(body) then return nil,{code='ENCODING_ERROR',message='章节正文不是有效的 UTF-8 文本。'} end
    -- Images carry content that the Leko text renderer cannot reproduce.
    if body:lower():find('<%s*img[%s/>]') then
        return nil,{code='UNSUPPORTED_CONTENT',message='本章包含图片，请关闭无感阅读后使用原生阅读器查看完整内容。'}
    end
    local value=body:gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>','')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>','')
    value=value:gsub('<%s*/?%s*([%a%d]+)[^>]*>',function(tag)
        tag=tag:lower()
        return (({p=true,div=true,br=true,li=true,blockquote=true,pre=true})[tag] or tag:match('^h[1-6]$')) and '\n' or ''
    end)
    value=require('legado.lib.safe_functions').functions.htmldecode(value):gsub('\r\n','\n'):gsub('\r','\n')
    local paragraphs={}
    for line in (value..'\n'):gmatch('(.-)\n') do
        line=line:match('^%s*(.-)%s*$')
        if line~='' then paragraphs[#paragraphs+1]=line end
    end
    if paragraphs[1]==title and #paragraphs>1 then table.remove(paragraphs,1) end
    if #paragraphs==0 then return nil,{code='PARSE_ERROR',message='本章没有可显示的文字。'} end
    return {title=tostring(title or ''),paragraphs=paragraphs,checksum=require('legado.lib.identity').hash(body)}
end
function Text.metrics(model)
    if model.metrics then return model.metrics end
    local m={prefixes={},lengths={},total=0}
    for i,p in ipairs(model.paragraphs) do m.prefixes[i]=m.total;m.lengths[i]=Text.utf8Length(p);m.total=m.total+m.lengths[i] end
    model.metrics=m;return m
end
function Text.fraction(model,position)
    local m=Text.metrics(model);local p=math.max(1,math.min(#model.paragraphs,position.paragraph or 1))
    return m.total>0 and math.min(1,((m.prefixes[p] or 0)+math.min(m.lengths[p],math.max(0,(position.char or 1)-1)))/m.total) or 0
end
function Text.positionAt(model,fraction)
    local m=Text.metrics(model);local wanted=math.floor(m.total*math.max(0,math.min(1,fraction or 0)))
    for p,length in ipairs(m.lengths) do
        if wanted<m.prefixes[p]+length then return {chapter=1,paragraph=p,char=wanted-m.prefixes[p]+1} end
    end
    return {chapter=1,paragraph=#model.paragraphs,char=math.max(1,m.lengths[#model.paragraphs])}
end
return Text
