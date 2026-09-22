-- Prepare a single screen-sized texture; crengine draws it behind the text.
local Background = {}
local cached_key, cached_path
local function image_name(name) return name:lower():match('%.png$') or name:lower():match('%.jpe?g$') or name:lower():match('%.webp$') end
function Background.resolve(path, lfs)
    if type(path)~='string' or path=='' then return nil end
    if #path>4096 or path:find('%c') or not (path:sub(1,1)=='/' or path:match('^%a:[/\\]')) then return nil,'请填写本地图片或目录的完整路径。' end
    lfs=lfs or require('libs/libkoreader-lfs')
    local attr=lfs.attributes(path)
    if attr and attr.mode=='directory' then
        local names={}
        local readable=pcall(function()
            for name in lfs.dir(path) do if image_name(name) then names[#names+1]=name end end
        end)
        if not readable then return nil,'无法读取图片目录，请检查路径和访问权限。' end
        table.sort(names)
        for _,name in ipairs(names) do
            local file=path:gsub('[/\\]$','')..'/'..name
            local item=lfs.attributes(file)
            if item and item.mode=='file' then path,attr=file,item;break end
        end
    end
    if not attr or attr.mode~='file' or not image_name(path) or not attr.size or attr.size<=0 or attr.size>8*1024*1024 then
        return nil,'图片不可读，请选择 PNG、JPG 或 WebP（不超过 8 MB）；目录内需有图片。'
    end
    return path,attr
end
function Background.layout(w,h,iw,ih,scale,y,x)
    local ratio=math.min(w/iw,h/ih)*(scale or 100)/100
    local dw,dh=math.max(1,math.floor(iw*ratio)),math.max(1,math.floor(ih*ratio))
    return {w=dw,h=dh,x=math.floor((w-dw)/2+w*(x or 0)/100),y=math.floor((h-dh)*(y or 50)/100)}
end
function Background.prepare(settings)
    local path=settings and settings:get('reader_background') or ''
    if path=='' then return nil end
    local image,scaled,canvas,temp
    local ok,result=pcall(function()
        local source,attr=Background.resolve(path)
        if not source then error(attr,0) end
        local screen=require('device').screen
        local w,h=screen:getWidth(),screen:getHeight()
        local scale,y,x=settings:get('reader_background_scale'),settings:get('reader_background_y'),settings:get('reader_background_x')
        local key=table.concat({source,attr.size,attr.modification or 0,w,h,scale,y,x},'|')
        if key==cached_key and require('libs/libkoreader-lfs').attributes(cached_path) then return cached_path end
        -- RenderImage's explicit dimensions stretch the source; layout must see its original ratio.
        image=assert(require('ui/renderimage'):renderImageFile(source,false),'图片解码失败')
        local g=Background.layout(w,h,image:getWidth(),image:getHeight(),scale,y,x)
        scaled=image:scale(g.w,g.h)
        local BB=require('ffi/blitbuffer')
        canvas=BB.new(w,h,BB.TYPE_BB8,nil,w,w);canvas:fill(BB.COLOR_WHITE)
        local dx,dy,sx,sy=math.max(0,g.x),math.max(0,g.y),math.max(0,-g.x),math.max(0,-g.y)
        local cw,ch=math.min(w-dx,g.w-sx),math.min(h-dy,g.h-sy)
        if cw>0 and ch>0 then canvas:pmulalphablitFrom(scaled,dx,dy,sx,sy,cw,ch) end
        local folder=require('datastorage'):getDataDir()..'/legado'
        assert(require('legado.lib.fs').new():ensureDirectory(folder))
        local output=folder..'/reader-background.png'
        -- BlitBuffer:writePNG drops the encoder's failure result. Check it directly.
        temp=output..'.part.png'
        assert(require('ffi/png').encodeToFile(temp,require('ffi').cast('const uint8_t*',canvas.data),w,h,1),'无法写入背景缓存')
        assert(os.rename(temp,output));temp=nil
        cached_key,cached_path=key,output
        return output
    end)
    for _,buffer in pairs{canvas=canvas,scaled=scaled,image=image} do if buffer.free then pcall(buffer.free,buffer) end end
    if temp then os.remove(temp) end
    if not ok then return nil,tostring(result) end
    return result
end
function Background.apply(document,settings)
    if not document or type(document.setBackgroundImage)~='function' then return false,'当前文档引擎不支持图片背景。' end
    local path,err=Background.prepare(settings)
    local ok,cause=pcall(function()
        document:setBackgroundImage(path)
        if document.resetCallCache then document:resetCallCache() end
    end)
    if not ok then return nil,tostring(cause) end
    return not err,err
end
return Background
