require("library_screen_stub")
local assertx = require("assertions")
local Presenter = require("legado.ui.presenter")
local CoverGrid = require("legado.ui.cover_grid")
package.preload["ui/font"] = function() return {getFace=function() return {} end} end

-- These fakes retain the close contract of KOReader's Menu and FocusManager:
-- Menu:onClose invokes close_callback, while a focus widget closes through its
-- own onClose event and UIManager:close.
do
    local shown, closed, cancelled = {}, {}, 0
    local ui = {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget) closed[#closed + 1] = widget end,
    }
    local Menu = {
        new = function(_, options)
            function options:onClose()
                if self._closed then return false end
                self._closed = true
                ui:close(self)
                if self.close_callback then return self.close_callback() end
                return false
            end
            return options
        end,
    }
    local Input = { new = function(_, options) return options end }
    local presenter = Presenter.new({
        ui_manager = ui,
        menu = Menu, input_dialog = Input,
        info_message = { new = function(_, options) return options end },
    })
    local late_callback
    local view = {
        kind = "search", alive = true, loading = false, results = {}, errors = {},
        submit = function(self)
            self.loading = true
            late_callback = function()
                self.loading = false
                if self.onUpdate then self.onUpdate(self) end
            end
            self.request = { cancel = function() cancelled = cancelled + 1; return true end }
            return self.request
        end,
        cancel = function(self)
            self.loading, self.alive = false, false
            self.request:cancel()
            return true
        end,
    }
    local dialog = presenter:show(view)
    dialog.buttons[1][2].callback("迟到结果")
    local progress = shown[#shown]
    progress:onClose()
    progress:onClose()
    late_callback()
    assertx.equal(1, cancelled, "native Menu Back cancels an in-flight search exactly once")
    assertx.equal(nil, view.progress_widget, "native Menu Back clears the search progress widget")
    assertx.equal(2, #closed, "valid submit closes the input and native Menu Back closes progress once")
    assertx.equal(progress, closed[2], "native Menu Back closes the progress widget")
    assertx.equal(2, #shown, "late search callback cannot reopen results after native close")
end

do
    local close_calls, closed = 0, 0
    local function class(kind)
        return { new = function(_, options) options.kind = kind; return options end }
    end
    local Focus = class("focus")
    function Focus:extend(prototype)
        prototype.new = function(_, options)
            setmetatable(options, { __index = prototype })
            return options
        end
        return prototype
    end
    local Button, Horizontal, Vertical, Frame = class("button"), class("horizontal"), class("vertical"), class("frame")
    local Image, Text = class("image"), class("text")
    local back_group = { "back-group" }
    local grid
    grid = CoverGrid.new({
        model = { items = { { title = "一本书", book = { id = "book" } } } },
        on_close = function() close_calls = close_calls + 1 end,
        dependencies = {
            focus_manager = Focus, button = Button, horizontal_group = Horizontal,
            vertical_group = Vertical, frame = Frame, image = Image, text = Text,
            ui_manager = { close = function(_, widget) closed = closed + 1; assertx.equal(grid, widget, "grid closes itself through UIManager") end },
            device = { hasKeys = function() return true end, input = { group = { Back = back_group } } },
        },
    })
    assertx.equal("返回", grid.close_button.text, "cover grid exposes a touch-reachable return button")
    grid.close_button.callback()
    grid:onClose()
    assertx.equal(1, close_calls, "cover grid close lifecycle is idempotent")
    assertx.equal(1, closed, "cover grid close lifecycle calls UIManager:close once")
    assertx.equal(back_group, grid.key_events.Close[1][1], "cover grid registers KOReader's physical Back group")
end

do
    local shown = {}
    local presenter = Presenter.new({
        ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end },
        menu = { new = function(_, options) return options end },
        info_message = { new = function(_, options) return options end },
    })
    local detail = {
        kind = "book_detail", book = { name = "失败详情" }, info_error = {
            code = "NETWORK_ERROR", message = "https://user:secret@example.test/?token=leak", details = { status = 503 },
        },
        compatibility = function() return { status = "partial", issues = { { field = "ruleContent", code = "UNSUPPORTED_RULE" } } } end,
        startReading = function() return "阅读" end, startDownload = function() return "下载" end,
        addToShelf = function() return true end, removeFromShelf = function() return true end,
        loadCatalog = function(_, callback) callback(nil, nil) end,
        alternatives = {},
    }
    local widget = presenter:show(detail)
    assertx.truthy(widget.subtitle:find("详情加载失败",1,true), "detail failure remains visible inline")
    local diagnostic_action
    widget.actions[2].callback()
    for _,action in ipairs(shown[#shown].items) do if action.text=="详情诊断" then diagnostic_action=action end end
    assertx.truthy(diagnostic_action, "detail failure exposes a clickable diagnostic route")
    diagnostic_action.callback()
    local diagnostic = shown[#shown]
    assertx.truthy(diagnostic.text:find("NETWORK_ERROR", 1, true) ~= nil, "detail diagnostic includes structured error code")
    assertx.truthy(diagnostic.text:find("partial", 1, true) ~= nil, "detail diagnostic includes compatibility report")
    assertx.equal(nil, diagnostic.text:find("secret", 1, true), "detail diagnostic redacts credential-bearing error messages")
end

do
    local BookDetail = require("legado.ui.book_detail")
    local detail = BookDetail.new({
        book = { id = "book", source_id = "source" },
        compatibility = function() return { status = "usable", issues = {} } end,
    })
    assertx.equal("usable", detail:compatibility().status, "real detail controller exposes its selected source compatibility report")
end

do
    local data_root = assert(os.getenv("LEGADO_PLUGIN_ROOT")):gsub("/legado%.koplugin$", "") .. "/.tools/bootstrap-review-data"
    local messages, event = {}, nil
    package.preload["datastorage"] = function() return { getDataDir = function() return data_root end } end
    package.preload["ui/uimanager"] = function() return { scheduleIn = function(_, _, action) return action end, show = function(_, widget) messages[#messages + 1] = widget end } end
    package.preload["ui/event"] = function() return { new = function(_, name) return { name = name } end } end
    package.preload["ui/widget/infomessage"] = function() return { new = function(_, options) return options end } end
    package.preload["legado.lib.storage"] = function() return { new = function() return { listShelf = function() return {} end, listSources = function() return {} end, getSource = function() end } end } end
    package.preload["legado.lib.request_engine"] = function() return { new = function(options) return { scheduler = options.scheduler, execute = function() return { cancel = function() return true end } end } end } end
    local Bootstrap = require("legado.ui.bootstrap")
    local app = Bootstrap.build({ ui = { handleEvent = function(_, received) event = received; return false end } }, {
        settings_adapter = { read = function() return { default_sources_initialized = true } end, write = function() return true end },
    })
    assertx.equal(false, app:openSettings().actions[1].callback(), "unhandled reader appearance event reports failure")
    assertx.equal("ShowConfigMenu", event.name, "appearance action sends the KOReader ShowConfigMenu event")
    assertx.truthy(messages[#messages].text:find("阅读界面", 1, true) ~= nil, "unhandled reader appearance event explains the required reader context")
end

return 18
