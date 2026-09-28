local A=require('assertions')
local Protocol=require('legado.lib.weread_protocol')
local md5=require('legado.lib.safe_functions').functions.md5
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local body='xk=SG'
eq('Hi',Protocol.decodeShards(md5(body):upper()..body),'small encoded shard decodes to chapter text')
local url_body='xC-4K'
eq(string.char(0xE0,0xA0,0xBE),Protocol.decodeShards(md5(url_body):upper()..url_body),
    'URL-safe unpadded Base64 shard decodes')
eq(nil,Protocol.decodeShards(string.rep('0',32)..body),'tampered shard is rejected')
local params=Protocol.contentParams('book1','chapter1',1000,'server-psvts')
eq('number',type(tonumber(params.ct)),'chapter request has timestamp')
eq('server-psvts',params.ps,'chapter request signs server-provided psvts')
eq(true,type(params.s)=='string' and #params.s>0,'chapter request is signed')
eq(true,Protocol.readerUrl('book1','chapter1'):find('https://weread.qq.com/web/reader/',1,true)==1,
    'chapter referer uses encoded reader URL')
return count
