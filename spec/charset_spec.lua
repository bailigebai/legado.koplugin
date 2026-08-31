local assertx = require("assertions")
local Charset = require("legado.lib.charset")

local converter = {
    convert = function(_, input, from, to)
        if input:find("\214\208", 1, true) and (from == "gbk" or from == "gb2312" or from == "gb18030") and to == "utf-8" then
            return (input:gsub("\214\208", "中"))
        end
        return nil, "invalid input"
    end,
}
local charset = Charset.new({ converter = converter })

local bom_text, bom_name = charset:decode("\239\187\191hello", {
    ["Content-Type"] = "text/html; charset=gbk",
})
assertx.equal("hello", bom_text, "UTF-8 BOM is stripped")
assertx.equal("utf-8", bom_name, "BOM wins over HTTP charset")

local http_text, http_name = charset:decode("\214\208<meta charset='utf-8'>", {
    ["content-type"] = "text/html; charset=GB2312",
})
assertx.equal("中", http_text:sub(1, #"中"), "HTTP charset drives conversion")
assertx.equal("gb2312", http_name, "HTTP charset is normalized")

local meta_text, meta_name = charset:decode("<meta charset=GBK>\214\208", {})
assertx.equal("<meta charset=GBK>中", meta_text, "HTML meta charset drives conversion")
assertx.equal("gbk", meta_name, "meta charset is normalized")

local utf8_text, utf8_name = charset:decode("plain utf8", {})
assertx.equal("plain utf8", utf8_text, "UTF-8 is left unchanged")
assertx.equal("utf-8", utf8_name, "UTF-8 is the safe default")

local unavailable = Charset.new({ converter = false })
local missing_text, missing_name, missing_error = unavailable:decode("\214\208", {
    ["Content-Type"] = "text/plain; charset=gb18030",
})
assertx.equal(nil, missing_text, "missing converter returns no body")
assertx.equal("gb18030", missing_name, "failed charset is preserved")
assertx.equal("ENCODING_ERROR", missing_error.code, "missing conversion capability is explicit")

local failed_text, failed_name, failed_error = charset:decode("bad", {
    ["Content-Type"] = "text/plain; charset=gbk",
})
assertx.equal(nil, failed_text, "decode failure returns no body")
assertx.equal("gbk", failed_name, "decode failure preserves charset")
assertx.equal("ENCODING_ERROR", failed_error.code, "decode failure is structured")

return 14
