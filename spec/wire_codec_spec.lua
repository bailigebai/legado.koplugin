local assertx = require("assertions")
local Wire = require("legado.lib.wire_codec")

local encoded, encode_error = Wire.encode({ body = string.rep("x", Wire.MAX_BYTES + 1) })
assertx.equal(nil, encoded, "oversized wire encoding is rejected")
assertx.truthy(tostring(encode_error):find("limit", 1, true) ~= nil, "oversized encoding has bounded diagnostic")

local decoded, decode_error = Wire.decode(string.rep("x", Wire.MAX_BYTES + 1))
assertx.equal(nil, decoded, "oversized wire input is rejected before parsing")
assertx.truthy(tostring(decode_error):find("limit", 1, true) ~= nil, "oversized decode has bounded diagnostic")

local malformed, malformed_error = Wire.decode("S999999999999999999999999999999999999999999:x")
assertx.equal(nil, malformed, "malformed huge length is rejected")
assertx.truthy(type(malformed_error) == "string", "malformed huge length returns diagnostic")

local collection = string.rep(" ", 4 * 1024 * 1024 + 256 * 1024) .. "[]"
local collection_wire, collection_error = Wire.encode({ body = collection })
assertx.truthy(collection_wire ~= nil, "a 4.46 MiB source collection fits the import pipe")
assertx.equal(nil, collection_error, "large source collection has no wire error")
local collection_value = collection_wire and Wire.decode(collection_wire)
assertx.equal(#collection, collection_value and #collection_value.body, "large source collection survives the wire round trip")

return 9
