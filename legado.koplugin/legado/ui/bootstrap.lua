local App = require("legado.ui.app")
local Fs = require("legado.lib.fs")
local Settings = require("legado.lib.settings")

local Bootstrap = {}

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

local function native_appearance(plugin)
    return function()
        local Event = optional("ui/event")
        if plugin.ui and type(plugin.ui.handleEvent) == "function" and Event and type(Event.new) == "function" then
            plugin.ui:handleEvent(Event:new("ShowReaderConfigMenu"))
            return true
        end
        local UIManager, InfoMessage = optional("ui/uimanager"), optional("ui/widget/infomessage")
        if UIManager and InfoMessage and type(UIManager.show) == "function" and type(InfoMessage.new) == "function" then
            UIManager:show(InfoMessage:new({ text = "请在 KOReader 阅读界面中使用原生字体和背景设置。" }))
            return true
        end
        return false
    end
end

function Bootstrap.build(plugin)
    local settings = Settings.new()
    local storage, service, source_manager, cover_loader, root
    local DataStorage = optional("datastorage")
    local fs = Fs.new()
    if DataStorage and type(DataStorage.getDataDir) == "function" then
        root = DataStorage:getDataDir() .. "/legado"
        fs:ensureDirectory(root)
        local Storage = require("legado.lib.storage")
        storage = Storage.new({ path = root .. "/legado.sqlite", fs = fs })
    end

    if storage then
        local RuleEngine = require("legado.lib.rule_engine")
        local SafeFunctions = require("legado.lib.safe_functions")
        local Json = require("legado.lib.json_codec")
        local HtmlParser = require("legado.vendor.htmlparser")
        local rules = RuleEngine.new({
            json_decoder = Json, html_parser = HtmlParser,
            url_resolver = SafeFunctions.resolve_url, safe_functions = SafeFunctions.functions,
        })
        local UIManager = optional("ui/uimanager")
        if UIManager and type(UIManager.scheduleIn) == "function" then
            local RequestEngine = require("legado.lib.request_engine")
            local UrlTemplate = require("legado.lib.url_template")
            local BookService = require("legado.lib.book_service")
            local requests = RequestEngine.new({ scheduler = UIManager, settings = settings })
            local templates = UrlTemplate.new({ rule_engine = rules })
            service = BookService.new({ storage = storage, rule_engine = rules, request_engine = requests, url_template = templates, settings = settings })
            local SourceImporter = require("legado.lib.source_importer")
            local SourceManager = require("legado.ui.source_manager")
            source_manager = SourceManager.new({
                storage = storage, importer = SourceImporter:new({ storage = storage }),
                request_engine = requests, fs = fs,
                confirm = function(message, accepted)
                    local ConfirmBox = optional("ui/widget/confirmbox")
                    if not (UIManager and ConfirmBox) then return false end
                    UIManager:show(ConfirmBox:new({ text = message, ok_callback = accepted }))
                    return "pending"
                end,
            })
            local CoverLoader = require("legado.lib.cover_loader")
            local loader = CoverLoader.new({ request_engine = requests, fs = fs, root = root .. "/covers" })
            cover_loader = function(book, callback) return loader:load(book, callback) end
        end
    end

    local presenter
    local UIManager = optional("ui/uimanager")
    if UIManager and type(UIManager.show) == "function" then presenter = require("legado.ui.presenter").new({ ui_manager = UIManager }) end
    local app
    app = App.new({
        storage = storage, book_service = service, source_manager = source_manager, settings = settings,
        appearance = native_appearance(plugin),
        cover_loader = cover_loader,
        show = presenter and function(view) return presenter:show(view) end or nil,
    })
    if presenter then presenter.detail_factory = function(book, alternatives) return app:createBookDetail(book, alternatives) end end
    return app
end

return Bootstrap
