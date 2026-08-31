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

local description_text, description_name = charset:decode(
    '<meta name="description" content="example charset=gbk">plain utf8', {})
assertx.equal('<meta name="description" content="example charset=gbk">plain utf8', description_text,
    "description content cannot declare charset")
assertx.equal("utf-8", description_name, "invalid meta content leaves UTF-8 default")

local equiv_text, equiv_name = charset:decode(
    '<meta http-equiv="Content-Type" content="text/html; charset=GBK">\214\208', {})
assertx.equal("中", equiv_text:sub(-#"中"), "http-equiv content-type charset is honored")
assertx.equal("gbk", equiv_name, "http-equiv charset is normalized")

local false_meta_inputs = {
    '<metadata charset="gbk">\214\208',
    '<metafoo charset="gbk">\214\208',
    '<!-- <meta charset="gbk"> -->\214\208',
    '<script>document.write("<meta charset=gbk>")</script>\214\208',
    '<style>.x:after { content: "<meta charset=gbk>" }</style>\214\208',
    '<script/><meta charset=gbk>\214\208',
    '<meta "charset=gbk">\214\208',
    '<meta ??? charset=gbk>\214\208',
    '<meta charset="gbk>\214\208',
}
for _, input in ipairs(false_meta_inputs) do
    local unchanged, detected = charset:decode(input, {})
    assertx.truthy(unchanged == input, "pseudo, raw-text, comment, or malformed meta is ignored")
    assertx.equal("utf-8", detected, "ignored meta leaves UTF-8 default")
end

local mixed_text, mixed_name = charset:decode("<MeTa \n\t ChArSeT = 'GBK' />\214\208", {})
assertx.equal("中", mixed_text:sub(-#"中"), "real mixed-case meta with whitespace is recognized")
assertx.equal("gbk", mixed_name, "mixed-case meta charset is normalized")

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

return 38
