local Json=require('legado.lib.json_codec')
local Markdown=require('legado.lib.excerpt_markdown')
local Client={};Client.__index=Client
local function decode(raw)
    local ok,value=pcall(Json.decode,raw or '')
    return ok and type(value)=='table' and value or nil
end
function Client.validate(value)
    if type(value)~='table' then return nil,'连接文件不是有效 JSON。' end
    local endpoint=type(value.endpoint)=='string' and value.endpoint:gsub('/$','') or ''
    local host,port=endpoint:match('^https://([%w%.%-]+):(%d+)$')
    if not host or #host>253 or not tonumber(port) or tonumber(port)<1 or tonumber(port)>65535 then
        return nil,'接收地址须为 https://电脑地址:端口。'
    end
    local key=value.api_key
    if type(key)~='string' or key=='' or #key>4096 or key:find('[%c%s]') then return nil,'接收密钥无效。' end
    local pin=type(value.certificate_sha256)=='string' and value.certificate_sha256:lower() or ''
    if #pin~=64 or pin:find('[^a-f0-9]') then return nil,'请提供接收端证书的 SHA-256 指纹。' end
    local ca=value.ca_file
    if type(ca)~='string' or ca=='' or #ca>4096 or ca:find('%c') then return nil,'请提供证书文件路径。' end
    local folder=Markdown.folder(value.folder or '阅读摘录/不亦阅乎')
    if not folder then return nil,'摘录目录须为仓库内相对目录，不能包含 .. 或特殊路径字符。' end
    return {endpoint=endpoint,api_key=key,certificate_sha256=pin,ca_file=ca,folder=folder,
        destination=endpoint..'\n'..pin..'\n'..folder}
end
function Client.new(options) return setmetatable(options,Client) end
function Client:config(path)
    path=path or self.settings:get('obsidian_config_file')
    if type(path)~='string' or path=='' or #path>4096 or path:find('%c') then return nil,'请先选择 Obsidian 连接 JSON 文件。' end
    local read,raw=pcall(self.fs.readBounded,self.fs,path,16384)
    if not read or not raw then return nil,'Obsidian 连接文件无法读取或超过 16 KiB。' end
    local config,err=Client.validate(decode(raw));if not config then return nil,err end
    if not config.ca_file:match('^[/\\]') and not config.ca_file:match('^%a:[/\\]') then
        if config.ca_file:find('[/\\]') or config.ca_file=='.' or config.ca_file=='..' then return nil,'相对证书文件应与连接文件同目录。' end
        config.ca_file=(path:match('^(.*[/\\])') or '')..config.ca_file
    end
    local ok,pem=pcall(self.fs.readBounded,self.fs,config.ca_file,65536)
    if not ok or type(pem)~='string' or not pem:find('-----BEGIN CERTIFICATE-----',1,true) then
        return nil,'接收端证书文件无法读取，请与连接 JSON 一起复制到设备。'
    end
    return config
end
function Client:setConfigFile(path)
    local config,err=self:config(path);if not config then return nil,err end
    local saved=self.settings:set('obsidian_config_file',path)
    if saved==nil then return nil,'连接文件路径保存失败。' end
    return true
end
function Client:_request(config,method,path,body,callback)
    local completed=false
    local function done(response,err)
        if completed then return end;completed=true;return callback(response,err)
    end
    local ok,handle=pcall(self.requests.execute,self.requests,{url=config.endpoint..path,
        method=method,body=body,source_id='obsidian',priority='background',timeout=8,max_bytes=2*1024*1024,
        max_redirects=0,binary=true,tls_ca_file=config.ca_file,tls_pin_sha256=config.certificate_sha256,
        headers={Authorization='Bearer '..config.api_key,Accept='text/markdown', ['Content-Type']='text/markdown; charset=utf-8'}},done)
    if not ok then done(nil,{code='NETWORK_ERROR'});return nil end
    return handle
end
local function status(response,err)
    return tonumber(response and response.status or err and err.details and err.details.status)
end
local function failure(response,err)
    local code=status(response,err)
    if code==401 or code==403 then return 'Obsidian 拒绝连接，请检查密钥和插件权限。' end
    if code==429 then return 'Obsidian 暂时限制请求，稍后再同步。' end
    return 'Obsidian 连接失败，请检查电脑是否运行、网络和接收端证书。摘录仍保存在设备。'
end
local function encoded_path(path)
    return (path:gsub('[^%w%-%._~/]',function(c) return string.format('%%%02X',c:byte()) end))
end
function Client:send(row,config,callback)
    local path=row.remote_path or Markdown.path(row,config.folder)
    if not path or path~=Markdown.path(row,config.folder) then callback(nil,'摘录目标路径无效。');return end
    local endpoint='/vault/'..encoded_path(path)
    return self:_request(config,'GET',endpoint,nil,function(response,err)
        if status(response,err)==404 then
            return self:_request(config,'PUT',endpoint,Markdown.render(row),function(created,create_error)
                local code=status(created,create_error)
                if not create_error and code and code>=200 and code<300 then return callback(true) end
                callback(nil,failure(created,create_error))
            end)
        end
        if not err and status(response,err)==200 and type(response.body)=='string' then
            if response.body:find(Markdown.marker(row),1,true) then return callback(true) end
            return callback(nil,'Obsidian 已有同名笔记，已保留原笔记，请检查目标目录。')
        end
        callback(nil,failure(response,err))
    end)
end
function Client:testConnection(callback)
    local config,err=self:config();if not config then callback(nil,err);return end
    return self:_request(config,'GET','/',nil,function(response,request_error)
        local data=not request_error and response and decode(response.body)
        if status(response,request_error)==200 and data and data.authenticated==true then return callback(true) end
        callback(nil,failure(response,request_error))
    end)
end
return Client
