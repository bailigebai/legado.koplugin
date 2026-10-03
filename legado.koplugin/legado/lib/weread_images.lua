local CacheStore=require('legado.lib.cache_store')

local Images={}
Images.__index=Images
Images.MAX_IMAGES=20
Images.MAX_IMAGE_BYTES=4*1024*1024
Images.MAX_TOTAL_BYTES=16*1024*1024

local function failure(code,message) return {code=code,message=message} end

local function trusted_url(value,remote_book_id)
    if type(value)~='string' or value=='' or #value>8192 or value:find('[%c%s]') then return nil end
    value=value:gsub('&amp;','&')
    local relative=value:match('^%.%./[iI][mM][aA][gG][eE][sS]/(.+)$')
    if relative then
        -- Matches the official reader's EPUB image rewrite. The local book
        -- hash is not the server's book id; never resolve against the host root.
        local extension=relative:match('%.([%a]+)$')
        if type(remote_book_id)~='string' or #remote_book_id>128 or not remote_book_id:match('^[%w_-]+$')
            or not relative:match('^[%w_./-]+$') or relative:find('..',1,true)
            or relative:sub(1,1)=='/' or relative:find('//',1,true)
            or not ({png=true,jpg=true,jpeg=true,gif=true})[extension and extension:lower()] then return nil end
        value='https://res.weread.qq.com/wrepub/web/'..remote_book_id..'/'..relative
    end
    if value:find('../',1,true) or value:find('\\',1,true) then return nil end
    if value:sub(1,2)=='//' then value='https:'..value
    elseif value:sub(1,1)=='/' then value='https://res.weread.qq.com'..value
    elseif not value:match('^%a[%w+.-]*:') then
        value='https://res.weread.qq.com/'..value
    end
    local host=value:match('^https://([^/%?#]+)')
    if not host or not ({['res.weread.qq.com']=true,['cdn.weread.qq.com']=true,
        ['weread.qq.com']=true})[host:lower()] then return nil end
    return value
end

local function legacy_notes(html)
    return html:gsub('<[iI][mM][gG][^>]*>',function(tag)
        local src=tag:match('%s+[sS][rR][cC]%s*=%s*"([^"]+)"') or tag:match("%s+[sS][rR][cC]%s*=%s*'([^']+)'")
        if not src or src:lower()~='../images/note.png' then return tag end
        local alt=tag:match('%s+[aA][lL][tT]%s*=%s*"([^"]+)"') or tag:match("%s+[aA][lL][tT]%s*=%s*'([^']+)'")
        if not alt or #alt>32768 or not alt:match('%S') then return tag end
        -- Older EPUBs use a missing note.png icon with the citation in alt,
        -- without the newer qqreader-footnote marker. Keep that text readable.
        alt=require('legado.lib.safe_functions').functions.htmldecode(alt)
        alt=require('legado.lib.xml_text').escape(alt)
        return '<span>〔注：'..alt..'〕</span>'
    end)
end

local function image_sources(html)
    local sources={}
    for tag in html:gmatch('<[iI][mM][gG][^>]*>') do
        local src=tag:match('%s+[sS][rR][cC]%s*=%s*"([^"]+)"')
            or tag:match("%s+[sS][rR][cC]%s*=%s*'([^']+)'")
        if not src then return nil end
        sources[#sources+1]=src
        if #sources>Images.MAX_IMAGES then return nil end
    end
    return sources
end

local function tar_images(data)
    if type(data)~='string' or #data>Images.MAX_TOTAL_BYTES then return nil end
    local images,pos={},1
    while pos+511<=#data do
        local header=data:sub(pos,pos+511)
        if header==string.rep('\0',512) then break end
        local name=header:sub(1,100):match('^[^%z]*')
        local size=tonumber(header:sub(125,136):match('^%s*([0-7]+)'),8)
        local kind=header:sub(157,157)
        if not name or not size or size<0 or size>Images.MAX_TOTAL_BYTES then return nil end
        local start=pos+512
        if start+size-1>#data then return nil end
        if (kind=='0' or kind=='\0') and not name:find('%.%.',1,true) then
            local basename=name:match('([^/]+)$')
            if basename and basename:match('^[%w_-]+$') then images[basename]=data:sub(start,start+size-1) end
        end
        pos=start+math.ceil(size/512)*512
    end
    return images
end

function Images.new(options)
    options=options or {}
    assert(options.cache and options.client,'WeRead images require cache and client')
    return setmetatable({cache=options.cache,client=options.client},Images)
end

function Images:prepare(book_id,chapter_uid,html,callback,chapter,remote_book_id)
    callback=callback or function() end
    if type(html)~='string' or type(book_id)~='string' or type(chapter_uid)~='string' then
        callback(nil,failure('INVALID_INPUT','微信图片章节参数无效'))
        return nil
    end
    html=legacy_notes(html)
    local sources=image_sources(html)
    if not sources then callback(nil,failure('INVALID_INPUT','微信图片标签或数量无效'));return nil end
    local urls={}
    for index,src in ipairs(sources) do
        urls[index]=trusted_url(src,remote_book_id)
        if not urls[index] then
            callback(nil,failure('INVALID_INPUT','微信图片地址不受信任'))
            return nil
        end
    end
    local cancelled,finished,active=false,false,nil
    local chapter_ref={uid=chapter_uid}
    local references,total={},0
    local function done(value,err)
        if cancelled or finished then return end
        finished=true
        callback(value,err)
    end
    local function set_active(start)
        local delivered=false
        local handle=start(function(...)
            delivered=true
            active=nil
            if not cancelled then return ... end
        end)
        if not delivered then active=handle end
    end
    local function finish_html()
        local index=0
        local localized=html:gsub('<[iI][mM][gG][^>]*>',function(tag)
            index=index+1
            local changed=tag:gsub('(%s+[sS][rR][cC]%s*=%s*["\'])(.-)(["\'])',
                function(prefix,_,quote) return prefix..references[index]..quote end,1)
            return changed
        end)
        done(localized)
    end
    local archive
    local function next_image(index)
        if cancelled or finished then return end
        if index>#urls then return finish_html() end
        local cached,cached_path=self.cache:readImage('weread',book_id,chapter_ref,index,urls[index])
        if cached then
            total=total+#cached
            if total>self.MAX_TOTAL_BYTES then
                return done(nil,failure('RESPONSE_TOO_LARGE','章节图片总量超过限制'))
            end
            references[index]='../images/'..cached_path:match('([^/\\]+)$')
            return next_image(index+1)
        end
        local function received(bytes,err)
            if cancelled or finished then return end
            if not bytes then return done(nil,failure('NETWORK_ERROR',err or '微信图片获取失败')) end
            if #bytes>self.MAX_IMAGE_BYTES or total+#bytes>self.MAX_TOTAL_BYTES then
                return done(nil,failure('RESPONSE_TOO_LARGE','章节图片超过缓存限制'))
            end
            if not CacheStore.imageExtension(bytes) then
                return done(nil,failure('INVALID_INPUT','微信图片格式不支持'))
            end
            local path,kind=self.cache:writeImage('weread',book_id,chapter_ref,index,bytes,urls[index])
            if not path then return done(nil,kind or failure('STORAGE_ERROR','微信图片缓存失败')) end
            total=total+#bytes
            references[index]='../images/'..path:match('([^/\\]+)$')
            next_image(index+1)
        end
        local path=urls[index]:match('^https://[^/]+(/[^?#]*)')
        local name=path and path:match('/([^/]+)$')
        local from_tar=archive and name and archive[name]
        if from_tar then return received(from_tar) end
        if not self.client.fetchResource then
            return done(nil,failure('NETWORK_ERROR','微信图片下载接口不可用'))
        end
        set_active(function(deliver)
            return self.client:fetchResource(urls[index],function(bytes,err) deliver();received(bytes,err) end,
                self.MAX_IMAGE_BYTES)
        end)
    end
    local tar=chapter and trusted_url(chapter.resource_tar)
    if chapter and chapter.resource_tar and not tar then
        done(nil,failure('INVALID_INPUT','微信章节资源包地址不受信任'))
    elseif tar and self.client.fetchResource then
        set_active(function(deliver)
            return self.client:fetchResource(tar,function(bytes)
                deliver()
                archive=tar_images(bytes)
                next_image(1)
            end,self.MAX_TOTAL_BYTES)
        end)
    else next_image(1) end
    return {cancel=function()
        if cancelled or finished then return false end
        cancelled=true
        if active and active.cancel then active:cancel() end
        return true
    end}
end

return Images
