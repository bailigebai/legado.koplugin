package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local ok,T=pcall(require,'legado.lib.leko_text')
eq(true,ok,'independent chapter text module exists')
local parsed=assert(T.parse('<h2>第一章</h2><p>甲&amp;乙<br/>丙</p><p>末尾&#x1F600;。　</p>','第一章'))
eq(3,#parsed.paragraphs,'block and br boundaries survive without repeated heading')
eq('甲&乙',parsed.paragraphs[1],'entities decoded after structural conversion')
eq('末尾😀。　',parsed.paragraphs[3],'unicode numeric entities keep their code point')
local absent,err=T.parse('<p>图示</p><img src="page.png"/>','图片章')
eq(nil,absent,'image chapters do not silently discard content')
eq('UNSUPPORTED_CONTENT',err.code,'image limit is actionable')
local malformed,encoding_error=T.parse('<p>'..string.char(0xC0,0xAF)..'</p>','坏编码')
eq(nil,malformed,'malformed UTF-8 cannot enter the native text shaper')
eq('ENCODING_ERROR',encoding_error.code,'encoding failure has an explicit result')
local P=require('legado.lib.leko_paginator')
local content=string.rep('甲乙丙丁戊己庚辛壬癸',240)..'终'
local model=assert(T.parse('<p>'..content..'</p><p>　</p>','长章节'))
local book={chapters={{id='c'}},models={model}}
local style={body_font_size=27,title_font_size=34,margin_left=28,margin_right=28,show_header=true,show_footer=true,indent=false}
local pos={chapter=1,paragraph=1,char=1};local seen={};local pages=0
repeat
    local page=assert(P:makePage(book,pos,style));pages=pages+1
    for _,e in ipairs(page.elements) do if e.type=='line' then seen[#seen+1]=e.text end end
    eq(true,page.used_height<=page.geometry.content_height,'page body fits its actual measured height')
    if page.at_end then break end
    eq(true,T.positionLess(pos,page.next_position),'pagination always advances')
    pos=page.next_position
    assert(pages<100)
until false
eq(content,table.concat(seen),'long forward windows neither drop nor duplicate content')
eq(true,pages>3,'fixture exercises multiple page boundaries')
local previous_width
for _,margin in ipairs(P.MARGINS.values) do
    style.margin_left,style.margin_right=margin,margin
    local g=P:getGeometry(style)
    if previous_width then eq(true,g.content_width<previous_width,'each margin preset changes the usable width') end
    previous_width=g.content_width
end
-- The actual TextWidget remains loaded; only the native XText library is a
-- deterministic metrics substitute on Windows. This covers its indexed API.
local allocated,fail_line=0,false
package.loaded['libs/libkoreader-xtext']={new=function(text,face)
    allocated=allocated+1
    local chars=require('util').splitToChars(text)
    function chars:measure() end
    function chars:getWidth() return #self*face.size end
    function chars:makeLine(first,width,strict)
        if fail_line then error('native fitter failed') end
        assert(strict==true,'reader must request the same no-break-rule fitter as TextWidget')
        local last=math.min(#self,first+math.max(1,math.floor(width/face.size))-1)
        return {offset=first,end_offset=last,width=(last-first+1)*face.size}
    end
    function chars:free() allocated=allocated-1 end
    return chars
end}
require('ui/widget/textwidget').use_xtext=true
style.margin_left,style.margin_right=28,28
local xpage=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
eq(true,xpage.next_position.char>1,'XText indexed measurement advances the real paginator')
eq(0,allocated,'pagination releases all native measurement handles')
fail_line=true
local successful=pcall(P.makePage,P,book,{chapter=1,paragraph=1,char=1},style)
eq(false,successful,'the native fitter failure reaches the reader boundary')
eq(0,allocated,'failed pagination releases its native measurement handle')
return n
