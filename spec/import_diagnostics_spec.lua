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

local source_json = '{"bookSourceName":"Book","bookSourceUrl":"https://sources.test"}'
local reads, writes, selected = 0, 0, nil
local storage = {listSources=function() return {} end, listShelf=function() return {} end,
    replaceSources=function() writes=writes+1; return true end}
local manager = SourceManager.new({storage=storage, importer=Importer:new({storage=storage}),
    fs={readBounded=function(_, path, limit)
        reads=reads+1; selected=path
        assert(limit==5*1024*1024);count=count+1
        if path=='/mnt/us/书源 test.json' then return source_json end
        return nil, Errors.new('STORAGE_ERROR','private missing file',{path=path,cause='private'})
    end}})
local function check(ok, message) assert(ok,message); count=count+1 end
local report=manager:importLocal(' \n"/mnt/us/书源 test.json"\r\n ')
check(not report.error and report.imported==1,'quoted/pasted local path imports successfully')
check(selected=='/mnt/us/书源 test.json','internal spaces and Unicode in filename survive')
check(writes==1,'exactly one commit after valid file selection')
local before=reads
report=manager:importLocal(' https://sources.test/source.json ')
check(report.error.code=='INVALID_INPUT' and reads==before,'URL in local entry never becomes a filesystem error')
check(report.error.details.reason=='source_path_is_url','wrong entry has actionable reason')
report=manager:importLocal('/missing/private.json')
check(report.error.details.stage=='source_file_read','file failures retain their distinct stage')
check(writes==1,'file failure never replaces existing sources')

-- Read failure must retain the database error, instead of pretending the source file is bad.
storage.listSources=function() return nil,Errors.new('STORAGE_ERROR','private SQL',{
    operation='read',sqlite_code='busy',cause='private header'}) end
report=manager:importLocal('/mnt/us/书源 test.json')
check(report.error.details.sqlite_code=='busy' and report.error.details.operation=='read','read error survives importer')
check(writes==1,'read failure never reaches replacement')
storage.listSources=function() return {} end

-- Real UI routing: use KOReader's chooser when available; cancellation leaves the list underneath.
package.loaded['ui/widget/pathchooser']=widget
G_reader_settings={readSetting=function() return '/mnt/us/documents' end}
local menu=presenter:show(manager)
local function open_local()
    for _, action in ipairs(menu.item_table) do if action.text=='从本地 JSON 导入' then action.callback();return shown[#shown] end end
    error('missing local import action')
end
local picker=open_local()
check(picker.select_file==true and picker.select_directory==false,'native picker selects JSON file')
check(picker.file_filter('SOURCE.JSON') and not picker.file_filter('book.epub'),'file filter accepts JSON regardless of case')
check(picker.path=='/mnt/us/documents','native picker uses the configured home')
check(writes==1,'opening picker does not import or mutate')
picker.onConfirm('/mnt/us/书源 test.json')
check(writes==2 and shown[#shown].text:find('新增 1',1,true),'selected file reaches importer and reports success')
menu=presenter:show(manager);picker=open_local();picker.onConfirm('/missing/private.json')
local text=shown[#shown].text
check(text:find('读取书源文件',1,true) and not text:find('存储空间',1,true),'file error does not guess that disk is full')
check(not text:find('private',1,true),'file diagnostics never display raw path/cause')
menu=presenter:show(manager);picker=open_local();picker.onConfirm('https://sources.test/private.json')
check(shown[#shown].text:find('从网址导入',1,true),'URL entered as local file points to the right entry')
local previous=writes
menu=presenter:show(manager);picker=open_local();manager:close();picker.onConfirm('/mnt/us/书源 test.json')
check(writes==previous,'stale chooser callback after leaving source manager cannot import')
package.loaded['ui/widget/pathchooser']=nil
G_reader_settings=nil
return count
