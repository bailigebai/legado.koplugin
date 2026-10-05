-- WeRead offsets refer to the original HTML, in JavaScript UTF-16 units.
-- Keep compact text-run annotations before removing the envelope/sanitizing.
local Coordinates={}
local ATTRIBUTE='data-legado-wr-offset'
local LIMIT=8*1024*1024
local BODY_LIMIT=4*1024*1024 -- The existing chapter cache payload limit.
local function utf16(value)
    local count=0
    for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count=count+(#char==4 and 2 or 1) end
    return count
end
function Coordinates.attribute(raw)
    local value=raw:match('data%-legado%-wr%-offset="(%d+)"')
    local offset=tonumber(value)
    if offset and offset<=LIMIT then return offset end
end
function Coordinates.body(html)
    local body,base=html,0
    local _,open_end=html:find('<[bB][oO][dD][yY][^>]*>')
    local close_start=open_end and html:find('</[bB][oO][dD][yY]%s*>',open_end+1)
    if close_start then base=utf16(html:sub(1,open_end));body=html:sub(open_end+1,close_start-1) end
    local out,count,size,exceeded={},0,0,false
    local function append(value,escaped_extra)
        size=size+#value+(escaped_extra or 0)
        if size>BODY_LIMIT then exceeded=true;return end
        out[#out+1]=value
    end
    local function emit(value,offset,mapped)
        if value=='' then return end
        count=count+1
        if count>20000 then return end
        -- The cleaner escapes bare text characters. Budget conservatively;
        -- preserved entities may cost less, but optional metadata must fit
        -- after sanitization as well as before it.
        local _,brackets=value:gsub('[<>]','')
        local _,ampersands=value:gsub('&','')
        append('<span'..(mapped and (' '..ATTRIBUTE..'="'..offset..'"') or '')..'>'..value..'</span>',
            3*brackets+4*ampersands)
    end
    local function text(chunk,offset)
        if chunk=='' then return end
        local cursor=1
        local entity,entity_end=chunk:find('&[#%w]+;')
        local line=chunk:find('[\r\n]')
        while cursor<=#chunk and count<=20000 and not exceeded do
            local first,last=entity,entity_end
            local is_line=line and (not first or line<first)
            if is_line then
                first,last=line,line
                if chunk:sub(line,line+1)=='\r\n' then last=line+1 end
            end
            if not first then emit(chunk:sub(cursor),offset,true);break end
            local prefix=chunk:sub(cursor,first-1)
            emit(prefix,offset,true);offset=offset+utf16(prefix)
            local token=chunk:sub(first,last)
            -- Hex-entity coordinates have no established official contract.
            emit(token,offset,not token:match('^&#[xX]'))
            offset=offset+utf16(token);cursor=last+1
            -- Retain each next match, including absence. Re-scanning the
            -- unconsumed suffix for every entity makes long paragraphs quadratic.
            if is_line then line=chunk:find('[\r\n]',cursor)
            else entity,entity_end=chunk:find('&[#%w]+;',cursor) end
        end
    end
    append('<span '..ATTRIBUTE..'="'..base..'"></span>')
    local cursor,offset=1,base
    while cursor<=#body do
        local first,last=body:find('<[^>]*>',cursor)
        if not first then text(body:sub(cursor),offset);break end
        local chunk=body:sub(cursor,first-1)
        text(chunk,offset);offset=offset+utf16(chunk)
        local tag=body:sub(first,last)
        -- Original attributes can also expand when escaped. Count syntactic
        -- delimiters conservatively instead of duplicating the cleaner rules.
        local _,special=tag:gsub('[<>&"]','')
        append(tag,5*special);offset=offset+utf16(tag);cursor=last+1
        if count>20000 or exceeded then break end
    end
    if count>20000 or exceeded then return body end -- Metadata limits never block reading.
    return table.concat(out)
end
function Coordinates.offset(runs,character,is_last)
    local low,high=1,#runs
    while low<=high do
        local middle=math.floor((low+high)/2);local run=runs[middle]
        if character<run.first then high=middle-1
        elseif character>run.last then low=middle+1
        else
            local wanted,index,offset=character-run.first+1,0,run.source_first
            for char in run.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
                index=index+1
                if index==wanted then return offset+(is_last and (#char==4 and 2 or 1) or 0) end
                offset=offset+(#char==4 and 2 or 1)
            end
            return nil
        end
    end
end
return Coordinates
