local Mapper=require('legado.lib.weread_mapper')
local Discussions={}
Discussions.__index=Discussions

function Discussions.new(options)
    assert(options.client and options.book_id and options.chapter_uid,'chapter discussions require their owner')
    return setmetatable({client=options.client,book_id=options.book_id,chapter_uid=options.chapter_uid,
        is_current=options.is_current,on_change=options.on_change,rows={},generation=0,loading=false},Discussions)
end
function Discussions:current()
    return not self.closed and (not self.is_current or self.is_current())
end
function Discussions:_notify()
    if self:current() and self.on_change then self.on_change(self) end
    if self:current() and self.panel_changed then self.panel_changed(self) end
end
function Discussions:cancelLoad()
    self.generation=self.generation+1
    if self.request and self.request.cancel then self.request:cancel() end
    self.request,self.loading=nil,false
    if self.detail then self.detail:close();self.detail=nil end
end
function Discussions:close()
    if self.closed then return false end
    self:cancelLoad();self.closed=true
    if self.panel_close then self.panel_close() end
    self.on_change,self.panel_changed,self.panel_close=nil,nil,nil
    return true
end
function Discussions:load()
    if not self:current() or self.loading or self.loaded then return false end
    self.loading,self.error=true,nil
    self.generation=self.generation+1
    local generation,delivered=self.generation,false
    self:_notify()
    local request=self.client:chapterDiscussions(self.book_id,self.chapter_uid,function(data,err)
        delivered=true
        if generation~=self.generation or not self:current() then return end
        self.request,self.loading=nil,false
        if not data then self.error=err or '无法加载本章热门想法，请检查网络或重新扫码登录'
        else
            self.rows=Mapper.chapterDiscussions(data,self.book_id,self.chapter_uid)
            self.loaded=true
        end
        self:_notify()
    end)
    if not delivered then self.request=request end
    return true
end
return Discussions
