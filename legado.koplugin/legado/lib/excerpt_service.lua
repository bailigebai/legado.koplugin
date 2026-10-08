local Identity=require('legado.lib.identity')
local Json=require('legado.lib.json_codec')
local Markdown=require('legado.lib.excerpt_markdown')
local Service={};Service.__index=Service
local fields={'quote','book_key','title','author','source','chapter','location'}
local function same(a,b)
    for _,key in ipairs({'quote','book_key','chapter','location'}) do if a[key]~=b[key] then return false end end
    return true
end
function Service.new(options)
    options.now=options.now or function() return os.date('%Y-%m-%dT%H:%M:%S%z') end
    options.busy=false
    return setmetatable(options,Service)
end
function Service:schedule()
    if self.busy then self.rerun=true;return false end
    if self.job or not self.scheduler then return false end
    local job
    job=function() if self.job~=job then return end;self.job=nil;self:sync() end
    self.job=job;self.scheduler:scheduleIn(.2,job);return true
end
function Service:capture(input)
    if type(input)~='table' or type(input.quote)~='string' or input.quote=='' or #input.quote>65536
        or type(input.book_key)~='string' or input.book_key=='' then return nil,'摘录内容或书籍来源无效。' end
    local row={}
    for _,key in ipairs(fields) do row[key]=type(input[key])=='string' and input[key] or '' end
    for _,key in ipairs({'book_key','title','author','source','chapter','location'}) do
        if #row[key]>4096 then return nil,'书籍来源信息过长，未保存摘录。' end
    end
    local base='excerpt-'..Identity.hash(Json.encode{row.book_key,row.chapter,row.location,row.quote})
    local suffix=0
    while true do
        row.id=base..(suffix>0 and ('-'..suffix) or '')
        local old,err=self.storage:getExcerpt(row.id)
        if err then return nil,'读取摘录记录失败。' end
        if not old then break end
        if same(old,row) then self:schedule();return old end
        suffix=suffix+1
    end
    row.captured_at=self.now();row.status='pending'
    local config=self.client:config()
    if config then row.destination=config.destination;row.remote_path=Markdown.path(row,config.folder) end
    local saved,err=self.storage:putExcerpt(row)
    if not saved then return nil,'摘录保存失败，请检查设备存储空间后重试。' end
    self:schedule()
    return saved
end
function Service:list()
    local rows,err=self.storage:listExcerpts();if not rows then return nil,err end
    table.sort(rows,function(a,b)
        if a.captured_at==b.captured_at then return a.id>b.id end
        return (a.captured_at or '')>(b.captured_at or '')
    end)
    return rows
end
function Service:sync(callback)
    if self.busy then if callback then callback(nil,'正在同步，请稍后刷新。') end;return false end
    local config,err=self.client:config()
    if not config then self.last_error=err;if callback then callback(nil,err) end;return false end
    local rows,read_error=self:list()
    if not rows then self.last_error='读取摘录队列失败。';if callback then callback(nil,self.last_error) end;return false end
    local queue={}
    for _,row in ipairs(rows) do if row.status~='synced' then queue[#queue+1]=row end end
    self.busy=true;self.last_error=nil;local index,total=0,0
    local function finish(error_text)
        self.busy=false;self.last_error=error_text
        local rerun=self.rerun;self.rerun=nil
        if callback then callback(not error_text and total or nil,error_text) end
        if rerun and not error_text then self:schedule() end
    end
    local pump
    pump=function()
        index=index+1;local row=queue[index]
        if not row then return finish() end
        if row.destination and row.destination~=config.destination then
            return finish('接收地址或目录已改变，待同步摘录保留原目标。请恢复原连接文件后重试。')
        end
        if not row.destination then
            row.destination=config.destination;row.remote_path=Markdown.path(row,config.folder)
            if not self.storage:putExcerpt(row) then return finish('保存摘录目标失败，尚未上传。') end
        end
        return self.client:send(row,config,function(sent,send_error)
            if not sent then return finish(send_error or '同步失败，原句保留在设备。') end
            row.status='synced'
            if not self.storage:putExcerpt(row) then return finish('摘录已上传，但同步状态保存失败。重试会核对已有笔记。') end
            total=total+1
            -- Yield between notes so queued sync never monopolizes the reader UI.
            if self.scheduler then self.scheduler:scheduleIn(.05,pump) else pump() end
        end)
    end
    pump();return true
end
return Service
