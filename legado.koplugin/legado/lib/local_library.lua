local Fs = require('legado.lib.fs')
local Identity = require('legado.lib.identity')
local Errors = require('legado.lib.errors')
local Models = require('legado.lib.models')

local LocalLibrary = {}
LocalLibrary.__index = LocalLibrary
local extensions = {epub=true, txt=true, html=true, htm=true, mobi=true, azw=true, azw3=true, pdf=true, fb2=true}
local function linked(attr)
    return attr and (attr.mode == 'link' or attr.reparse_point or attr.is_reparse_point or attr.reparse_tag)
end
local function title(value) return tostring(value or ''):lower():gsub('[%s%p]',''):gsub('《',''):gsub('》','') end

function LocalLibrary.new(options)
    return setmetatable(options or {}, LocalLibrary)
end

function LocalLibrary:directories()
    local dirs = {}
    for path in tostring(self.settings:get('local_dir') or ''):gmatch('[^\r\n]+') do dirs[#dirs+1]=path end
    return dirs
end

function LocalLibrary:addDirectory(path)
    local fs = self.fs or Fs.new()
    if type(path) ~= 'string' or path == '' or path:find('[%z\r\n]') then return nil,Errors.new(Errors.INVALID_INPUT,'invalid local directory') end
    path = fs:canonicalize(path)
    local lfs = fs.lfs
    local attr = lfs and lfs.symlinkattributes and lfs.symlinkattributes(path)
    if not attr or linked(attr) or attr.mode ~= 'directory' then return nil,Errors.new(Errors.INVALID_INPUT,'local directory is unavailable') end
    local dirs = self:directories()
    for _,dir in ipairs(dirs) do if dir == path then return true end end
    dirs[#dirs+1]=path
    local encoded=table.concat(dirs,'\n')
    if #encoded>4096 then return nil,Errors.new(Errors.INVALID_INPUT,'too many local directories') end
    return self.settings:set('local_dir',encoded)
end

function LocalLibrary:removeDirectory(path)
    local dirs={}
    for _,dir in ipairs(self:directories()) do if dir~=path then dirs[#dirs+1]=dir end end
    return self.settings:set('local_dir',table.concat(dirs,'\n'))
end

function LocalLibrary:scan()
    local lfs = self.fs and self.fs.lfs
    if not lfs or not lfs.dir or not lfs.symlinkattributes then return {},'本地目录读取不可用' end
    local books, seen, warnings = {}, {}, {}
    local function walk(dir, depth)
        if seen[dir] then return end
        seen[dir]=true
        local attr=lfs.symlinkattributes(dir)
        if not attr or linked(attr) or attr.mode~='directory' then warnings[#warnings+1]='目录不可用：'..dir; return end
        local ok=pcall(function()
            for name in lfs.dir(dir) do
                if name:sub(1,1)~='.' then
                    local path=dir:gsub('[/\\]+$','')..'/'..name
                    local info=lfs.symlinkattributes(path)
                    if info and not linked(info) then
                        if info.mode=='directory' and not name:match('%.sdr$') then
                            -- ponytail: bound scans on Kindle; add another directory for deeper trees.
                            if depth<8 and #books<10000 then walk(path,depth+1) else warnings[#warnings+1]='目录过大，仅显示已扫描书籍' end
                        elseif info.mode=='file' and extensions[(name:match('%.([^%.]+)$') or ''):lower()] and not seen[path] then
                            seen[path]=true
                            if #books>=10000 then warnings[#warnings+1]='目录过大，仅显示前 10000 本'; return end
                            local id='local-'..Identity.hash(path)
                            local book=self.storage and self.storage:getBook(id) or nil
                            book=book or {id=id,name=name:gsub('%.[^%.]+$',''),author=''}
                            book.is_local,book.local_path,book.source_id=true,path,'local'
                            book.file_stamp=tostring(info.modification or '')..':'..tostring(info.size or '')
                            books[#books+1]=book
                        end
                    end
                end
            end
        end)
        if not ok then warnings[#warnings+1]='无法读取目录：'..dir end
    end
    for _,dir in ipairs(self:directories()) do walk(dir,1) end
    table.sort(books,function(a,b) if a.name==b.name then return a.local_path<b.local_path end return a.name<b.name end)
    return books, warnings[1]
end

function LocalLibrary:_embeddedCover(book)
    local stem=self.root..'/local-'..Identity.hash(book.local_path..'\n'..tostring(book.file_stamp or ''))..'.png'
    if self.fs:readBounded(stem,2*1024*1024) then return stem end
    local loaded,registry=pcall(require,'document/documentregistry')
    if not loaded or not registry:hasProvider(book.local_path) then return end
    local doc,bb
    local ok=pcall(function()
        doc=registry:openDocument(book.local_path)
        if not doc then return end
        if doc.loadDocument then doc:loadDocument(false) end
        bb=doc:getCoverPageImage()
        if bb then
            self.fs:ensureDirectory(self.root)
            local saved=bb:writeToFile(stem,'png')
            if not saved then error('cover save failed') end
        end
    end)
    if bb and bb.free then pcall(bb.free,bb) end
    if doc and doc.close then pcall(doc.close,doc) end
    if ok and bb and self.fs:readBounded(stem,2*1024*1024) then return stem end
end

function LocalLibrary:loadCover(book, callback)
    local finished, cancelled, downstream=false,false,nil
    local handle={cancel=function()
        cancelled=true
        if downstream and downstream.cancel then downstream:cancel() end
        return true
    end}
    local function done(path,err)
        if finished or cancelled then return end
        finished=true; callback(path,err)
    end
    local function fetch()
        local cover_book={id=book.id,cover_url=book.cover_url,source_id=book.cover_source_id}
        downstream=self.cover_loader:load(cover_book,done)
        if cancelled and downstream and downstream.cancel then downstream:cancel() end
    end
    local function run()
        if cancelled then return end
        local stem=book.local_path:gsub('%.[^%.]+$','')
        for _,ext in ipairs({'.jpg','.png','.jpeg'}) do
            if self.fs:readBounded(stem..ext,2*1024*1024) then done(stem..ext); return end
        end
        local ok,path=pcall(self.native_cover or self._embeddedCover,self,book)
        if cancelled then return end
        if ok and path then done(path); return end
        if book.cover_url and book.cover_url~='' then fetch(); return end
        if not self.service then done(nil); return end
        local matched, search_handle, search_done=false,nil,false
        local function same_book(candidate)
            return candidate and title(candidate.name)==title(book.name)
                and (not book.author or book.author=='' or title(candidate.author)==title(book.author))
        end
        local function save_cover(candidate)
            matched=true
            if search_handle and search_handle.cancel then search_handle:cancel() end
            book.cover_url,book.cover_source_id=candidate.cover_url,candidate.source_id
            if self.storage then self.storage:createBook(book) end
            fetch()
        end
        local function match(result)
            if cancelled or matched then return end
            for _,group in ipairs(result and result.groups or {}) do
                for _,candidate in ipairs(group.alternatives or {group.book}) do
                    -- ponytail: exact normalized titles only; never guess a different book's cover.
                    if same_book(candidate) and candidate.cover_url and candidate.cover_url~='' then
                        save_cover(candidate); return
                    end
                end
            end
        end
        local function details(result)
            local candidates={}
            for _,group in ipairs(result and result.groups or {}) do
                for _,candidate in ipairs(group.alternatives or {group.book}) do
                    if same_book(candidate) then candidates[#candidates+1]=candidate end
                end
            end
            local sources=self.storage and self.storage.listSources and self.storage:listSources() or {}
            local index=0
            local function next_detail()
                if cancelled or matched then return end
                index=index+1
                local candidate=candidates[index]
                if not candidate or not self.service.getBookInfo then done(nil);return end
                local source
                for _,value in ipairs(sources) do if Models.sourceId(value)==candidate.source_id then source=value;break end end
                if not source then next_detail();return end
                local completed=false
                local request=self.service:getBookInfo(source,candidate,function(info)
                    completed=true
                    if cancelled or matched then return end
                    if same_book(info) and info.cover_url and info.cover_url~='' then save_cover(info)
                    else next_detail() end
                end)
                if not completed then downstream=request end
            end
            next_detail()
        end
        search_handle=self.service:search(book.name,nil,1,function(result,err)
            search_done=true
            match(result)
            if not matched and not cancelled then
                if err then done(nil,err) else details(result) end
            end
        end,match)
        if matched or cancelled then if search_handle and search_handle.cancel then search_handle:cancel() end
        elseif not search_done then downstream=search_handle end
    end
    if self.scheduler and self.scheduler.scheduleIn then self.scheduler:scheduleIn(0,run) else run() end
    return handle
end

return LocalLibrary
