local A=require('assertions')
local Client=require('legado.lib.weread_client')
local Protocol=require('legado.lib.weread_protocol')
local Cleaner=require('legado.lib.content_cleaner')
local Text=require('legado.lib.leko_text')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local html='<html><body><p class="x">甲&amp;😀乙。</p></body></html>'
local original_decode=Protocol.decodeShards
Protocol.decodeShards=function() return html end
local received
local client=Client.new{auth={session=function() return {vid='a',access_token='token'} end},
    requests={execute=function(_,spec,cb) cb{status=200,body='non-text-shard'};return {cancel=function() end} end}}
client:chapterContent('b','7',function(body) received=body end)
Protocol.decodeShards=original_decode
local clean=assert(Cleaner.normalize(received))
local model=assert(Text.parse(clean,'章',true))
eq('甲&😀乙。',model.paragraphs[1],'coordinate annotations do not change visible decoded text')
local position=Text.locateQuote(model,'甲&😀乙。','25-35')
eq(true,position~=nil,'original HTML prefix, attributes, entity and UTF-16 offsets survive sanitization')
eq(1,position.char,'raw HTML start maps to the first displayed Unicode character')
eq(5,position.last_char,'UTF-16 does not shift the endpoint after an emoji')
eq(nil,Text.locateQuote(model,'甲&😀乙。','25-34'),'wrong original endpoint cannot create an underline')
eq(true,Text.locateQuote(model,'&','26-27')~=nil,'entity endpoint is its decoded glyph length rather than raw token length')
eq(true,Text.locateQuote(model,'乙','33-34')~=nil,'character after an entity and emoji retains raw source position')
local twice=assert(Text.parse(assert(Cleaner.normalize(clean)),'章',true))
eq(true,Text.locateQuote(twice,'甲&😀乙。','25-35')~=nil,'a second sanitization keeps valid internal source offsets')
local marker=received:find('data-legado-wr-offset',1,true)
eq(true,marker~=nil,'client retains source positions before removing the HTML envelope')
local Coordinates=require('legado.lib.weread_text_coordinates')
local inline=assert(Text.parse(assert(Cleaner.normalize(Coordinates.body('<body><p>甲<b>乙</b>丙。</p></body>'))),'章',true))
eq(true,Text.locateQuote(inline,'甲乙丙。','9-20')~=nil,'inline markup keeps gaps in the original HTML range')
local lines=assert(Text.parse(assert(Cleaner.normalize(Coordinates.body('<body>\r\n<p>甲乙</p>\r\n<p>丙丁</p></body>'))),'章',true))
eq(true,Text.locateQuote(lines,'乙丙','12-23')~=nil,'CRLF and block boundaries preserve a cross-paragraph raw range')
local hex=assert(Text.parse(assert(Cleaner.normalize(Coordinates.body('<p>&#x41;</p>'))),'章',true))
eq(nil,Text.locateQuote(hex,'A','3-4'),'unverified hex entity coordinates remain list-only')
local unsafe=assert(Cleaner.normalize('<span data-legado-wr-offset="999999999999" onclick="bad()">甲</span>'))
eq(false,unsafe:find('data-legado',1,true)~=nil,'oversized internal offsets are stripped')
eq(false,unsafe:find('onclick',1,true)~=nil,'coordinate carrier cannot retain event handlers')
local large='<p>'..string.rep('a',180)..'</p>'
local large_body=string.rep(large,19000)
local bounded=Coordinates.body('<html><body>'..large_body..'</body></html>')
eq(true,#bounded<=4*1024*1024,'optional annotations cannot exceed the chapter cache payload limit')
eq(large_body,bounded,'byte-limit fallback retains the entire readable body')
local escaped_body=string.rep('<p>'..string.rep('a',150)..string.rep('>',7)..'</p>',19000)
local escaped=assert(Cleaner.normalize(Coordinates.body('<html><body>'..escaped_body..'</body></html>')))
eq(true,#escaped<=4*1024*1024,'annotation budget includes sanitizer expansion of legal bare greater-than text')
local old=assert(Text.parse('<p>哨兵</p>','章',true))
eq(nil,Text.locateQuote(old,'哨兵','1-3'),'unannotated old chapters never use guessed stripped-text offsets')
local exhausted=Coordinates.body('<p>哨兵</p>'..string.rep('<p>甲</p>',20001))
local exhausted_model=assert(Text.parse(exhausted,'章',true))
eq(nil,Text.locateQuote(exhausted_model,'哨兵','1-3'),'run-limit fallback does not invent a source coordinate')
local find,scans=string.find,0
string.find=function(value,pattern,...)
    if pattern=='[\r\n]' then scans=scans+1 end
    return find(value,pattern,...)
end
local fast=Coordinates.body('<p>'..string.rep('a&amp;',1000)..string.rep('a',512*1024)..'</p>')
string.find=find
eq(true,scans<=1,'a long no-newline paragraph scans for the next newline only once')
eq(true,fast:find('data-legado-wr-offset',1,true)~=nil,'linear entity scan keeps source annotations')
return n
