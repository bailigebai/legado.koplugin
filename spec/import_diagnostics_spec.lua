require("library_screen_stub")
local Presenter = require("legado.ui.presenter")
local SourceManager = require("legado.ui.source_manager")
local Importer = require("legado.lib.source_importer")
local Errors = require("legado.lib.errors")
local shown, count = {}, 0
local widget = {new=function(_, options) return options end}
local presenter = Presenter.new({menu=widget, info_message=widget, input_dialog=widget,
    ui_manager={show=function(_, value) shown[#shown+1]=value end, close=function() end}})
for _, case in ipairs({
    {code="full", text="存储空间不足"}, {code="readonly", text="数据目录不可写"},
    {code="busy", text="数据库正被占用"}, {code="error", text="数据库执行失败"},
    {code="private-cookie", text="本地数据读写失败"},
}) do
    local storage = {listSources=function() return {} end, listShelf=function() return {} end,
        replaceSources=function() return nil, Errors.new("STORAGE_ERROR", "private-cookie", {
            operation="write", sqlite_code=case.code, cause="private-cookie; SQL with private source headers",
        }) end}
    local manager = SourceManager.new({storage=storage, importer=Importer:new({storage=storage}),
        fs={read=function() return '{"bookSourceName":"Book","bookSourceUrl":"https://sources.test"}' end}})
    local menu = presenter:show(manager)
    for _, action in ipairs(menu.item_table) do if action.text=="从本地 JSON 导入" then action.callback() end end
    shown[#shown].buttons[1][2].callback("sources.json")
    local text = shown[#shown].text
    assert(text:find(case.text, 1, true), "import error explains the actual storage failure"); count=count+1
    assert(text:find("保存本地数据库", 1, true), "import error identifies its operation"); count=count+1
    assert(not text:find("private", 1, true), "import error never exposes native SQL or source credentials"); count=count+1
    assert(not text:find("检查书源配置", 1, true), "storage failure does not blame rule configuration"); count=count+1
end
return count
