require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local values = { ai_provider = "deepseek", ai_deepseek_key_file = "", ai_mimo_key_file = "", ai_prompt_extra = "" }
local fail_key
local settings = { all = function() return values end, get = function(_, key) return values[key] end,
    set = function(_, key, value)
        if key == fail_key then return nil, {code = "STORAGE_ERROR"} end
        values[key] = value
        return true
    end }
local chosen, tested = nil, false
local ai = { setKeyFile = function(_, provider, path) chosen = provider .. ":" .. path; return true end,
    testConnection = function(_, callback) tested = true; callback("连接成功") end }
local shown = {}
local presenter = Presenter.new{ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end },
    input_dialog = { new = function(_, options) return options end }}
local app = App.new{settings = settings, ai_service = ai, show = function(view) return presenter:show(view) end}
presenter.app = app
app:openSettings()
local entry
for _, item in ipairs(shown[#shown].item_table) do if item.text == "AI 服务设置" then entry = item end end
eq("function", type(entry and entry.callback), "settings expose the AI service page")
entry.callback()
eq("AI 服务", shown[#shown].title, "AI settings have a dedicated page")
local select_mimo, key_file, test
for _, item in ipairs(shown[#shown].item_table) do
    if item.text == "小米 MiMo" then select_mimo = item end
    if item.text == "选择密钥 JSON 文件" then key_file = item end
    if item.text == "测试连接" then test = item end
end
local ai_page = select_mimo.callback()
eq("mimo", values.ai_provider, "provider selector saves MiMo")
key_file.callback()
shown[#shown].buttons[1][2].callback("mimo.json")
eq("mimo:mimo.json", chosen, "file picker sends the JSON path to the AI service")
test.callback()
eq(true, tested, "connection test reaches the configured provider")
local select_deepseek, prompt_action
for _, item in ipairs(ai_page.item_table) do
    if item.text == "DeepSeek" then select_deepseek = item end
    if item.text == "补充提示词" then prompt_action = item end
end
fail_key = "ai_provider"
select_deepseek.callback()
eq("mimo", values.ai_provider, "failed provider save keeps the prior service")
eq(true, type(shown[#shown].text) == "string"
    and shown[#shown].text:find("设置保存失败", 1, true) ~= nil,
    "provider save failure is visible")
fail_key = "ai_prompt_extra"
prompt_action.callback()
shown[#shown].buttons[1][2].callback("解释更多术语")
eq("", values.ai_prompt_extra, "failed prompt save keeps the prior prompt")
eq(true, type(shown[#shown].text) == "string"
    and shown[#shown].text:find("设置保存失败", 1, true) ~= nil,
    "prompt save failure is visible")
return count
