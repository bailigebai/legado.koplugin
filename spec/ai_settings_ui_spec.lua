require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local values = { ai_provider = "deepseek", ai_deepseek_key_file = "", ai_mimo_key_file = "", ai_prompt_extra = "" }
local settings = { all = function() return values end, get = function(_, key) return values[key] end,
    set = function(_, key, value) values[key] = value; return true end }
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
select_mimo.callback()
eq("mimo", values.ai_provider, "provider selector saves MiMo")
key_file.callback()
shown[#shown].buttons[1][2].callback("mimo.json")
eq("mimo:mimo.json", chosen, "file picker sends the JSON path to the AI service")
test.callback()
eq(true, tested, "connection test reaches the configured provider")
return count
