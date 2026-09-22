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
            local handled = plugin.ui:handleEvent(Event:new("ShowConfigMenu"))
            if handled then return true end
            local UIManager, InfoMessage = optional("ui/uimanager"), optional("ui/widget/infomessage")
            if UIManager and InfoMessage and type(UIManager.show) == "function" and type(InfoMessage.new) == "function" then
                UIManager:show(InfoMessage:new({ text = "请在 KOReader 阅读界面中使用原生字体和背景设置。" }))
            end
            return false
        end
        local UIManager, InfoMessage = optional("ui/uimanager"), optional("ui/widget/infomessage")
        if UIManager and InfoMessage and type(UIManager.show) == "function" and type(InfoMessage.new) == "function" then
            UIManager:show(InfoMessage:new({ text = "请在 KOReader 阅读界面中使用原生字体和背景设置。" }))
            return true
        end
        return false
    end
end

function Bootstrap.build(plugin, options)
    if not options and Bootstrap.active_app then
        Bootstrap.active_app.appearance=native_appearance(plugin)
        return Bootstrap.active_app
    end
    local shared=options==nil
    options = options or {}
    local settings, settings_error = Settings.new(options.settings_adapter, options.settings_options)
    local License = require("legado.lib.license")
    local LicenseStore = require("legado.lib.license_store")
    local license = License.new({ store = LicenseStore.new(settings) })
    local storage, service, source_manager, cover_loader, reader_session, download_manager, root, local_library
    local presenter
    local DataStorage = optional("datastorage")
    local fs = options.fs or Fs.new()
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
        local HtmlParser = require("legado.vendor.htmlparser.init")
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
            local diagnostics = require("legado.lib.diagnostics").new({ book_service = service })
            local SourceImporter = require("legado.lib.source_importer")
            local SourceManager = require("legado.ui.source_manager")
            source_manager = SourceManager.new({
                storage = storage, importer = SourceImporter:new({ storage = storage, json = Json }),
                request_engine = requests, fs = fs,
                diagnostics = diagnostics,
                confirm = function(message, accepted)
                    local ConfirmBox = optional("ui/widget/confirmbox")
                    if not (UIManager and ConfirmBox) then return false end
                    UIManager:show(ConfirmBox:new({ text = message, ok_callback = accepted }))
                    return "pending"
                end,
            })
            local CoverLoader = require("legado.lib.cover_loader")
            local loader = CoverLoader.new({ request_engine = requests, fs = fs, root = root .. "/covers" })
            local_library = require('legado.lib.local_library').new({settings=settings,fs=fs,storage=storage,
                service=service,cover_loader=loader,root=root..'/covers',scheduler=UIManager})
            cover_loader = function(book, callback)
                if book.is_local then return local_library:loadCover(book,callback) end
                return loader:load(book, callback)
            end
            local CacheStore = require("legado.lib.cache_store")
            local ReaderSession = require("legado.lib.reader_session")
            local ReaderUIAdapter = require("legado.lib.koreader_reader_ui")
            local cache = CacheStore.new({ fs = fs, root = root .. "/cache", settings = settings, scheduler = UIManager })
            local reader_ui = ReaderUIAdapter.new({settings=settings,ui_manager=UIManager})
            local Statistics=optional('legado.lib.koreader_statistics')
            local native=plugin.ui and plugin.ui.statistics
            local statistics=Statistics and Statistics.new{settings=native and native.settings or {is_enabled=false}}
            local statistics_warned=false
            reader_session = ReaderSession.new({ cache = cache, storage = storage,
                service = service, ui = reader_ui, settings = settings, scheduler = UIManager,statistics=statistics,
                timing=function(metric)
                    local logger=optional('logger')
                    if logger and logger.dbg then
                        logger.dbg('[LegadoTiming]',metric.stage,metric.ms,metric.backend,
                            'attempt',metric.attempt,'total_ms',metric.total_ms,'over_budget',metric.over_budget)
                    end
                end,
                diagnostics = function(stage, err)
                    if stage=='statistics' then
                        if statistics_warned then return end
                        statistics_warned=true
                        local Info=optional('ui/widget/infomessage')
                        if Info then UIManager:show(Info:new{text='KOReader 统计暂未写入；插件阅读回顾仍正常记录。请先启用阅读统计并打开统计页。',timeout=5}) end
                        return
                    end
                    if stage ~= "read" and stage ~= "reader" then return end
                    local InfoMessage = optional("ui/widget/infomessage")
                    if not InfoMessage then return end
                    local text = "阅读失败，请检查书源、网络或缓存。"
                    if type(err)=='table' and err.code=='UNSUPPORTED_CONTENT' then
                        text='本章含图片，无感阅读暂不支持；请在阅读菜单关闭无感阅读后使用原生模式。'
                    elseif type(err)=='table' and err.code=='READER_ERROR' and type(err.message)=='string' then
                        text=err.message
                    elseif type(err) == "table" and err.message == "next chapter is not cached" then
                        text = "下一章尚未缓存，请联网下载后继续阅读。"
                    end
                    if presenter then presenter:_info(text)
                    else UIManager:show(InfoMessage:new({ text = text })) end
                end })
            if type(storage.listDownloadTasks) == "function" and type(storage.putDownloadTask) == "function"
                and type(storage.listChapters) == "function" and type(storage.replaceChapters) == "function" then
                local download_root = root .. "/downloads"
                fs:ensureDirectory(download_root)
                local EpubBuilder = require("legado.lib.epub_builder")
                local DownloadManager = require("legado.lib.download_manager")
                local StandbyGuard = require("legado.lib.standby_guard")
                download_manager = DownloadManager.new({ storage = storage, cache = cache, book_service = service,
                    builder = EpubBuilder.new({ fs = fs }), standby = StandbyGuard.new({ ui_manager = UIManager }),
                    scheduler = UIManager, output_root = download_root,
                    open_final = function(path) return reader_ui:openDocument(path) end })
            end
        end
    end

    local UIManager = optional("ui/uimanager")
    if UIManager and type(UIManager.show) == "function" then presenter = require("legado.ui.presenter").new({ ui_manager = UIManager }) end
    local app
    app = App.new({
        version = plugin.version,
        license = license,
        storage = storage, book_service = service, source_manager = source_manager, settings = settings,
        settings_error = settings_error,
        appearance = native_appearance(plugin),
        cover_loader = cover_loader,
        reader_session = reader_session,
        download_manager = download_manager,
        fs = fs,
        local_library = local_library,
        native_statistics = plugin.ui and plugin.ui.statistics,
        scheduler = UIManager,
        show_native_statistics = presenter and function(statistics,document) return presenter:showNativeStatistics(statistics,document) end or nil,
        show = presenter and function(view) return presenter:show(view) end or nil,
    })
    if presenter then
        presenter.app = app
        presenter.cover_loader = cover_loader
        presenter.detail_factory = function(book, alternatives) return app:createBookDetail(book, alternatives) end
    end
    if reader_session and reader_session.ui then
        reader_session.ui.on_exit = function(doc) return app:exitReader(doc) end
        reader_session.ui.on_toc = function(doc) return app:openReadingCatalog(reader_session.active,doc) end
        reader_session.ui.on_settings = function(doc) return app:openSettings(doc) end
        reader_session.ui.on_chrome_settings = function(doc) return app:openSettings(doc, true) end
        reader_session.ui.on_sources = function(doc) return app:openReaderSources(reader_session.active,doc) end
        reader_session.ui.on_book_search = function(doc) return app:openReaderBookSearch(reader_session.active,doc) end
        reader_session.ui.on_source_sites = function(doc) return app:openReaderSourceSites(reader_session.active,doc) end
        reader_session.ui.on_review = function(doc) return app:openReadingReview(nil,doc) end
        reader_session.ui.on_receipt = function(doc) return app:openCurrentReceipt(doc) end
        reader_session.ui.on_statistics = function(doc) return app:openNativeStatistics(doc) end
        reader_session.ui.on_toggle_reader = function(doc) return app:toggleImmersiveReader(doc) end
        reader_session.ui.on_book_info = function(doc) return app:openReaderBookInfo(doc) end
        reader_session.ui.on_add_to_shelf = function(doc) return app:addReaderToShelf(doc) end
    end
    if shared then Bootstrap.active_app=app end
    return app
end

return Bootstrap
