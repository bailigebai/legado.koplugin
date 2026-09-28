local Errors=require('legado.lib.errors')
local Management={}
Management.__index=Management

function Management.new(options)
    options=options or {}
    return setmetatable({reading=options.reading,offline=options.offline,
        fs=options.fs,covers_root=options.covers_root,cover_loader=options.cover_loader},Management)
end

local function covers(self,remove)
    local fs,root=self.fs,self.covers_root
    local lfs=fs and fs.lfs
    if not root or not lfs or type(lfs.dir)~='function' or type(lfs.symlinkattributes)~='function' then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cover cache scan unavailable')
    end
    local root_attr=lfs.symlinkattributes(root)
    if not root_attr or root_attr.mode~='directory' or root_attr.reparse_point then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cover cache root unavailable')
    end
    if remove and self.cover_loader and next(self.cover_loader.pending or {}) then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cover downloads are active')
    end
    local entries={}
    for name in lfs.dir(root) do
        if name~='.' and name~='..' then
            local path=root..'/'..name
            local attr=lfs.symlinkattributes(path)
            if attr and (attr.mode=='link' or attr.reparse_point or attr.is_reparse_point) then
                return nil,Errors.new(Errors.STORAGE_ERROR,'linked cover cache entry')
            end
            local stem,extension=name:match('^(cover%-%x+)%.([%a]+)$')
            if attr and attr.mode=='file' and stem and
                (extension=='jpg' or extension=='png' or extension=='webp' or extension=='gif') then
                entries[#entries+1]={path=path,size=tonumber(attr.size) or 0}
            end
        end
    end
    local bytes,removed=0,0
    for _,entry in ipairs(entries) do
        bytes=bytes+entry.size
        if remove then
            local ok,err=fs:removeFile(entry.path)
            if not ok then return nil,err end
            removed=removed+1
        end
    end
    return {bytes=bytes,files=#entries,removed=removed}
end

function Management:usage()
    local result={bytes=0,files=0}
    for _,entry in ipairs{{'reading',self.reading},{'offline',self.offline}} do
        if entry[2] then
            local value,err=entry[2]:usage()
            if not value then return nil,err end
            result[entry[1]]=value
            result.bytes=result.bytes+value.bytes
            result.files=result.files+value.files
        end
    end
    local cover,err=covers(self,false)
    if not cover then return nil,err end
    result.covers=cover
    result.bytes=result.bytes+cover.bytes
    result.files=result.files+cover.files
    return result
end

function Management:clear(keep)
    -- Validate every category before the first removal, so a busy or unsafe
    -- cover directory does not leave an avoidably half-cleared cache.
    local _,scan_error=self:usage()
    if scan_error then return nil,scan_error end
    if self.cover_loader and next(self.cover_loader.pending or {}) then
        return nil,Errors.new(Errors.STORAGE_ERROR,'cover downloads are active')
    end
    local result={removed=0}
    for _,entry in ipairs{{'reading',self.reading},{'offline',self.offline}} do
        if entry[2] then
            local count,err=entry[2]:clear(keep,entry[1]=='offline')
            if count==nil then return nil,err end
            result[entry[1]]=count
            result.removed=result.removed+count
        end
    end
    local cover,err=covers(self,true)
    if not cover then return nil,err end
    result.covers=cover.removed
    result.removed=result.removed+cover.removed
    return result
end

return Management
