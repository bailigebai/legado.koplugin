local Cleaner=require('legado.lib.content_cleaner')
local Errors=require('legado.lib.errors')
local Worker={};Worker.__index=Worker

-- Owns only the current book's bounded chapter requests, never task persistence.
function Worker.new(options)
    return setmetatable({options=options,scheduler=options.scheduler,next=1,busy=0,slots={},closed=false,
        width=math.max(1,math.min(2,math.floor(tonumber(options.concurrency) or 1)))},Worker)
end
function Worker:current() return not self.closed and self.options.valid() end
function Worker:cancel()
    if self.closed then return false end
    self.closed=true
    local job=self.scheduled;self.scheduled=nil
    if job and self.scheduler and self.scheduler.unschedule then pcall(self.scheduler.unschedule,self.scheduler,job) end
    for slot in pairs(self.slots) do
        slot.active=false
        if slot.handle and slot.handle.cancel then pcall(slot.handle.cancel,slot.handle) end
    end
    self.slots={};self.busy=0
    return true
end
function Worker:_fail(err,chapter_failed)
    if not self:current() then return end
    self:cancel();self.options.failed(err,chapter_failed==true)
end
function Worker:_queue()
    if not self:current() or self.scheduled then return end
    if not self.scheduler or type(self.scheduler.scheduleIn)~='function' then
        if not self.pumping then self:_run() end
        return
    end
    local job
    job=function()
        if self.scheduled~=job then return end
        self.scheduled=nil;if self:current() then self:_run() end
    end
    self.scheduled=job
    local called,err=pcall(self.scheduler.scheduleIn,self.scheduler,.01,job)
    if not called then self.scheduled=nil;self:_fail(Errors.new(Errors.STORAGE_ERROR,'download scheduling failed')) end
end
function Worker:_accept(chapter,body,write)
    if not self:current() then return false end
    local o=self.options
    if write then
        local saved,err=o.target:writeBody(o.source_id,o.book_id,chapter,body)
        if not saved then self:_fail(err,true);return false end
    end
    if not self:current() then return false end
    return o.progress(chapter)==true and self:current()
end
function Worker:_request(chapter)
    local o=self.options
    local slot={active=true};self.slots[slot]=true;self.busy=self.busy+1
    local function deliver(result,err)
        if not slot.active or not self:current() then return end
        slot.active=false;slot.completed=true;self.slots[slot]=nil;self.busy=self.busy-1
        local called,cause=pcall(function()
            if err or type(result)~='table' or type(result.content)~='string' then
                self:_fail(err or Errors.new(Errors.PARSE_ERROR,'download content is invalid'),true);return
            end
            local body,clean_error=Cleaner.normalize(result.content)
            if not body then self:_fail(clean_error,true);return end
            if self:_accept(chapter,body,true) then self:_queue() end
        end)
        if not called then self:_fail(Errors.new(Errors.STORAGE_ERROR,'download chapter processing failed'),true) end
    end
    local called,handle=pcall(o.request,chapter,deliver)
    if not called then deliver(nil,Errors.new(Errors.NETWORK_ERROR,'download request failed'));return end
    if slot.active and self:current() then slot.handle=handle
    elseif not slot.completed and handle and handle.cancel then pcall(handle.cancel,handle) end
end
function Worker:_run()
    if self.pumping or not self:current() then return end
    self.pumping=true
    local o=self.options
    local called=pcall(function()
        local budget=self.scheduler and 2 or math.huge
        while self:current() and self.busy<self.width and self.next<=#o.chapters and budget>0 do
            local chapter=o.chapters[self.next];self.next=self.next+1;budget=budget-1
            local body=o.target:readBody(o.source_id,o.book_id,chapter)
            local write=false
            if (type(body)~='string' or body=='') and o.alternate then
                body=o.alternate:readBody(o.source_id,o.book_id,chapter);write=o.copy_alternate==true
            end
            if type(body)=='string' and body~='' then
                if not self:_accept(chapter,body,write) then return end
            else self:_request(chapter) end
        end
        if not self:current() then return end
        if self.next>#o.chapters and self.busy==0 then
            self:cancel()
            local finished=pcall(o.completed)
            if not finished and o.valid() then o.failed(Errors.new(Errors.STORAGE_ERROR,'download finalization failed')) end
        elseif self.next<=#o.chapters and self.busy<self.width then self:_queue() end
    end)
    self.pumping=false
    if not called then self:_fail(Errors.new(Errors.STORAGE_ERROR,'download chapter processing failed')) end
end
function Worker:start() self:_queue();return self end
return Worker
