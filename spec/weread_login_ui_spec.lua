require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, scheduled = {}, {}
local ui = { show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end,
    scheduleIn = function(_, _, callback) scheduled[#scheduled + 1] = callback; return callback end,
    unschedule = function() end }
local begin_callback, poll_callback, complete_callback, cancelled
local auth = {
    hasSession = function() return false end,
    beginLogin = function(_, callback) begin_callback = callback; return { cancel = function() cancelled = true end } end,
    pollLogin = function(_, _, callback) poll_callback = callback; return { cancel = function() cancelled = true end } end,
    completeLogin = function(_, _, callback) complete_callback = callback; return { cancel = function() cancelled = true end } end,
}
local presenter = Presenter.new{ui_manager = ui,
    qr_message = { new = function(_, options) options.kind = "qr"; return options end }}
local app = App.new{weread_auth = auth, scheduler = ui, show = function(view) return presenter:show(view) end}
presenter.app = app
local view = app:openWeRead()
eq("weread", view.kind, "WeRead has a standalone entry")
local login
for _, item in ipairs(shown[#shown].actions) do if item.text == "微信扫码登录" then login = item end end
eq("function", type(login and login.callback), "login is reachable from the WeRead page")
login.callback()
begin_callback({ uuid = "uuid", payload = "https://open.weixin.qq.com/connect/confirm?uuid=uuid" })
eq("qr", shown[#shown].kind, "login displays a native QR widget")
eq(true, type(poll_callback) == "function", "scan polling starts while QR is visible")
poll_callback(nil, "waiting")
scheduled[1]()
poll_callback("wx-code", "confirmed")
complete_callback({ vid = "1234" })
eq("已登录", view.status, "confirmed login updates the page")
eq(false, cancelled == true, "successful login does not cancel the session")
return count
