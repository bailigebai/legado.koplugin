local Text=require('legado.lib.leko_text')
local Dictionary={}
function Dictionary.word(value)
    if type(value)~='string' then return nil end
    value=value:match('^%s*(.-)%s*$')
    value=value:match('^《(.-)》$') or value
    if value=='' or #value>512 or value:find('[%c<>]') then return nil end
    return value
end
function Dictionary.definition(wire)
    if type(wire)~='table' or (tonumber(wire.status)~=1 and tonumber(wire.status)~=0) then
        return nil,'微信读书词典返回格式无效，请重试。'
    end
    local function empty()
        return {text='微信读书词典暂未收录这个词条的说明。可长按选择更短的词语再查询。',source='微信读书词典',empty=true}
    end
    if tonumber(wire.status)==0 then return empty() end
    local pieces,bytes={},0
    local function add(value)
        if type(value)=='string' and #value<=64*1024 then
            value=Text.plainText(value)
            if value~='' and bytes+#value<=64*1024 then pieces[#pieces+1]=value;bytes=bytes+#value end
        end
    end
    add(wire.baike)
    local encyclopedia=#pieces>0
    if not encyclopedia then
        local results=type(wire.message)=='table' and wire.message.result
        if type(results)=='table' then
            for index=1,math.min(#results,20) do
                local row=results[index]
                if type(row)=='table' then
                    add(row.mean)
                    if type(row.means)=='table' then
                        for at=1,math.min(#row.means,20) do
                            if type(row.means[at])=='table' then add(row.means[at].mean) end
                        end
                    end
                end
            end
        end
    end
    if #pieces==0 then return empty() end
    local source=encyclopedia and tonumber(wire.source)==1 and '微信读书词典 · 搜狗百科' or '微信读书词典'
    return {text=table.concat(pieces,'\n\n'),source=source}
end
return Dictionary
