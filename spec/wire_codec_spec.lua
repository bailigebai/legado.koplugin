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

return 6
