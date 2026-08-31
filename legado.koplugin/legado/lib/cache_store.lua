local Errors = require("legado.lib.errors")
local Fs = require("legado.lib.fs")
local Identity = require("legado.lib.identity")
local Json = require("legado.lib.json_codec")

local CacheStore = {}; CacheStore.__index = CacheStore
CacheStore.VERSION, CacheStore.MAX_BODY_BYTES = 2, 4 * 1024 * 1024
local extensions = { chapters = ".body", html = ".html", catalog = ".json", cover = ".img" }
local function safe_id(v) return type(v) == "string" and v:match("^[%w_-]+$") and v or nil end
local function utf8(v)
    local i, n = 1, #v
    while i <= n do
        local b = v:byte(i); local w = b < 0x80 and 1 or (b >= 0xC2 and b <= 0xDF and 2 or (b >= 0xE0 and b <= 0xEF and 3 or (b >= 0xF0 and b <= 0xF4 and 4 or 0)))
        if w == 0 or i + w - 1 > n then return false end
        local c = w > 1 and v:byte(i + 1) or 0
        if (w == 3 and ((b == 0xE0 and c < 0xA0) or (b == 0xED and c > 0x9F))) or (w == 4 and ((b == 0xF0 and c < 0x90) or (b == 0xF4 and c > 0x8F))) then return false end
        for j = 2, w do c = v:byte(i + j - 1); if c < 0x80 or c > 0xBF then return false end end
        i = i + w
    end
    return true
end
local function hex(v) return (v:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(v) if type(v) ~= "string" or #v % 2 ~= 0 or v:find("[^%da-fA-F]") then return nil end return (v:gsub("..", function(p) return string.char(tonumber(p, 16)) end)) end
local function encode(v)
    if v == nil then return "null" elseif type(v) == "boolean" then return v and "true" or "false" elseif type(v) == "number" then return tostring(v) elseif type(v) == "string" then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"' end
    local array, count = true, 0; for k in pairs(v) do count = count + 1; if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then array = false end end
    local out = {}; if array then for i = 1, count do out[i] = encode(v[i]) end; return "[" .. table.concat(out, ",") .. "]" end
    local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end; table.sort(keys); for _, k in ipairs(keys) do out[#out + 1] = encode(tostring(k)) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
function CacheStore.new(o) o = o or {}; assert(type(o.root) == "string" and o.root ~= "", "CacheStore requires root"); local self = setmetatable({ fs = o.fs or Fs.new(), root = o.root:gsub("[/\\]+$", ""), quarantine = o.quarantine ~= false }, CacheStore); self.fs:ensureDirectory(self.root); return self end
function CacheStore:_path(s,b,kind,chapter)
    if not extensions[kind] then return nil, Errors.new(Errors.INVALID_INPUT, "unknown cache kind") end; s,b = safe_id(s),safe_id(b); if not s or not b then return nil, Errors.new(Errors.INVALID_INPUT, "cache ids must be opaque") end
    local pieces={s,b,kind}; if chapter then local uid=safe_id(type(chapter)=="table" and chapter.uid or chapter); if not uid then return nil, Errors.new(Errors.INVALID_INPUT,"chapter uid must be opaque") end; pieces[#pieces+1]=uid end
    local path,err=self.fs:join(self.root,unpack(pieces)); if not path then return nil,err end; path=path..extensions[kind]
    local root=self.root:gsub("\\","/").."/"; if path:gsub("\\","/"):sub(1,#root)~=root then return nil,Errors.new(Errors.INVALID_INPUT,"cache path escapes root") end
    local lfs=self.fs.lfs; if lfs and type(lfs.symlinkattributes)=="function" then local ancestor=self.root; local info=lfs.symlinkattributes(ancestor); if info and info.mode=="link" then return nil,Errors.new(Errors.INVALID_INPUT,"cache root is a symlink") end; for _,piece in ipairs(pieces) do ancestor=ancestor.."/"..piece; info=lfs.symlinkattributes(ancestor); if info and info.mode=="link" then return nil,Errors.new(Errors.INVALID_INPUT,"cache path contains symlink") end end end
    return path
end
function CacheStore:path(s,b,k,c,e) if e and e~=extensions[k] then return nil,Errors.new(Errors.INVALID_INPUT,"cache extension is fixed") end return self:_path(s,b,k,c) end
function CacheStore:_write(s,b,k,c,content)
    if type(content)~="string" or #content>self.MAX_BODY_BYTES then return nil,Errors.new(Errors.RESPONSE_TOO_LARGE,"invalid cache payload") end; if k~="cover" and not utf8(content) then return nil,Errors.new(Errors.ENCODING_ERROR,"cache payload is not UTF-8") end
    local path,err=self:_path(s,b,k,c); if not path then return nil,err end; local stored=k=="cover" and hex(content) or content
    local envelope=encode({version=self.VERSION,kind=k,source_id=s,book_id=b,chapter_uid=c and c.uid or nil,bytes=#content,checksum=Identity.hash(content),content=stored})
    local ok,write_err=self.fs:atomicWrite(path,envelope); if not ok then return nil,write_err end; return path
end
function CacheStore:_read(s,b,k,c)
    local path,err=self:_path(s,b,k,c); if not path then return nil,err end; local raw=self.fs:readBounded(path,self.MAX_BODY_BYTES*3); if not raw then return nil,Errors.new(Errors.STORAGE_ERROR,"cache entry unavailable",{path=path}) end
    local ok,entry=pcall(Json.decode,raw); local content=ok and type(entry)=="table" and entry.content or nil; if k=="cover" then content=unhex(content) end
    if type(content)~="string" or entry.version~=self.VERSION or entry.kind~=k or entry.source_id~=s or entry.book_id~=b or entry.chapter_uid~=(c and c.uid or nil) or entry.bytes~=#content or entry.checksum~=Identity.hash(content) or (k~="cover" and not utf8(content)) then if self.quarantine then self.fs:removeFile(path) end; return nil,Errors.new(Errors.STORAGE_ERROR,"cache entry failed integrity validation",{path=path}) end
    return content,path
end
function CacheStore:writeBody(s,b,c,v) return self:_write(s,b,"chapters",c,v) end; function CacheStore:readBody(s,b,c) return self:_read(s,b,"chapters",c) end
function CacheStore:writeHtml(s,b,c,v) return self:_write(s,b,"html",c,v) end; function CacheStore:readHtml(s,b,c) return self:_read(s,b,"html",c) end
function CacheStore:writeCover(s,b,v) return self:_write(s,b,"cover",nil,v) end; function CacheStore:readCover(s,b) return self:_read(s,b,"cover",nil) end
function CacheStore:writeCatalog(s,b,catalog) return self:_write(s,b,"catalog",nil,encode(catalog)) end
function CacheStore:readCatalog(s,b)
    local value,err=self:_read(s,b,"catalog",nil); if not value then return nil,err end; local ok,catalog=pcall(Json.decode,value); local chapters=ok and type(catalog)=="table" and (catalog.chapters or catalog) or nil
    if type(chapters)~="table" or #chapters>100000 then return nil,Errors.new(Errors.STORAGE_ERROR,"invalid cached catalog") end
    for i,ch in ipairs(chapters) do if type(ch)~="table" or not safe_id(ch.uid) or ch.source_id~=s or ch.book_id~=b or type(ch.url)~="string" or type(ch.title)~="string" then return nil,Errors.new(Errors.STORAGE_ERROR,"cached catalog ownership mismatch",{index=i}) end end
    return catalog
end
return CacheStore
