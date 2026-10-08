local Identity=require('legado.lib.identity')
local Markdown={}
local function text(value)
    return tostring(value or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
        :gsub('([\\`*_{}%[%]#!|])','\\%1')
end
local function line(value) return text(value):gsub('[%c]',' ') end
local function filename(value)
    value=tostring(value or ''):gsub('[%c/\\:*?"<>|%.]','_'):gsub(' +$','')
    -- UTF-8 safe boundary; leave room for a stable book identifier.
    local cut=math.min(#value,96)
    while cut>0 and value:byte(cut+1) and value:byte(cut+1)>=128 and value:byte(cut+1)<192 do cut=cut-1 end
    value=value:sub(1,cut)
    if value=='' then value='未命名书籍' end
    if value:upper():match('^CON$') or value:upper():match('^PRN$') or value:upper():match('^AUX$')
        or value:upper():match('^NUL$') or value:upper():match('^COM%d$') or value:upper():match('^LPT%d$') then value='_'..value end
    return value
end
function Markdown.folder(value)
    if type(value)~='string' or value=='' or #value>240 or value:find('[%c\\:*?"<>|%%]')
        or value:sub(1,1)=='/' or value:sub(-1)=='/' or value:find('//',1,true) then return nil end
    for part in value:gmatch('[^/]+') do
        if part=='.' or part=='..' or part:sub(-1)=='.' or part:sub(-1)==' ' or part:sub(1,1)=='.' then return nil end
    end
    return value
end
function Markdown.path(row,folder)
    if not Markdown.folder(folder) or not tostring(row.id or ''):match('^[%w%-]+$') then return nil end
    return folder..'/'..filename(row.title)..'-'..Identity.hash(row.book_key)..'/'..row.id..'.md'
end
function Markdown.marker(row) return '<!-- legado-excerpt:'..row.id..' -->' end
function Markdown.render(row)
    local quote=text(row.quote):gsub('\r\n','\n'):gsub('\r','\n'):gsub('\n','\n> ')
    return Markdown.marker(row)..'\n\n# '..line(row.title)..' · 摘录\n\n> '..quote..'\n\n'
        ..'- 作者：'..line(row.author)..'\n- 来源：'..line(row.source)..'\n- 章节：'..line(row.chapter)
        ..'\n- 位置：'..line(row.location)..'\n- 摘录时间：'..line(row.captured_at)..'\n\n## 我的想法\n\n'
end
return Markdown
