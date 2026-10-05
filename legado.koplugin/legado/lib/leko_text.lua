-- UTF-8 windows/positions adapted from Leko/Util.lua at
-- jnjnnjzch/leko-reader 57dff8958dd43a5d95cb2dac22ca363d874de29b (AGPL-3.0-or-later).
-- The HTML-to-paragraph boundary uses this plugin's existing entity decoder.
local Text = {}
local Coordinates=require('legado.lib.weread_text_coordinates')
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
function Text.positionLength(model,index)
    if model.images and model.images[index] then return 1 end
    return Text.utf8Length(model.paragraphs[index] or '')
end
function Text.parse(body,title,map_positions,assets)
    if type(body)~='string' or #body>8*1024*1024 or body=='' then
        return nil,{code='INVALID_INPUT',message='章节正文为空或超过 8 MB。'}
    end
    if not valid_utf8(body) then return nil,{code='ENCODING_ERROR',message='章节正文不是有效的 UTF-8 文本。'} end
    local value=body:gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>','')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>','')
    local decode=require('legado.lib.safe_functions').functions.htmldecode
    local Cleaner=require('legado.lib.content_cleaner')
    local style_stack,style_runs,style_char,source_cursor={},{},1,1
    local source_runs,source_mapped={},false
    local styles_valid=true
    local function style_text(chunk)
        local decoded=decode(chunk):gsub('\r\n','\n'):gsub('\r','\n')
        local length=Text.utf8Length(decoded)
        local scope=style_stack[#style_stack]
        if map_positions and length>0 and scope and scope.source_offset then
            source_runs[#source_runs+1]={first=style_char,last=style_char+length-1,
                source_first=scope.source_offset,text=decoded}
        end
        if length>0 and styles_valid then
            if #style_runs>=20000 then styles_valid=false
            else style_runs[#style_runs+1]={first=style_char,last=style_char+length-1,
                values=style_stack[#style_stack] and style_stack[#style_stack].values or {}} end
        end
        style_char=style_char+length
    end
    local original=value
    value=value:gsub('()(<%s*/?%s*([%a%d]+)[^>]*>)',function(first,raw,tag)
        style_text(original:sub(source_cursor,first-1));source_cursor=first+#raw
        tag=tag:lower()
        if tag=='img' then return nil end -- Keep image tags for the bounded block scan below.
        if raw:match('^<%s*/') then
            for index=#style_stack,1,-1 do if style_stack[index].tag==tag then
                for last=#style_stack,index,-1 do style_stack[last]=nil end;break
            end end
        elseif not ({br=true,hr=true,meta=true,link=true,input=true})[tag] and not raw:match('/%s*>$') then
            if #style_stack>=64 then styles_valid=false
            else
                local values={}
                for key,item in pairs(style_stack[#style_stack] and style_stack[#style_stack].values or {}) do values[key]=item end
                for key,item in pairs(Cleaner.paragraphStyle(tag,raw)) do values[key]=item end
                local offset=tag=='span' and Coordinates.attribute(raw) or nil
                if offset then source_mapped=true end
                style_stack[#style_stack+1]={tag=tag,values=values,source_offset=offset}
            end
        end
        if ({p=true,div=true,br=true,li=true,blockquote=true,pre=true})[tag] or tag:match('^h[1-6]$') then
            style_char=style_char+1;return '\n'
        end
        return ''
    end)
    style_text(original:sub(source_cursor))
    local paragraphs,images,paragraph_styles,source_positions={},{},{},map_positions and {} or nil
    local style_run_index=1
    local function paragraph_style(first,last)
        if not styles_valid then return nil end
        while style_runs[style_run_index] and style_runs[style_run_index].last<first do style_run_index=style_run_index+1 end
        local common
        for index=style_run_index,#style_runs do
            local run=style_runs[index]
            if run.first>last then break end
            if run.last>=first then
                if not common then common={};for key,item in pairs(run.values) do common[key]=item end
                else for key,item in pairs(common) do if run.values[key]~=item then common[key]=nil end end end
            end
        end
        return common and next(common) and common or nil
    end
    local original_char=1
    local function text_chunk(chunk)
        chunk=decode(chunk):gsub('\r\n','\n'):gsub('\r','\n')
        local cursor=1
        repeat
            local ending=chunk:find('\n',cursor,true)
            local line=chunk:sub(cursor,ending and ending-1 or #chunk)
            local trimmed=line:match('^%s*(.-)%s*$')
            if trimmed~='' then
                local index=#paragraphs+1;paragraphs[index]=trimmed
                local leading=line:find('%S') or 1
                local first=original_char+Text.utf8Length(line:sub(1,leading-1))
                local last=first+Text.utf8Length(trimmed)-1
                paragraph_styles[index]=paragraph_style(first,last)
                if source_positions then
                    source_positions[index]={first=first,last=last}
                end
            end
            original_char=original_char+Text.utf8Length(line)+(ending and 1 or 0)
            cursor=ending and ending+1 or nil
        until not cursor
    end
    local cursor,count=1,0
    while true do
        local first,last=value:find('<%s*[iI][mM][gG][^>]*>',cursor)
        if not first then text_chunk(value:sub(cursor));break end
        text_chunk(value:sub(cursor,first-1))
        local tag=value:sub(first,last)
        local src=tag:match('%s+[sS][rR][cC]%s*=%s*"([^"]+)"') or tag:match("%s+[sS][rR][cC]%s*=%s*'([^']+)'")
        local asset=src and assets and assets[src]
        count=count+1
        if not asset or count>20 then return nil,{code='STORAGE_ERROR',message='本章图片未完成缓存校验，请联网刷新章节。'} end
        local index=#paragraphs+1;paragraphs[index]='';images[index]=asset
        if source_positions then source_positions[index]=false end
        cursor=last+1
    end
    -- Invalid markup can assemble an entity across tag boundaries. Keep the
    -- established text/coordinate result and discard ambiguous metadata.
    if style_char~=original_char then paragraph_styles={};source_runs={} end
    if not images[1] and paragraphs[1]==title and #paragraphs>1 then
        table.remove(paragraphs,1);if source_positions then table.remove(source_positions,1) end
        local shifted={};for index,asset in pairs(images) do shifted[index-1]=asset end;images=shifted
        shifted={};for index,style in pairs(paragraph_styles) do if index>1 then shifted[index-1]=style end end;paragraph_styles=shifted
    end
    if #paragraphs==0 then return nil,{code='PARSE_ERROR',message='本章没有可显示的内容。'} end
    local paths={}
    for index=1,#paragraphs do
        local image=images[index]
        if image then paths[#paths+1]=table.concat({index,image.path,image.width,image.height},'\n') end
    end
    local image_key=#paths>0 and '\n'..require('legado.lib.identity').hash(table.concat(paths,'\n')) or ''
    return {title=tostring(title or ''),paragraphs=paragraphs,images=images,image_key=image_key,source_positions=source_positions,
        weread_source_runs=map_positions and (source_mapped and styles_valid and source_runs or {}) or nil,
        paragraph_styles=paragraph_styles,
        checksum=require('legado.lib.identity').hash(body)}
end

function Text.plainText(value)
    if type(value)~='string' then return '' end
    value=value:gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>','')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>','')
        :gsub('<[^>]*>','')
    return require('legado.lib.safe_functions').functions.htmldecode(value):match('^%s*(.-)%s*$')
end

local function normalized_quote(value)
    local chars,positions={},{}
    local index=0
    for char in tostring(value):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        index=index+1
        if not char:match('^%s$') and char~='　' and char~=' ' then
            chars[#chars+1]=char;positions[#positions+1]=index
        end
    end
    return table.concat(chars),positions
end

-- A quote alone cannot identify its original occurrence after an edit. Accept
-- a marker only when its zero-based, end-exclusive range also matches the
-- reconstructed original-text map. Other coordinate variants stay list-only.
local function comment_index(model)
    if model.comment_index then return model.comment_index end
    local parts,spans,offset={},{},0
    for paragraph,value in ipairs(model.paragraphs or {}) do
        -- An image has no verified source character coordinates. It must not
        -- join otherwise adjacent sentences into a false cross-block quote.
        local normalized=model.images and model.images[paragraph] and '\0' or normalized_quote(value)
        parts[#parts+1]=normalized
        if #normalized>0 then spans[#spans+1]={paragraph=paragraph,first=offset+1,last=offset+#normalized} end
        offset=offset+#normalized
    end
    model.comment_index={text=table.concat(parts),spans=spans}
    return model.comment_index
end
function Text.locateQuote(model,quote,range)
    local first,last
    if type(range)=='string' then first,last=range:match('^(%d+)%-(%d+)$') end
    if not first or not last or tonumber(first)>=tonumber(last) or tonumber(last)>8*1024*1024 then return nil end
    if model.weread_source_runs and #model.weread_source_runs==0 then return nil end
    quote=Text.plainText(quote)
    if #quote>32768 or quote:find('%z') or not valid_utf8(quote) then return nil end
    local wanted=normalized_quote(quote)
    if wanted=='' then return nil end
    local index=comment_index(model)
    local at,ending=index.text:find(wanted,1,true)
    if not at or index.text:find(wanted,at+1,true) then return nil end
    local start_span,end_span
    for _,span in ipairs(index.spans) do
        if at>=span.first and at<=span.last then start_span=span end
        if ending>=span.first and ending<=span.last then end_span=span;break end
    end
    if not start_span or not end_span then return nil end
    local function source_position(span,byte,is_last)
        local normalized,positions=normalized_quote(model.paragraphs[span.paragraph])
        local char=Text.utf8Length(normalized:sub(1,byte-span.first+(is_last and 1 or 0)))+(is_last and 0 or 1)
        local original=model.source_positions and model.source_positions[span.paragraph]
        local coordinate=original and original.first+positions[char]-1
        if coordinate and model.weread_source_runs then
            coordinate=Coordinates.offset(model.weread_source_runs,coordinate,is_last)
            if coordinate and not is_last then coordinate=coordinate+1 end
        end
        return positions[char],coordinate
    end
    local start_char,original_first=source_position(start_span,at,false)
    local end_char,original_last=source_position(end_span,ending,true)
    if original_first~=tonumber(first)+1 or original_last~=tonumber(last) then return nil end
    return {paragraph=start_span.paragraph,char=start_char,last_paragraph=end_span.paragraph,last_char=end_char,
        source_range=range,original_first=original_first,original_last=original_last}
end
function Text.metrics(model)
    if model.metrics then return model.metrics end
    local m={prefixes={},lengths={},total=0}
    for i in ipairs(model.paragraphs) do m.prefixes[i]=m.total;m.lengths[i]=Text.positionLength(model,i);m.total=m.total+m.lengths[i] end
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
