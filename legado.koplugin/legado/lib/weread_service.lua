local Mapper=require('legado.lib.weread_mapper')
local Service={}
Service.__index=Service

function Service.new(client,images)
    return setmetatable({client=client,images=images},Service)
end

function Service:getChapters(_,book,callback)
    return self.client:chapterInfos(book.remote_id,function(wire,err)
        if not wire then return callback(nil,{code='NETWORK_ERROR',message=err or '微信读书目录获取失败'}) end
        local chapters,map_error=Mapper.chapters(wire,book)
        if not chapters then return callback(nil,{code='PARSE_ERROR',message=map_error}) end
        callback(chapters,nil,{catalog_complete=true})
    end)
end

function Service:getContent(_,book,chapter,callback)
    local cancelled,active,finished=false,nil,false
    local function deliver(value,err)
        if cancelled or finished then return end
        finished=true
        callback(value,err)
    end
    local delivered=false
    local handle=self.client:chapterContent(book.remote_id,chapter.remote_uid,function(body,err)
        delivered=true
        active=nil
        if cancelled then return end
        if not body then return deliver(nil,{code='NETWORK_ERROR',message=err or '微信读书正文获取失败'}) end
        if not body:lower():find('<img',1,true) then return deliver({content=body}) end
        if not self.images then
            return deliver(nil,{code='STORAGE_ERROR',message='微信图片缓存尚未初始化'})
        end
        local prepared=false
        local image_handle=self.images:prepare(book.id,chapter.uid,body,function(local_body,image_error)
            prepared=true
            active=nil
            if not local_body then return deliver(nil,image_error) end
            deliver({content=local_body})
        end,chapter)
        if not prepared then active=image_handle end
    end)
    if not delivered then active=handle end
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if active and active.cancel then active:cancel() end
        return true
    end}
end

return Service
