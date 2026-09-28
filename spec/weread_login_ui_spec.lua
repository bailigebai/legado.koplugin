require("library_screen_stub")
local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, scheduled, delays, closed_widgets = {}, {}, {}, {}
local ui = { show = function(_, widget) shown[#shown + 1] = widget end,
    close = function(_, widget) closed_widgets[widget] = true end,
    scheduleIn = function(_, delay, callback)
        delays[#delays + 1] = delay
        scheduled[#scheduled + 1] = callback
        return callback
    end,
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
eq(0.2, delays[1], "normal QR waiting restarts polling promptly")
scheduled[1]()
poll_callback(nil, "retrying")
eq(3, delays[2], "temporary network error backs off before polling again")
eq("网络暂时不可用，正在重试…", view.status, "retry status explains the wait")
scheduled[2]()
poll_callback("wx-code", "confirmed")
complete_callback({ vid = "1234" })
eq("已登录", view.status, "confirmed login updates the page")
eq(false, cancelled == true, "successful login does not cancel the session")

app.storage = {listShelf = function() return {} end, getProgress = function() return nil end}
cancelled = false
local pending_view = app:openWeRead()
local pending_login
for _, item in ipairs(shown[#shown].actions) do
    if item.text == "微信扫码登录" then pending_login = item end
end
pending_login.callback()
begin_callback({uuid = "pending", payload = "https://open.weixin.qq.com/connect/confirm?uuid=pending"})
local pending_qr = shown[#shown]
app:openBookshelf()
eq(true, closed_widgets[pending_qr] == true, "leaving WeRead closes the pending QR widget")
eq(true, cancelled == true, "leaving WeRead cancels the pending login request")
eq(false, pending_view.alive, "leaving WeRead closes its login controller")
return count
