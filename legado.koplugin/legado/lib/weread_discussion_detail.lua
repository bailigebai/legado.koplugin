local Mapper=require('legado.lib.weread_mapper')
local Detail={};Detail.__index=Detail

local function page(rows,offset,total,has_more)
    if has_more==1 then has_more=true elseif has_more==0 then has_more=false end
    if type(has_more)~='boolean' then has_more=total==nil or offset<total end
    return {rows=rows or {},offset=offset or 0,total=total,has_more=has_more}
end
local function append(state,rows)
    local seen={}
    for _,row in ipairs(state.rows) do seen[row.id]=true end
    for _,row in ipairs(rows) do
        if not seen[row.id] then state.rows[#state.rows+1]=row;seen[row.id]=true end
    end
end

function Detail.new(options)
    assert(options.client and options.review and options.review.id,'discussion detail requires an owner')
    return setmetatable({client=options.client,book_id=options.book_id,chapter_uid=options.chapter_uid,
        review=options.review,is_current=options.is_current,on_change=options.on_change,
        generation=0,replies=page({},0,nil),likes=page({},0,nil),threads={}},Detail)
end
function Detail:current() return not self.closed and (not self.is_current or self.is_current()) end
function Detail:notify() if self:current() and self.on_change then self.on_change(self) end end
function Detail:_start(state,start,accept)
    if not self:current() or state.loading then return false end
    state.loading,state.error=true,nil
    local generation,delivered=self.generation,false
    self:notify()
    if generation~=self.generation or not self:current() then state.loading=false;return false end
    local handle=start(function(data,err)
        delivered=true
        if generation~=self.generation or not self:current() then return end
        state.request,state.loading=nil,false
        if not data then state.error=err or '讨论加载失败，请重试'
        else accept(data) end
        self:notify()
    end)
    if not delivered then state.request=handle end
    return true
end
function Detail:load()
    if self.loaded then return false end
    return self:_start(self,function(cb)
        return self.client:discussionDetail(self.book_id,self.chapter_uid,self.review.id,cb)
    end,function(data)
        local row=Mapper.discussionDetail(data,self.book_id,self.chapter_uid,self.review.id)
        if not row then self.error='讨论详情不属于当前章节';return end
        if row.abstract=='' then row.abstract=self.review.abstract end
        self.review=row;self.loaded=true
        self.replies=page(Mapper.discussionReplies(data,row.id),#(data.comments or {}),row.comments_count,data.commentsHasMore)
        self.likes=page(Mapper.discussionLikes(data),#(data.likes or {}),row.likes_count)
    end)
end
function Detail:thread(parent)
    if not parent then return self.replies end
    if not self.threads[parent.id] then
        local raw=parent.sub_comments or {}
        self.threads[parent.id]=page(Mapper.discussionReplies({comments=raw},self.review.id),#raw,
            parent.replies_count,parent.sub_has_more)
    end
    return self.threads[parent.id]
end
function Detail:loadReplies(parent)
    if not self.loaded then return false end
    local state=self:thread(parent)
    if not state.has_more and not state.error then return false end
    return self:_start(state,function(cb)
        return self.client:discussionReplies(self.review.id,cb,{review_id=self.review.id,
            comment_id=parent and parent.id or nil,max_idx=state.offset})
    end,function(data)
        append(state,Mapper.discussionReplies(data,self.review.id))
        local total=Mapper.discussionCount(data.commentsCount)
        if total~=nil then
            state.total=total
            if parent then parent.replies_count=total else self.review.comments_count=total end
        end
        local amount=#(data.comments or {})
        state.offset=state.offset+amount
        if data.has_more~=nil then state.has_more=data.has_more
        elseif data.commentsHasMore~=nil then state.has_more=data.commentsHasMore==true or data.commentsHasMore==1
        else state.has_more=amount>0 and (state.total==nil or state.offset<state.total) end
        if amount==0 and state.has_more then state.error='回复分页未前进，请重试';state.has_more=false end
    end)
end
function Detail:loadLikes()
    if not self.loaded or (not self.likes.has_more and not self.likes.error) then return false end
    local state=self.likes
    return self:_start(state,function(cb) return self.client:discussionLikes(self.review.id,state.offset,cb) end,function(data)
        append(state,Mapper.discussionLikes(data))
        local total=Mapper.discussionCount(data.likesCount)
        if total~=nil then state.total=total;self.review.likes_count=total end
        local amount=#(data.likes or {})
        state.offset=state.offset+amount
        -- The Web UI compares the original real total against the loaded offset.
        state.has_more=amount>0 and (state.total==nil or state.offset<state.total)
    end)
end
function Detail:cancelRequests()
    self.generation=self.generation+1
    local states={self,self.replies,self.likes}
    for _,state in pairs(self.threads) do states[#states+1]=state end
    for _,state in ipairs(states) do
        if state.request and state.request.cancel then pcall(state.request.cancel,state.request) end
        state.request,state.loading=nil,false
    end
    return true
end
function Detail:close()
    if self.closed then return false end
    self.closed=true;self:cancelRequests();self.on_change=nil
    return true
end
return Detail
