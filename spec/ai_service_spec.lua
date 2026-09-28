local A = require("assertions")
local Json = require("legado.lib.json_codec")
local AI = require("legado.lib.ai_service")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local values, files, pending = { ai_provider = "deepseek" }, {}, {}
local settings = { get = function(_, key) return values[key] end,
    set = function(_, key, value) values[key] = value; return true end }
local fs = { readBounded = function(_, path) return files[path] end }
local requests = { execute = function(_, spec, callback)
    local row = { spec = spec, callback = callback }
    pending[#pending + 1] = row
    return { cancel = function() row.cancelled = true end }
end }
local ai = AI.new{ requests = requests, fs = fs, settings = settings }
eq("https://api.deepseek.com", AI.providers.deepseek.base_url, "DeepSeek official base URL is configured")
eq("deepseek-flash", AI.providers.deepseek.model, "current DeepSeek default model is configured")
eq("https://api.xiaomimimo.com/v1", AI.providers.mimo.base_url, "MiMo official base URL is configured")
eq("mimo-v2.5-pro", AI.providers.mimo.model, "current MiMo default model is configured")
eq(true, AI.DEFAULT_PROMPT:find("不熟悉的名称", 1, true) ~= nil, "default reading prompt explains unfamiliar names")
files["deepseek.json"] = Json.encode({ api_key = "secret-deepseek" })
eq(true, ai:setKeyFile("deepseek", "deepseek.json"), "JSON key file is accepted")
eq("deepseek.json", values.ai_deepseek_key_file, "only the file path is stored in settings")
files["bad.json"] = "{bad"
eq(nil, ai:setKeyFile("deepseek", "bad.json"), "malformed JSON key file is rejected")
local answer
ai:explain("庄周梦蝶", "补充时代背景", function(value) answer = value end)
eq("https://api.deepseek.com/chat/completions", pending[1].spec.url, "explanation uses chat completions")
eq("Bearer secret-deepseek", pending[1].spec.headers.Authorization, "key is sent only in authorization header")
eq("deepseek-flash", pending[1].spec.body.model, "request uses provider model")
eq(true, pending[1].spec.body.messages[1].content:find("补充时代背景", 1, true) ~= nil,
    "custom prompt is appended to the default system prompt")
eq("庄周梦蝶", pending[1].spec.body.messages[2].content, "only selected text is sent as user content")
pending[1].callback({ status = 200, body = Json.encode({ choices = {{ message = { content = "解释结果" } }} }) })
eq("解释结果", answer, "answer is returned to reading UI")
files["mimo.json"] = Json.encode({ mimo = { api_key = "secret-mimo" } })
eq(true, ai:setKeyFile("mimo", "mimo.json"), "provider-specific JSON key is accepted")
settings:set("ai_provider", "mimo")
local connected, connection_error
ai:testConnection(function(value, err) connected, connection_error = value, err end)
eq("https://api.xiaomimimo.com/v1/chat/completions", pending[2].spec.url,
    "connection test uses the selected provider")
eq("mimo-v2.5-pro", pending[2].spec.body.model, "MiMo test uses its default model")
pending[2].callback({status = 200, body = Json.encode({choices = {{message = {}}}})})
eq(nil, connected, "missing answer content does not count as a connected model")
eq("AI 返回内容不可用，请检查密钥、模型和服务余额", connection_error,
    "a successful HTTP status without text reports a useful error")
return count
