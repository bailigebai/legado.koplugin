-- WeRead Web chapter protocol. Adapted from AnkioTomas/moon (AGPL-3.0-or-later).
-- Kept independent of UI and storage so protocol changes have one boundary.
local bit=require('bit')
local Safe=require('legado.lib.safe_functions').functions
local native,native_sha2=pcall(require,'ffi/sha2')
local md5=native and native_sha2.md5 or Safe.md5
local Protocol={}

function Protocol.encode(value)
    local input=tostring(value)
    local digest=md5(input)
    local output=digest:sub(1,3)..(input:match('^%d+$') and '3' or '4')..'2'..digest:sub(-2)
    local chunks={}
    if input:match('^%d+$') then
        for at=1,#input,9 do chunks[#chunks+1]=string.format('%x',tonumber(input:sub(at,at+8))) end
    else
        chunks[1]=(input:gsub('.',function(char) return string.format('%x',char:byte()) end))
    end
    for index,chunk in ipairs(chunks) do
        output=output..string.format('%02x',#chunk)..chunk
        if index<#chunks then output=output..'g' end
    end
    if #output<20 then output=output..digest:sub(1,20-#output) end
    return output..md5(output):sub(1,3)
end

local function query(params)
    local keys,values={},{}
    for key in pairs(params) do if key~='s' then keys[#keys+1]=key end end
    table.sort(keys)
    for _,key in ipairs(keys) do
        local value=params[key]
        if value==nil then value='null' elseif value==true then value='true' elseif value==false then value='false' end
        values[#values+1]=key..'='..Safe.urlencode(value)
    end
    return table.concat(values,'&')
end
function Protocol.sign(value)
    local a,b=0x15051505,0x15051505
    local length=#value
    for index=length,2,-2 do
        a=bit.band(bit.bxor(a,bit.lshift(value:byte(index),(length-index+1)%30)),0x7fffffff)
        b=bit.band(bit.bxor(b,bit.lshift(value:byte(index-1),(index-1)%30)),0x7fffffff)
    end
    return string.format('%x',a+b):lower()
end
function Protocol.readerUrl(book_id,chapter_uid)
    return 'https://weread.qq.com/web/reader/'..Protocol.encode(book_id)..'k'..Protocol.encode(chapter_uid)
end
function Protocol.contentParams(book_id,chapter_uid,now,psvts)
    now=now or os.time()
    local ct=now
    assert(type(psvts)=='string' and psvts~='', 'reader psvts is required')
    if Protocol.encode(ct)==psvts then ct=ct+1 end
    local params={b=Protocol.encode(book_id),c=Protocol.encode(chapter_uid),
        r=tostring(math.random(0,9999)^2),ct=tostring(ct),ps=psvts,pc=Protocol.encode(ct),
        sc=1,prevChapter=false,st=0}
    params.s=Protocol.sign(query(params))
    return params
end

local function positions(encoded)
    local length=#encoded
    if length<4 then return {} end
    if length<11 then return {0,2} end
    local n=math.min(4,math.floor((length+9)/10))
    local tail={}
    for at=length,length-n+1,-1 do
        local byte=encoded:byte(at)
        local bits={}
        repeat table.insert(bits,1,tostring(byte%2));byte=math.floor(byte/2) until byte==0
        tail[#tail+1]=tostring(tonumber(table.concat(bits),4) or 0)
    end
    local packed=table.concat(tail)
    local result,modulus,step={},length-n-2,#tostring(length-n-2)
    local at=1
    while #result<10 and at+step-1<#packed do
        result[#result+1]=(tonumber(packed:sub(at,at+step-1)) or 0)%modulus
        if at+1<=#packed then result[#result+1]=(tonumber(packed:sub(at+1,math.min(at+step,#packed))) or 0)%modulus end
        at=at+step
    end
    return result
end

local function unswap(encoded,at)
    local patched={}
    local function character(index) return patched[index] or encoded:sub(index,index) end
    for index=#at,1,-2 do
        for offset=1,0,-1 do
            local left,right=at[index]+offset+1,at[index-1]+offset+1
            patched[left],patched[right]=character(right),character(left)
        end
    end
    if not next(patched) then return encoded end
    local touched={}
    for index in pairs(patched) do touched[#touched+1]=index end
    table.sort(touched)
    local parts,cursor={},1
    for _,index in ipairs(touched) do
        if index>cursor then parts[#parts+1]=encoded:sub(cursor,index-1) end
        parts[#parts+1]=patched[index]
        cursor=index+1
    end
    parts[#parts+1]=encoded:sub(cursor)
    return table.concat(parts)
end

function Protocol.decodeShards(...)
    local pieces={}
    for index=1,select('#',...) do
        local raw=select(index,...)
        if raw and raw~='' then
            if type(raw)~='string' or #raw<=32 then return nil,'分片过短' end
            local expected,body=raw:sub(1,32),raw:sub(33)
            if md5(body):upper()~=expected then return nil,'分片校验失败' end
            pieces[#pieces+1]=body
        end
    end
    if #pieces==0 then return nil,'章节内容为空' end
    local combined=table.concat(pieces)
    local encoded=combined:sub(2)
    local restored=unswap(encoded,positions(encoded)):gsub('-','+'):gsub('_','/')
    local padding=#restored%4
    if padding==1 then return nil,'章节解码失败' end
    if padding~=0 then restored=restored..string.rep('=',4-padding) end
    local ok,decoded=pcall(Safe.base64decode,restored)
    if not ok or type(decoded)~='string' then return nil,'章节解码失败' end
    return decoded
end

return Protocol
