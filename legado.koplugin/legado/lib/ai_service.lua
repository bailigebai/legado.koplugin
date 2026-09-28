local Json = require("legado.lib.json_codec")

local AI = {}
AI.__index = AI

AI.providers = {
    deepseek = { base_url = "https://api.deepseek.com", model = "deepseek-flash" },
    mimo = { base_url = "https://api.xiaomimimo.com/v1", model = "mimo-v2.5-pro" },
}
AI.DEFAULT_PROMPT = "请用通俗中文解释下面这段阅读内容。先说明不熟悉的名称或术语，再解释句子的意思和上下文；不要编造原文没有的信息。"

local function trim(value)
    return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
end

local function decoded(raw)
    if type(raw) ~= "string" then return nil end
    local ok, value = pcall(Json.decode, raw)
    if ok and type(value) == "table" then return value end
end

function AI.new(options)
    options = options or {}
    assert(options.requests and options.fs and options.settings, "AI service requires requests, fs and settings")
    return setmetatable({ requests = options.requests, fs = options.fs, settings = options.settings }, AI)
end

function AI:provider()
    local name = self.settings:get("ai_provider")
    return AI.providers[name] and name or "deepseek"
end

function AI:_key(provider, path)
    if not AI.providers[provider] then return nil, "AI 服务商不可用" end
    path = path or self.settings:get("ai_" .. provider .. "_key_file")
    if type(path) ~= "string" or path == "" or #path > 4096 or path:find("%z") then
        return nil, "请先选择密钥 JSON 文件"
    end
    local ok, raw = pcall(self.fs.readBounded, self.fs, path, 8192)
    if not ok or type(raw) ~= "string" then return nil, "密钥文件无法读取或超过 8 KiB" end
    local data = decoded(raw)
    if not data then return nil, "密钥文件不是有效 JSON" end
    local nested = type(data[provider]) == "table" and data[provider] or nil
    local keys = type(data.keys) == "table" and data.keys or nil
    local value = nested and (nested.api_key or nested.apiKey or nested.key)
        or keys and keys[provider]
        or data[provider .. "_api_key"] or data.api_key or data.apiKey
    value = trim(value)
    if value == "" or #value > 4096 or value:find("[%c%s]") then return nil, "密钥字段无效" end
    return value
end

function AI:setKeyFile(provider, path)
    local key, err = self:_key(provider, path)
    if not key then return nil, err end
    local saved = self.settings:set("ai_" .. provider .. "_key_file", path)
    if saved == nil then return nil, "密钥文件路径保存失败" end
    return true
end

function AI:_chat(provider, messages, callback)
    local config = AI.providers[provider]
    if not config then callback(nil, "AI 服务商不可用"); return nil end
    local key, key_error = self:_key(provider)
    if not key then callback(nil, key_error); return nil end
    local body = { model = config.model, messages = messages, stream = false }
    if provider == "mimo" then body.thinking = { type = "disabled" } end
    return self.requests:execute({ url = config.base_url .. "/chat/completions",
        method = "POST", source_id = "ai-" .. provider, priority = "foreground",
        timeout = 90, max_bytes = 512 * 1024,
        headers = { Authorization = "Bearer " .. key },
        body_type = "json", body = body,
    }, function(response, err)
        if err then callback(nil, "AI 连接失败，请检查网络、密钥或服务余额"); return end
        local status = response and tonumber(response.status or response.code)
        local data = response and decoded(response.body)
        local first = data and type(data.choices) == "table" and data.choices[1]
        local content = first and type(first.message) == "table" and trim(first.message.content)
        if not status or status < 200 or status >= 300 or content == "" then
            callback(nil, "AI 返回内容不可用，请检查密钥、模型和服务余额")
            return
        end
        callback(content)
    end)
end

function AI:explain(selected_text, extra_prompt, callback)
    callback = callback or function() end
    local text = trim(selected_text)
    if text == "" or #text > 4000 then callback(nil, "请选择不超过 4000 字节的阅读内容"); return nil end
    local extra = trim(extra_prompt ~= nil and extra_prompt or self.settings:get("ai_prompt_extra"))
    if #extra > 2000 then callback(nil, "补充提示词过长"); return nil end
    local prompt = AI.DEFAULT_PROMPT
    if extra ~= "" then prompt = prompt .. "\n补充要求：" .. extra end
    return self:_chat(self:provider(), { { role = "system", content = prompt },
        { role = "user", content = text } }, callback)
end

function AI:testConnection(callback)
    return self:_chat(self:provider(), { { role = "user", content = "请只回复：连接成功" } }, callback)
end

return AI
