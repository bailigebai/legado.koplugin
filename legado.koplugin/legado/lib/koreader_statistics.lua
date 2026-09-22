-- Adapted from Leko/KOReaderStatisticsBridge.lua (AGPL-3.0).
-- A whole-book bridge to an existing KOReader statistics schema; never creates it.
local Statistics = {}
Statistics.__index = Statistics
local SCHEMA_VERSION, TOTAL_PAGES, MAX_PENDING = 20221111, 10000, 500

local function failure(code,message,cause)
    return {code=code,message=message,details=cause and {cause=tostring(cause)} or nil}
end
local function structured(err)
    if type(err)=='table' and err.code then return err end
    return failure('STATISTICS_ERROR','阅读统计暂未写入，稍后会重试。',err)
end
local function finite(value)
    local n=(type(value)=='number' or type(value)=='string') and tonumber(value) or nil
    return n and n==n and n~=math.huge and n~=-math.huge and n or nil
end
local function page(value,default)
    return math.max(1,math.min(TOTAL_PAGES,math.floor(finite(value) or default or 1)))
end
local function close(resource)
    if resource and type(resource.close)=='function' then pcall(resource.close,resource) end
end

local Store = {}
Store.__index = Store
function Store.new(options)
    options=options or {}
    return setmetatable({db_path=options.db_path,open_db=options.open_db,file_exists=options.file_exists},Store)
end
function Store:_transaction(callback)
    local db,statements=nil,{}
    local ok,result=pcall(function()
        local path=self.db_path or (require('datastorage'):getSettingsDir()..'/statistics.sqlite3')
        local exists=self.file_exists or function(p) return require('libs/libkoreader-lfs').attributes(p,'mode')=='file' end
        if not exists(path) then error(failure('STATISTICS_UNAVAILABLE','KOReader 阅读统计库尚未建立。'),0) end
        -- rw also prevents a missing-file race from creating a fresh SQLite file.
        db=(self.open_db or require('lua-ljsqlite3/init').open)(path,'rw')
        assert(db,'cannot open statistics database')
        local function prepare(sql)
            local statement=assert(db:prepare(sql),'cannot prepare statistics query')
            statements[#statements+1]=statement
            return statement
        end
        local function query(sql,...)
            return prepare(sql):bind(...):step()
        end
        local schema_ok=pcall(function()
            assert(tonumber(db:rowexec('PRAGMA user_version;'))==SCHEMA_VERSION)
            assert(db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='book';"))
            assert(db:rowexec("SELECT name FROM sqlite_master WHERE type='table' AND name='page_stat_data';"))
            assert(db:rowexec("SELECT name FROM sqlite_master WHERE type='view' AND name='page_stat';"))
            prepare('SELECT id,title,authors,notes,last_open,highlights,pages,series,language,md5,total_read_time,total_read_pages FROM book LIMIT 0;')
            prepare('SELECT id_book,page,start_time,duration,total_pages FROM page_stat_data LIMIT 0;')
            prepare('SELECT id_book,page,start_time,duration FROM page_stat LIMIT 0;')
            local index=prepare('PRAGMA index_info(sqlite_autoindex_page_stat_data_1);')
            for _,name in ipairs{'id_book','page','start_time'} do
                local row=index:step();assert(row and row[3]==name)
            end
            assert(index:step()==nil)
        end)
        if not schema_ok then error(failure('STATISTICS_SCHEMA','KOReader 阅读统计库结构不支持，未修改数据库。'),0) end
        db:exec('BEGIN IMMEDIATE;')
        local value=callback(db,prepare,query)
        db:exec('COMMIT;')
        return value
    end)
    for _,statement in ipairs(statements) do close(statement) end
    if not ok and db then pcall(db.exec,db,'ROLLBACK;') end
    close(db)
    if not ok then return nil,structured(result) end
    return result
end
function Store:getOrCreate(book,md5,pages,now)
    return self:_transaction(function(db,_,query)
        local row=query('SELECT id FROM book WHERE md5=? ORDER BY id LIMIT 1;',md5)
        if row then return tonumber(row[1]) end
        query([[INSERT INTO book
            (title,authors,notes,last_open,highlights,pages,series,language,md5,total_read_time,total_read_pages)
            VALUES (?,?,0,?,0,?,'N/A','N/A',?,0,0);]],
            tostring(book.name or book.title or '未命名书籍'),tostring(book.author or 'N/A'),now,pages,md5)
        return assert(tonumber(db:rowexec('SELECT last_insert_rowid();')),'missing statistics book id')
    end)
end
function Store:write(id,periods,pages,now,max_sec)
    if #periods==0 then return true end
    return self:_transaction(function(_,prepare,query)
        assert(query('SELECT id FROM book WHERE id=?;',id),'statistics book no longer exists')
        local insert=prepare([[INSERT OR IGNORE INTO page_stat_data
            (id_book,page,start_time,duration,total_pages) VALUES (?,?,?,?,?);]])
        for _,period in ipairs(periods) do
            insert:reset():bind(id,period.page,period.start_time,period.duration,period.total_pages or pages):step()
        end
        local row=query([[SELECT count(*),sum(durations) FROM
            (SELECT min(sum(duration),?) AS durations FROM page_stat WHERE id_book=? GROUP BY page);]],max_sec or 120,id)
        query('UPDATE book SET pages=?,last_open=?,total_read_time=?,total_read_pages=? WHERE id=?;',
            pages,now,tonumber(row and row[2]) or 0,tonumber(row and row[1]) or 0,id)
        return true
    end)
end

function Statistics.new(options)
    options=options or {}
    local config=options.settings
    if not config and G_reader_settings and type(G_reader_settings.readSetting)=='function' then
        local ok,value=pcall(G_reader_settings.readSetting,G_reader_settings,'statistics',{})
        if ok then config=value end
    end
    config=type(config)=='table' and config or {}
    local self=setmetatable({clock=options.clock or os.time,store=options.store or Store.new(options),settings=config,
        total_pages=TOTAL_PAGES,periods={},active=false,paused=false,closed=false,blocked=false,turns=0},Statistics)
    self:_syncSettings()
    return self
end
function Statistics:_syncSettings()
    local config=self.settings
    self.enabled=config.is_enabled~=false
    self.max_sec=math.max(1,math.min(7200,finite(config.max_sec) or 120))
    self.min_sec=math.max(0,math.min(120,self.max_sec,finite(config.min_sec) or 5))
    if not self.enabled and self.active then
        self.period_start,self.paused=nil,true
    end
    return self.enabled
end
function Statistics:_error(err)
    self.last_error=structured(err)
    return nil,self.last_error
end
function Statistics:_now()
    local ok,value=pcall(self.clock)
    value=ok and finite(value) or nil
    if not value or value<0 then return self:_error(failure('STATISTICS_CLOCK','阅读统计时钟不可用。')) end
    return math.floor(value)
end
function Statistics:identityForBook(book,stable_id)
    local id=stable_id or (type(book)=='table' and book.id)
    if (type(id)~='string' and type(id)~='number') or tostring(id)=='' then
        return nil,failure('INVALID_INPUT','阅读统计缺少稳定书籍标识。')
    end
    return require('legado.lib.safe_functions').functions.md5('legado-reader\0'..tostring(id)),tostring(id)
end
function Statistics:_restart(now)
    if self.active and not self.paused and not self.blocked then self.period_start=now end
end
function Statistics:start(book,current_page,stable_id)
    if not self:_syncSettings() then return false end
    if type(book)~='table' then return self:_error(failure('INVALID_INPUT','阅读统计缺少书籍信息。')) end
    local md5,id=self:identityForBook(book,stable_id)
    if not md5 then return self:_error(id) end
    if self.active and self.book_id==id then
        if self.paused or self.blocked then return self:resume(current_page) end
        return self:onPageChanged(current_page or self.current_page)
    end
    if self.book_id then
        local saved,err=self:close()
        if not saved then return nil,err end
    end
    local now,err=self:_now();if not now then return nil,err end
    local ok,native_id,cause=pcall(self.store.getOrCreate,self.store,book,md5,TOTAL_PAGES,now)
    if not ok or not native_id then return self:_error(ok and cause or native_id) end
    self.book_id,self.statistics_id=id,native_id
    self.active,self.paused,self.closed,self.blocked=true,false,false,false
    self.current_page,self.period_start,self.turns=page(current_page),now,0
    self.last_error=nil
    return true
end
function Statistics:_finish(now)
    if not self.period_start then return end
    local elapsed=math.max(0,now-self.period_start)
    if elapsed>0 and elapsed>=self.min_sec then
        self.periods[#self.periods+1]={page=self.current_page,start_time=self.period_start,
            duration=math.min(elapsed,self.max_sec),total_pages=TOTAL_PAGES}
    end
    self.period_start=nil
    if #self.periods>=MAX_PENDING then self.blocked=true end
end
function Statistics:flush()
    self:_syncSettings()
    if #self.periods==0 then return true end
    local now,err=self:_now();if not now then return nil,err end
    local ok,saved,cause=pcall(self.store.write,self.store,self.statistics_id,self.periods,TOTAL_PAGES,now,self.max_sec)
    if not ok or not saved then
        local write_error=ok and cause or saved
        if self.blocked then return self:_error(failure('STATISTICS_QUEUE_FULL','待写阅读统计已满，新增统计已暂停；保存恢复后继续。',type(write_error)=='table' and write_error.code or write_error)) end
        return self:_error(write_error)
    end
    local blocked=self.blocked
    self.periods,self.turns,self.blocked,self.last_error={},0,false,nil
    if blocked then self:_restart(now) end
    return true
end
function Statistics:onPageChanged(current_page)
    if not self:_syncSettings() then return false end
    if not self.active or self.paused or self.closed then return false end
    local next_page=page(current_page,self.current_page)
    if self.blocked then self.current_page=next_page;return self:flush() end
    if next_page==self.current_page then return true end
    local now,err=self:_now();if not now then return nil,err end
    self:_finish(now)
    self.current_page=next_page;self:_restart(now)
    self.turns=self.turns+1
    if self.turns>=50 or self.blocked then return self:flush() end
    return true
end
function Statistics:checkpoint()
    self:_syncSettings()
    if self.active and not self.paused and not self.blocked then
        local now,err=self:_now();if not now then return nil,err end
        self:_finish(now);self:_restart(now)
    end
    return self:flush()
end
function Statistics:pause()
    self:_syncSettings()
    if self.active and not self.paused then
        local now,err=self:_now();if not now then return nil,err end
        self:_finish(now);self.paused=true
    end
    return self:flush()
end
function Statistics:resume(current_page)
    if not self:_syncSettings() then return false end
    if not self.active or self.closed then return false end
    if not self.paused and not self.blocked then return true end
    local now,err=self:_now();if not now then return nil,err end
    if self.blocked then local saved,cause=self:flush();if not saved then return nil,cause end end
    self.current_page,self.paused=page(current_page,self.current_page),false
    self:_restart(now)
    return true
end
function Statistics:close()
    self:_syncSettings()
    if not self.closed then
        local now,err=self:_now()
        if now and self.active then self:_finish(now) end
        self.active,self.paused,self.closed=false,false,true
        -- A failed clock cannot leave the old book's timer accepting new pages.
        self.period_start=nil
        if not now then return nil,err end
    end
    return self:flush()
end
function Statistics:status()
    return {pending=#self.periods,pending_limit=MAX_PENDING,active=self.active,paused=self.paused,
        blocked=self.blocked,closed=self.closed,last_error=self.last_error}
end
Statistics.DB_SCHEMA_VERSION,Statistics.VIRTUAL_PAGE_COUNT,Statistics.NativeStore=SCHEMA_VERSION,TOTAL_PAGES,Store
return Statistics
