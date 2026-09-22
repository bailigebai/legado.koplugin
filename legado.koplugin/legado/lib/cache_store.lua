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
function CacheStore.new(o)
    o = o or {}; assert(type(o.root) == "string" and o.root ~= "", "CacheStore requires root")
    local self = setmetatable({ fs = o.fs or Fs.new(), root = o.root:gsub("[/\\]+$", ""), quarantine = o.quarantine ~= false, encoder = o.encoder or Json.encode, max_catalog_chapters = o.max_catalog_chapters or 100000, settings = o.settings, scheduler = o.scheduler, pending_keep = {} }, CacheStore)
    local valid, validation_error = self:_validatePath(self.root)
    if not valid then self.init_error = validation_error; return self end
    local ensured, ensure_error = self.fs:ensureDirectory(self.root)
    if not ensured then self.init_error = ensure_error; return self end
    valid, validation_error = self:_validatePath(self.root)
    if not valid then self.init_error = validation_error; return self end
    if type(self.fs.identity)=="function" then self.root_identity=self.fs:identity(self.root) end
    if jit and jit.os~="Windows" and not self.root_identity then
        self.init_error=Errors.new(Errors.STORAGE_ERROR,"cache root identity unavailable")
    end
    return self
end
local linked
function CacheStore:_scan()
    local lfs = self.fs and self.fs.lfs
    if self.init_error then return nil,self.init_error end
    if not lfs or not lfs.dir or not lfs.symlinkattributes then return nil,Errors.new(Errors.STORAGE_ERROR,"cache directory scan unavailable") end
    local valid,err=self:_validatePath(self.root);if not valid then return nil,err end
    local identity=self.fs.identity and self.fs:identity(self.root)
    if self.root_identity and (not identity or identity.dev~=self.root_identity.dev or identity.ino~=self.root_identity.ino) then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cache root identity changed')
    end
    local files={}
    local function walk(path,relative,depth)
        for name in lfs.dir(path) do
            if name~='.' and name~='..' then
                local child=path..'/'..name;local rel=relative=='' and name or relative..'/'..name
                local attr=lfs.symlinkattributes(child)
                if linked(attr) then error('linked cache entry') end
                if attr and attr.mode=='directory' and depth<4 and name:match('^[%w_-]+$') then walk(child,rel,depth+1)
                elseif attr and attr.mode=='file' and (
                    rel:match('^[%w_-]+/[%w_-]+/chapters/[%w_-]+%.body$') or
                    rel:match('^[%w_-]+/[%w_-]+/html/[%w_-]+%.html$') or
                    rel:match('^[%w_-]+/[%w_-]+/cover%.img$') or
                    rel:match('^[%w_-]+/[%w_-]+/catalog%.json$')) then
                    files[#files+1]={path=child,relative=rel,size=tonumber(attr.size) or 0,mtime=tonumber(attr.modification) or 0,
                        removable=not rel:match('/catalog%.json$')}
                end
            end
        end
    end
    local ok,cause=pcall(walk,self.root,'',0)
    if not ok then return nil,Errors.new(Errors.STORAGE_ERROR,'cache scan failed; nothing removed',{cause=tostring(cause)}) end
    return files
end
function CacheStore:usage()
    local files,err=self:_scan();if not files then self.known_bytes=nil;return nil,err end
    self:_rememberUsage(files)
    return {bytes=self.known_bytes,files=#files}
end
function CacheStore:_rememberUsage(files)
    self.known_bytes,self.known_sizes=0,{}
    for _,entry in ipairs(files) do
        self.known_bytes=self.known_bytes+entry.size;self.known_sizes[entry.path]=entry.size
    end
end
function CacheStore:setActive(keep) self.active_keep=keep end
local function book_prefix(keep)
    return keep and keep.source_id and keep.book_id and (keep.source_id..'/'..keep.book_id..'/') or nil
end
function CacheStore:_protected(entry,keep)
    local active,explicit=book_prefix(self.active_keep),book_prefix(keep)
    if (active and entry.relative:sub(1,#active)==active) or (explicit and entry.relative:sub(1,#explicit)==explicit) then return true end
    local book=entry.relative:match('^([^/]+/[^/]+/)')
    return self.pending_keep[book]==true
end
function CacheStore:enforceLimit(limit_mb,threshold_mb,retain_mb,keep)
    local files,err=self:_scan();if not files then self.known_bytes=nil;return nil,err end
    self:_rememberUsage(files)
    local limit=math.max(0,tonumber(limit_mb) or 500)*1024*1024
    local threshold=math.max(0,tonumber(threshold_mb) or 300)*1024*1024
    local retain=math.max(0,tonumber(retain_mb) or 200)*1024*1024
    if threshold>limit then threshold=limit end;if retain>threshold then retain=threshold end
    local bytes=0;for _,entry in ipairs(files) do bytes=bytes+entry.size end
    if bytes<=threshold then return {bytes=bytes,removed=0,files=#files} end
    table.sort(files,function(a,b) if a.mtime==b.mtime then return a.relative<b.relative end return a.mtime<b.mtime end)
    local removed=0
    for _,entry in ipairs(files) do
        if bytes<=retain then break end
        if entry.removable and not self:_protected(entry,keep) then
            local valid,path_error=self:_validatePath(entry.path);if not valid then self.known_bytes=nil;return nil,path_error end
            local ok,remove_err=self.fs:removeFile(entry.path);if not ok then self.known_bytes=nil;return nil,remove_err end
            bytes=bytes-entry.size;removed=removed+1
            self.known_bytes=bytes;self.known_sizes[entry.path]=nil
        end
    end
    return {bytes=bytes,removed=removed,files=#files}
end
function CacheStore:_limits()
    local function value(key,default)
        local result=type(self.settings.get)=='function' and self.settings:get(key) or self.settings[key]
        return math.max(0,tonumber(result) or default)*1024*1024
    end
    local limit=value('cache_limit_mb',500)
    local threshold=math.min(limit,value('cache_cleanup_threshold_mb',300))
    return limit,threshold,math.min(threshold,value('cache_retain_mb',200))
end
function CacheStore:_cleanup(threshold_override)
    local ok,result,err=pcall(function()
        local limit,threshold,retain=self:_limits()
        threshold=math.min(threshold,threshold_override or threshold)
        return self:enforceLimit(limit/1048576,threshold/1048576,math.min(retain,threshold)/1048576,self.active_keep)
    end)
    if not ok then err=Errors.new(Errors.STORAGE_ERROR,'automatic cache cleanup failed',{cause=tostring(result)});result=nil end
    self.last_cleanup_error=result and nil or err
    if not result then self.known_bytes=nil end
    return result,err
end
function CacheStore:_beforeWrite(path,size)
    if not self.settings then return true end
    if not self.known_bytes then local result,err=self:_cleanup();if not result then return nil,err end end
    local limit=self:_limits()
    local growth=size-(self.known_sizes[path] or 0)
    if self.known_bytes+growth>limit or self.known_bytes>=limit*0.9 then
        local result,err=self:_cleanup(math.max(0,limit-math.max(0,growth)))
        if not result then return nil,err end
        growth=size-(self.known_sizes[path] or 0)
    end
    if self.known_bytes+growth>limit then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cache hard limit reached; active reading files were preserved',{reason='cache_limit'})
    end
    return true
end
function CacheStore:_afterWrite(path,size)
    if self.known_bytes then
        self.known_bytes=self.known_bytes-(self.known_sizes[path] or 0)+size;self.known_sizes[path]=size
    end
    if not self.settings then self.pending_keep={};return end
    local function cleanup()
        self.cleanup_scheduled=nil
        self:_cleanup()
        self.pending_keep={}
    end
    if self.scheduler and type(self.scheduler.scheduleIn)=='function' then
        if self.cleanup_scheduled then return end
        self.cleanup_scheduled=true
        local ok,err=pcall(self.scheduler.scheduleIn,self.scheduler,0,cleanup)
        if not ok then
            cleanup()
            self.last_cleanup_error=self.last_cleanup_error or Errors.new(Errors.STORAGE_ERROR,'cache cleanup scheduling failed',{cause=tostring(err)})
        end
    else
        local _,threshold=self:_limits()
        if self.known_bytes and self.known_bytes>threshold then cleanup() else self.pending_keep={} end
    end
end
function CacheStore:_store(path,payload,s,b)
    local book=s..'/'..b..'/'
    local already_pending=self.pending_keep[book]
    self.pending_keep[book]=true
    local checked,admitted,err=pcall(self._beforeWrite,self,path,#payload)
    if not checked then
        err=Errors.new(Errors.STORAGE_ERROR,'cache capacity check failed',{cause=tostring(admitted)});admitted=nil
        self.known_bytes=nil;self.last_cleanup_error=err
    end
    if not admitted then self.pending_keep[book]=already_pending;return nil,err end
    local called,ok,write_err=pcall(self.fs.atomicWrite,self.fs,path,payload,{root=self.root,root_identity=self.root_identity,validate=function(candidate) return self:_validatePath(candidate) end})
    if not called then write_err=Errors.new(Errors.STORAGE_ERROR,'cache write failed',{cause=tostring(ok)});ok=nil end
    if not ok then self.pending_keep[book]=already_pending;return nil,write_err end
    local maintained,maintenance_error=pcall(self._afterWrite,self,path,#payload)
    if not maintained then
        self.known_bytes=nil;self.pending_keep={}
        self.last_cleanup_error=Errors.new(Errors.STORAGE_ERROR,'cache maintenance failed',{cause=tostring(maintenance_error)})
    end
    return path
end
local function path_prefixes(path)
    local normalized=path:gsub("\\","/")
    local prefix,rest="",normalized
    if rest:sub(1,2)=="//" then prefix,rest="//",rest:sub(3)
    elseif rest:match("^%a:/") then prefix,rest=rest:sub(1,3),rest:sub(4)
    elseif rest:sub(1,1)=="/" then prefix,rest="/",rest:sub(2) end
    local output,current={},prefix
    for part in rest:gmatch("[^/]+") do
        if current=="" then current=part elseif current=="/" or current=="//" or current:match("^%a:/$") then current=current..part else current=current.."/"..part end
        output[#output+1]=current
    end
    return output
end
linked = function(attributes)
    return attributes and (attributes.mode=="link" or attributes.reparse_point==true or attributes.is_reparse_point==true or attributes.reparse_tag~=nil)
end
function CacheStore:_validatePath(path)
    local root=self.fs.canonicalize and self.fs:canonicalize(self.root) or self.root:gsub("\\","/")
    local target=self.fs.canonicalize and self.fs:canonicalize(path) or path:gsub("\\","/")
    if type(root)~="string" or type(target)~="string" then return nil,Errors.new(Errors.INVALID_INPUT,"cache path cannot be canonicalized") end
    root=root:gsub("/+$",""); target=target:gsub("/+$","")
    local compare_root,compare_target=root,target
    if root:match("^%a:") or root:sub(1,2)=="//" then compare_root,compare_target=root:lower(),target:lower() end
    if compare_target~=compare_root and compare_target:sub(1,#compare_root+1)~=compare_root.."/" then return nil,Errors.new(Errors.INVALID_INPUT,"cache path escapes canonical root") end
    local lfs=self.fs.lfs
    if lfs then
        local checked={}
        for _,candidate in ipairs(path_prefixes(self.root)) do checked[candidate]=true end
        for _,candidate in ipairs(path_prefixes(path)) do checked[candidate]=true end
        for candidate in pairs(checked) do
            local info=type(lfs.symlinkattributes)=="function" and lfs.symlinkattributes(candidate) or nil
            if not info and type(lfs.attributes)=="function" then info=lfs.attributes(candidate) end
            if linked(info) then return nil,Errors.new(Errors.INVALID_INPUT,"cache path contains link or reparse point") end
        end
    end
    return true
end
function CacheStore:_path(s,b,kind,chapter)
    if self.init_error then return nil,self.init_error end
    if not extensions[kind] then return nil, Errors.new(Errors.INVALID_INPUT, "unknown cache kind") end; s,b = safe_id(s),safe_id(b); if not s or not b then return nil, Errors.new(Errors.INVALID_INPUT, "cache ids must be opaque") end
    local pieces={s,b,kind}; if chapter then local uid=safe_id(type(chapter)=="table" and chapter.uid or chapter); if not uid then return nil, Errors.new(Errors.INVALID_INPUT,"chapter uid must be opaque") end; pieces[#pieces+1]=uid end
    local path,err=self.fs:join(self.root,unpack(pieces)); if not path then return nil,err end; path=path..extensions[kind]
    local valid,validation_error=self:_validatePath(path); if not valid then return nil,validation_error end
    return path
end
function CacheStore:path(s,b,k,c,e) if e and e~=extensions[k] then return nil,Errors.new(Errors.INVALID_INPUT,"cache extension is fixed") end return self:_path(s,b,k,c) end
function CacheStore:_write(s,b,k,c,content)
    if type(content)~="string" or #content>self.MAX_BODY_BYTES then return nil,Errors.new(Errors.RESPONSE_TOO_LARGE,"invalid cache payload") end; if k~="cover" and not utf8(content) then return nil,Errors.new(Errors.ENCODING_ERROR,"cache payload is not UTF-8") end
    local path,err=self:_path(s,b,k,c); if not path then return nil,err end; local stored=k=="cover" and hex(content) or content
    local expected={version=self.VERSION,kind=k,source_id=s,book_id=b,chapter_uid=c and c.uid or nil,bytes=#content,checksum=Identity.hash(content),content=stored}
    local encoded_ok,envelope=pcall(self.encoder,expected)
    local decoded_ok,decoded=false,nil
    if encoded_ok and type(envelope)=="string" then decoded_ok,decoded=pcall(Json.decode,envelope) end
    if not encoded_ok or not decoded_ok or type(decoded)~="table" or decoded.version~=expected.version or decoded.kind~=expected.kind
        or decoded.source_id~=expected.source_id or decoded.book_id~=expected.book_id or decoded.chapter_uid~=expected.chapter_uid
        or decoded.bytes~=expected.bytes or decoded.checksum~=expected.checksum or decoded.content~=expected.content then
        return nil,Errors.new(Errors.STORAGE_ERROR,"cache envelope failed self-validation")
    end
    return self:_store(path,envelope,s,b)
end
function CacheStore:_read(s,b,k,c)
    local path,err=self:_path(s,b,k,c); if not path then return nil,err end; local raw=self.fs:readBounded(path,self.MAX_BODY_BYTES*3); if not raw then return nil,Errors.new(Errors.STORAGE_ERROR,"cache entry unavailable",{path=path}) end
    local ok,entry=pcall(Json.decode,raw); local content=ok and type(entry)=="table" and entry.content or nil; if k=="cover" then content=unhex(content) end
    if type(content)~="string" or entry.version~=self.VERSION or entry.kind~=k or entry.source_id~=s or entry.book_id~=b or entry.chapter_uid~=(c and c.uid or nil) or entry.bytes~=#content or entry.checksum~=Identity.hash(content) or (k~="cover" and not utf8(content)) then if self.quarantine then self.fs:removeFile(path) end; return nil,Errors.new(Errors.STORAGE_ERROR,"cache entry failed integrity validation",{path=path}) end
    return content,path
end
function CacheStore:writeBody(s,b,c,v) return self:_write(s,b,"chapters",c,v) end; function CacheStore:readBody(s,b,c) return self:_read(s,b,"chapters",c) end
function CacheStore:writeHtml(s,b,c,v)
    if type(v)~="string" or #v>self.MAX_BODY_BYTES then return nil,Errors.new(Errors.RESPONSE_TOO_LARGE,"invalid cache payload") end
    if not utf8(v) then return nil,Errors.new(Errors.ENCODING_ERROR,"cache payload is not UTF-8") end
    local path,err=self:_path(s,b,"html",c); if not path then return nil,err end
    return self:_store(path,v,s,b)
end
function CacheStore:readHtml(s,b,c)
    local path,err=self:_path(s,b,"html",c); if not path then return nil,err end
    local value,read_err=self.fs:readBounded(path,self.MAX_BODY_BYTES); if not value then return nil,read_err end
    if not utf8(value) then return nil,Errors.new(Errors.ENCODING_ERROR,"cache payload is not UTF-8") end
    return value,path
end
function CacheStore:writeCover(s,b,v) return self:_write(s,b,"cover",nil,v) end; function CacheStore:readCover(s,b) return self:_read(s,b,"cover",nil) end
function CacheStore:clear(keep)
    self.known_bytes=nil
    local files,err=self:_scan();if not files then return nil,err end
    local count=0
    for _,entry in ipairs(files) do
        if entry.removable and not self:_protected(entry,keep) then
            local safe,path_error=self:_validatePath(entry.path);if not safe then return nil,path_error end
            local removed,remove_error=self.fs:removeFile(entry.path);if not removed then return nil,remove_error end;count=count+1
        end
    end
    return count
end
function CacheStore:_validateCatalog(s,b,catalog,decoded)
    local chapters = type(catalog)=="table" and (catalog.chapters~=nil and catalog.chapters or catalog) or nil
    if type(chapters)~="table" or (decoded and not Json.isArray(chapters)) then return nil,Errors.new(Errors.STORAGE_ERROR,"cached catalog chapters must be a JSON array") end
    local count,maximum=0,0
    for key in pairs(chapters) do
        if type(key)~="number" or key%1~=0 or key<1 then return nil,Errors.new(Errors.STORAGE_ERROR,"cached catalog must be a dense array") end
        count,maximum=count+1,math.max(maximum,key)
    end
    if count~=maximum or count>self.max_catalog_chapters then return nil,Errors.new(Errors.STORAGE_ERROR,count>self.max_catalog_chapters and "cached catalog exceeds chapter limit" or "cached catalog must be a dense array") end
    local seen={}
    for index=1,count do
        local chapter=chapters[index]
        if type(chapter)~="table" or not safe_id(chapter.uid) or #chapter.uid>128 or seen[chapter.uid]
            or type(chapter.index)~="number" or chapter.index%1~=0 or chapter.index~=index
            or chapter.source_id~=s or chapter.book_id~=b
            or type(chapter.url)~="string" or #chapter.url==0 or #chapter.url>8192
            or type(chapter.title)~="string" or #chapter.title>1024 then
            return nil,Errors.new(Errors.STORAGE_ERROR,"cached catalog chapter schema mismatch",{index=index})
        end
        seen[chapter.uid]=true
    end
    return chapters
end
function CacheStore:writeCatalog(s,b,catalog)
    local chapters,validation_error=self:_validateCatalog(s,b,catalog,false)
    if not chapters then return nil,validation_error end
    Json.array(chapters)
    return self:_write(s,b,"catalog",nil,Json.encode(catalog))
end
function CacheStore:readCatalog(s,b)
    local value,err=self:_read(s,b,"catalog",nil); if not value then return nil,err end; local ok,catalog=pcall(Json.decode,value)
    local chapters,validation_error
    if ok then chapters,validation_error=self:_validateCatalog(s,b,catalog,true)
    else validation_error=Errors.new(Errors.STORAGE_ERROR,"invalid cached catalog JSON") end
    if not chapters then
        if self.quarantine then local path=self:_path(s,b,"catalog",nil); if path then self.fs:removeFile(path) end end
        return nil,validation_error
    end
    return catalog
end
return CacheStore
