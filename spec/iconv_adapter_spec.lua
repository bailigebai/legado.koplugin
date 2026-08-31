local assertx = require("assertions")
local IconvAdapter = require("legado.lib.iconv_adapter")

local fixtures = {
    ["gbk:\214\208"] = "中",
    ["gb18030:\148\57\252\54"] = "😀",
}

local calls = { opened = {}, closed = 0 }
local fake_ffi = {}
function fake_ffi.new(kind, value)
    if kind == "int[1]" or kind == "unsigned long[1]" then return { [0] = value or 0 } end
    if kind == "const char *[1]" then return { [0] = value } end
    if kind == "char *[1]" then return { [0] = value } end
    if kind == "char[?]" then return { capacity = value, data = "" } end
    error("unexpected fake FFI type: " .. tostring(kind))
end
function fake_ffi.string(buffer, length) return buffer.data:sub(1, length) end

local api = {}
function api.miniconv_open2(to, from, error_out)
    calls.opened[#calls.opened + 1] = { to = to, from = from }
    error_out[0] = 0
    return from
end
function api.miniconv2(handle, in_ptr, in_left, out_ptr, out_left, error_out)
    local output = fixtures[handle:lower() .. ":" .. in_ptr[0]]
    if not output or #output > out_left[0] then error_out[0] = 84; return -1 end
    out_ptr[0].data = output
    in_left[0] = 0
    out_left[0] = out_left[0] - #output
    error_out[0] = 0
    return 0
end
function api.miniconv_close() calls.closed = calls.closed + 1; return 0 end

local adapter = IconvAdapter.new({ ffi = fake_ffi, library = api })
local gbk, gbk_error = adapter:convert("\214\208", "gbk", "utf-8")
assertx.equal(nil, gbk_error, "injected miniconv ABI converts GBK bytes")
assertx.equal("中", gbk, "real GBK fixture converts to UTF-8")
local gb18030, gb18030_error = adapter:convert("\148\57\252\54", "gb18030", "utf-8")
assertx.equal(nil, gb18030_error, "injected miniconv ABI converts GB18030 bytes")
assertx.equal("😀", gb18030, "real four-byte GB18030 fixture converts to UTF-8")
assertx.equal(2, calls.closed, "descriptor closes after every conversion")
assertx.equal("UTF-8", calls.opened[1].to, "target charset uses native canonical name")

local unavailable = IconvAdapter.new({ ffi = false, library = false })
assertx.equal(false, unavailable:available(), "missing native symbols fail capability probe")
local missing, missing_error = unavailable:convert("\214\208", "gbk", "utf-8")
assertx.equal(nil, missing, "missing native converter returns no data")
assertx.truthy(tostring(missing_error):find("unavailable", 1, true) ~= nil,
    "missing native converter reports capability error")

return 9
