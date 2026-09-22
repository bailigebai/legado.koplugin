local assertx = require("assertions")
local CoverGrid = require("legado.ui.cover_grid")
package.preload["ui/font"] = function() return {getFace=function() return {} end} end

local function class(kind)
    return { new = function(_, options) options.kind = kind; return options end }
end

local shared_events = { Existing = { { "ExistingKey" } } }
local Focus = { key_events = shared_events }
function Focus:extend(prototype)
    setmetatable(prototype, { __index = self })
    prototype.new = function(_, options)
        setmetatable(options, { __index = prototype })
        return options
    end
    return prototype
end

local function dependencies(device)
    return {
        focus_manager = Focus, button = class("button"), horizontal_group = class("horizontal"),
        vertical_group = class("vertical"), frame = class("frame"), image = class("image"), text = class("text"),
        ui_manager = { close = function() end }, device = device,
    }
end

local back_group = { "physical-back" }
local keyed = CoverGrid.new({
    model = { items = {} },
    dependencies = dependencies({ hasKeys = function() return true end, input = { group = { Back = back_group } } }),
})
local keyless = CoverGrid.new({
    model = { items = {} },
    dependencies = dependencies({ hasKeys = function() return false end, input = { group = { Back = { "not-used" } } } }),
})

assertx.equal(back_group, keyed.key_events.Close[1][1], "keyed grid owns the physical Back binding")
assertx.equal(nil, keyless.key_events.Close, "keyless grid receives no Close binding after a keyed grid")
assertx.equal(nil, shared_events.Close, "FocusManager shared key_events table is not mutated")
assertx.equal(shared_events.Existing, keyed.key_events.Existing, "keyed grid preserves inherited non-Close bindings")
assertx.equal(shared_events.Existing, keyless.key_events.Existing, "keyless grid preserves inherited non-Close bindings")
assertx.truthy(rawget(keyed, "key_events") ~= shared_events, "keyed grid has a private key-events table")
assertx.truthy(rawget(keyless, "key_events") ~= shared_events, "keyless grid has a private key-events table")

return 7
