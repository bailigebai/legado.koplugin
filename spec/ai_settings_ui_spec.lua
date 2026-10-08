require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local function item(widget, label)
    for _, candidate in ipairs(widget.item_table or {}) do
        if candidate.text == label then return candidate end
    end
end
local values = { ai_provider = "deepseek", ai_deepseek_key_file = "", ai_mimo_key_file = "", ai_prompt_extra = "" }
local fail_key
local settings = { all = function() return values end, get = function(_, key) return values[key] end,
    set = function(_, key, value)
        if key == fail_key then return nil, {code = "STORAGE_ERROR"} end
        values[key] = value
        return true
    end }
local chosen, pending_tests = nil, {}
local ai = { setKeyFile = function(_, provider, path) chosen = provider .. ":" .. path; return true end,
    testConnection = function(_, callback) pending_tests[#pending_tests + 1] = callback; return true end }
local shown = {}
local presenter = Presenter.new{ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end },
    input_dialog = { new = function(_, options) return options end }}
local app = App.new{settings = settings, ai_service = ai, show = function(view) return presenter:show(view) end}
presenter.app = app
app:openSettings()
local entry = item(shown[#shown], "AI 服务设置")
eq("function", type(entry and entry.callback), "settings expose the AI service page")
entry.callback()
local ai_page = shown[#shown]
eq("AI 服务", ai_page.title, "AI settings have a dedicated page")
eq(true, item(ai_page, "✓ DeepSeek") ~= nil, "DeepSeek is visibly selected by default")
eq(true, item(ai_page, "□ 小米 MiMo") ~= nil, "MiMo is visibly unselected by default")

ai_page = item(ai_page, "□ 小米 MiMo").callback()
eq("mimo", values.ai_provider, "provider selector saves MiMo")
eq(true, item(ai_page, "✓ 小米 MiMo") ~= nil, "MiMo is visibly selected after switching")
eq(true, item(ai_page, "□ DeepSeek") ~= nil, "DeepSeek is visibly unselected after switching")
item(ai_page, "选择密钥 JSON 文件").callback()
shown[#shown].buttons[1][2].callback("mimo.json")
eq("mimo:mimo.json", chosen, "file picker sends the JSON path to the AI service")
ai_page = shown[#shown]

item(ai_page, "测试连接").callback()
eq(1, #pending_tests, "connection test reaches the configured provider")
pending_tests[1]("连接成功")
eq("AI 连接成功", shown[#shown].text, "current connection test shows success")

item(ai_page, "测试连接").callback()
item(ai_page, "测试连接").callback()
local before_stale = #shown
pending_tests[2]("连接成功")
eq(before_stale, #shown, "earlier repeated test cannot show a stale result")
pending_tests[3]("连接成功")
eq(before_stale + 1, #shown, "latest repeated test still shows success")

item(ai_page, "测试连接").callback()
ai_page = item(ai_page, "□ DeepSeek").callback()
before_stale = #shown
pending_tests[4]("连接成功")
eq(before_stale, #shown, "switching provider suppresses the previous test result")
eq("deepseek", values.ai_provider, "provider switch updates saved setting")
ai_page = item(ai_page, "□ 小米 MiMo").callback()

fail_key = "ai_provider"
item(ai_page, "□ DeepSeek").callback()
eq("mimo", values.ai_provider, "failed provider save keeps the prior service")
eq(true, type(shown[#shown].text) == "string"
    and shown[#shown].text:find("设置保存失败", 1, true) ~= nil,
    "provider save failure is visible")
fail_key = "ai_prompt_extra"
item(ai_page, "补充提示词").callback()
shown[#shown].buttons[1][2].callback("解释更多术语")
eq("", values.ai_prompt_extra, "failed prompt save keeps the prior prompt")
eq(true, type(shown[#shown].text) == "string"
    and shown[#shown].text:find("设置保存失败", 1, true) ~= nil,
    "prompt save failure is visible")

item(ai_page, "测试连接").callback()
shown[#shown]:onCloseWidget()
before_stale = #shown
pending_tests[5]("连接成功")
eq(before_stale, #shown, "dismissing the waiting window suppresses the pending test result")
do
    local displays,pending={},nil
    local real_close=Presenter.new{menu={new=function(_,options) return options end},
        info_message={new=function(_,options) return options end},
        ui_manager={show=function(_,widget) displays[#displays+1]=widget end,close=function() end}}
    local model={refresh=function() return values end,settings=settings,
        ai_service={testConnection=function(_,done) pending=done;return {cancel=function() end} end}}
    local page=real_close:_aiSettings(model)
    item(page,'测试连接').callback()
    page.close_callback() -- Menu closes naturally after item selection.
    local before=#displays
    pending('连接成功')
    eq(before+1,#displays,'connection test result survives normal Menu selection close')
    eq('AI 连接成功',displays[#displays].text,'connection success is visible after Menu closes')
end
return count
