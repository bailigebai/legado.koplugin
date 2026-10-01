local Mapper=require('legado.lib.weread_mapper')
local Comments={}
Comments.__index=Comments
Comments.MAX_ROWS=2000

function Comments.new(options)
    assert(options.client and options.book_id and options.chapter_uid,'chapter comments require their owner')
    return setmetatable({client=options.client,book_id=options.book_id,chapter_uid=options.chapter_uid,
        model=options.model,is_current=options.is_current,on_change=options.on_change,
        rows={},seen={},generation=0,pages=0},Comments)
end
function Comments:current()
    return not self.closed and (not self.is_current or self.is_current())
end
function Comments:_notify()
    if self:current() and self.on_change then self.on_change(self) end
    if self:current() and self.panel_changed then self.panel_changed(self) end
end
function Comments:cancelLoad()
    self.generation=self.generation+1
    if self.request and self.request.cancel then self.request:cancel() end
    self.request,self.loading=nil,false
end
function Comments:close()
    if self.closed then return false end
    self:cancelLoad();self.closed=true
    if self.panel_close then self.panel_close() end
    self.on_change,self.panel_changed,self.panel_close=nil,nil,nil
    return true
end
function Comments:load()
    if not self:current() or self.loading or (self.loaded and not self.next_cursor) then return false end
    if self.pages>=50 or #self.rows>=self.MAX_ROWS then
        self.error='本章评论较多，已达到本次加载上限。';self:_notify();return false
    end
    self.loading,self.error=true,nil
    self.generation=self.generation+1
    local generation,delivered=self.generation,false
    self:_notify()
    local request=self.client:chapterComments(self.book_id,self.chapter_uid,function(data,err)
        delivered=true
        if generation~=self.generation or not self:current() then return end
        self.request,self.loading=nil,false
        if not data then self.error=err or '无法加载本章评论，请检查网络或重新扫码登录'
        else
            self.pages,self.loaded=self.pages+1,true
            for _,row in ipairs(Mapper.inlineComments(data,self.book_id,self.chapter_uid,self.model)) do
                local key=tostring(row.range or '')..'\n'..row.id
                if not self.seen[key] and #self.rows<self.MAX_ROWS then
                    self.seen[key]=true;self.rows[#self.rows+1]=row
                end
            end
            self.next_cursor=data.has_more and data.next_cursor or nil
            if #self.rows>=self.MAX_ROWS and self.next_cursor then
                self.error='本章评论较多，已显示前 '..self.MAX_ROWS..' 条。'
            end
        end
        self:_notify()
    end,self.next_cursor)
    if not delivered then self.request=request end
    return true
end
function Comments:list(range)
    local located,unlocated={},{}
    for _,row in ipairs(self.rows) do
        local selected=not range or row.range==range
        if type(range)=='table' then for _,value in ipairs(range) do if value==row.range then selected=true;break end end end
        if selected then
            local list=row.position and located or unlocated;list[#list+1]=row
        end
    end
    for _,row in ipairs(unlocated) do located[#located+1]=row end
    return located
end
return Comments
