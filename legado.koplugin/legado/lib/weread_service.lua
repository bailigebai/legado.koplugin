local Mapper=require('legado.lib.weread_mapper')
local Service={}
Service.__index=Service

function Service.new(client)
    return setmetatable({client=client},Service)
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
    return self.client:chapterContent(book.remote_id,chapter.remote_uid,function(body,err)
        if not body then return callback(nil,{code='NETWORK_ERROR',message=err or '微信读书正文获取失败'}) end
        callback({content=body})
    end)
end

return Service
