local assertx = require("assertions")
local Json = require("legado.lib.json_codec")

local count = 0
local function equal(expected, actual, message) count = count + 1; assertx.equal(expected, actual, message) end
local function truthy(value, message) count = count + 1; assertx.truthy(value, message) end

for _, text in ipairs({
    '{"schema_version":1,"schema_version":1}',
    '{"settings":{},"settings":{}}',
    '{"settings":{"prefetch":3,"prefetch":4}}',
    '{"outer":{"key":1,"key":2}}',
}) do
    local ok, decode_error = pcall(Json.decode, text)
    equal(false, ok, "duplicate JSON object key is rejected at every object depth")
    truthy(tostring(decode_error):find("duplicate JSON object key", 1, true),
        "duplicate-key decode error is explicit")
end

local valid = Json.decode('{"outer":{"key":1},"items":[{"key":1},{"key":2}]}')
equal(1, valid.outer.key, "unique nested objects remain valid")
equal(2, valid.items[2].key, "same key in separate objects remains valid")

return count
