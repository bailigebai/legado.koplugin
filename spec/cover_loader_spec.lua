local assertx = require("assertions")
local CoverLoader = require("legado.lib.cover_loader")

local pending, captured
local requests = { execute = function(_, request, callback) captured = request; pending = callback; return { cancel = function() return true end } end }
local writes = {}
local fs = {
    ensureDirectory = function() return true end,
    atomicWrite = function(_, path, body) writes[#writes + 1] = { path, body }; return true end,
}
local loader = CoverLoader.new({ request_engine = requests, fs = fs, root = "/data/covers" })
local path, failure
local handle = loader:load({ id = "book-secret-id", source_id = "opaque-source", cover_url = "https://covers.test/one" }, function(value, err) path, failure = value, err end)
assertx.equal("opaque-source", captured.source_id, "cover cookies use only opaque source scope")
assertx.equal(2 * 1024 * 1024, captured.max_bytes, "cover response has a strict byte limit")
pending({ status = 200, headers = { ["Content-Type"] = "image/jpeg" }, body = "jpeg-bytes" }, nil)
assertx.equal(nil, failure, "valid cover load succeeds")
assertx.truthy(path:match("%.jpg$"), "content type selects a safe extension")
assertx.equal("jpeg-bytes", writes[1][2], "cover bytes are atomically written")
assertx.equal("function", type(handle.cancel), "cover loader returns the network cancel handle")

return 6
