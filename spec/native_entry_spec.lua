local A = require("assertions")
local count = 0
local function equal(expected, actual, message)
    count = count + 1
    A.equal(expected, actual, message)
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(base, fields) return setmetatable(fields, { __index = base }) end }
end
local plugin = require("main")
local registered
local instance = setmetatable({ ui = { menu = {
    registerToMainMenu = function(_, value) registered = value end,
} } }, { __index = plugin })
equal("function", type(instance.init), "KOReader initialization registers the plugin")
instance:init()
equal(instance, registered, "host receives the plugin menu provider")
equal(nil, instance._app, "loading a document does not rebuild book services")

-- The compatibility check supplies the pinned upstream module; unit runs use its public shape.
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
local upstream = os.getenv("LEGADO_KOREADER_SOURCE")
local Event = upstream and dofile(upstream .. "/frontend/ui/event.lua") or {
    new = function(_, name, ...) return { handler = "on" .. name, args = table.pack(...) } end,
}
package.preload["ui/event"] = function() return Event end
local Adapter = require("legado.lib.koreader_reader_ui")
local forwarded, ended, flushed, closed = 0, 0, 0, 0
local reader = {
    handleEvent = function(_, event) forwarded = forwarded + 1; return event.handler end,
    onFlushSettings = function() return "flushed" end,
    onClose = function() return "closed" end,
}
local adapter = Adapter.new({ ReaderUI = {
    showReader = function(_, _, _, _, _, ready) ready(reader) end,
} })
local document = assert(adapter:openDocument("chapter.html", {
    end_of_book = function() ended = ended + 1 end,
    flush = function() flushed = flushed + 1 end,
    close = function() closed = closed + 1 end,
}))
equal(true, reader:handleEvent(Event:new("EndOfBook")), "native end event reaches the chapter session")
equal(1, ended, "chapter navigation runs once")
equal(0, forwarded, "native final-book action waits for chapter navigation")
equal("onPageUpdate", reader:handleEvent(Event:new("PageUpdate")), "unrelated events retain native dispatch")
equal("onEndOfBook", adapter:endOfBook(document), "last chapter can forward to native book completion")
equal(2, forwarded, "fallback invokes saved native dispatcher without recursion")
equal("flushed", reader:onFlushSettings(), "native settings flush still runs")
equal("closed", reader:onClose(), "native reader close still runs")
equal(1, flushed, "plugin progress flush runs")
equal(1, closed, "plugin progress close runs")
return count
