local Text=require('legado.lib.leko_text')
local Selection=require('legado.lib.leko_selection')
local Terms={}
local function ranges(value)
    local result,cursor,char,scanned={},1,1,0
    -- These are lookup hints for title phrases, not reconstructed official
    -- WeRead blue-word annotations. No dictionary requests happen here.
    while scanned<64 do
        local opening=value:find('《',cursor,true)
        if not opening then break end
        local closing=value:find('》',opening+3,true)
        if not closing then break end
        local word=value:sub(opening+3,closing-1)
        scanned=scanned+1
        char=char+Text.utf8Length(value:sub(cursor,opening-1))
        if word~='' and #word<=512 and not word:find('《',1,true) and not word:find('[%c<>]') then
            result[#result+1]={first=char+1,last=char+Text.utf8Length(word),word=word}
        end
        char=char+Text.utf8Length(value:sub(opening,closing+2));cursor=closing+3
    end
    return result
end
function Terms.targets(model,page,widgets)
    local result,seen={},{}
    model.dictionary_ranges=model.dictionary_ranges or {}
    for _,item in ipairs(widgets) do
        local line=item.element
        if line.type=='line' and not seen[line.paragraph] then
            seen[line.paragraph]=true
            local entries=model.dictionary_ranges[line.paragraph]
            if not entries then entries=ranges(model.paragraphs[line.paragraph]);model.dictionary_ranges[line.paragraph]=entries end
            for _,entry in ipairs(entries) do
                local first={chapter=1,paragraph=line.paragraph,char=entry.first}
                local last={chapter=1,paragraph=line.paragraph,char=entry.last}
                for _,rect in ipairs(Selection.rectsForRange(page,widgets,first,last)) do
                    rect.word=entry.word;result[#result+1]=rect
                end
            end
        end
    end
    return result
end
return Terms
