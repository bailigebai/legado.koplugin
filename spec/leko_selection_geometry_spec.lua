package.path='spec/phase3/?.lua;'..package.path
require('leko_reader_harness').install()
local A=require('assertions')
local Selection=require('legado.lib.leko_selection')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local page={geometry={content_width=100}}
local function item(text,shaping,prefix,start)
    return {x=10,y=20,element={type='line',text=text,paragraph=1,start_char=start or 1,
        next_char=(start or 1)+require('legado.lib.leko_text').utf8Length(text)-(prefix or 0),
        prefix_chars=prefix or 0,height=24},
        widget={face={size=12},_xtext={shapeLine=function() return shaping end}}}
end
local shaped=item('A中i',{{text_index=1,x_advance=6},{text_index=2,x_advance=18},{text_index=3,x_advance=4}})
local selection=assert(Selection.new(page,{shaped},{x=17,y=25}))
eq('中',selection:text(),'unequal shaped glyph widths determine the touched character')
selection:move{x=37,y=25}
eq('中i',selection:text(),'dragging uses shaped glyph advances instead of an average character width')
eq(16,selection:rects()[1].x,'highlight starts at the selected glyph boundary')
eq(22,selection:rects()[1].w,'highlight covers exactly the selected glyph advances')
local ligature=item('ffi',{{text_index=1,cluster_len=3,x_advance=24}})
local linked=assert(Selection.new(page,{ligature},{x=19,y=25}))
eq('f',linked:text(),'ligature cluster maps to the touched logical character')
eq(2,linked.anchor.char,'ligature cluster divides its original characters')
linked:move{x=31,y=25}
eq('fi',linked:text(),'ligature selection can extend to its last original character')
local rtl=item('אב',{{text_index=1,cluster_len=2,is_rtl=true,x_advance=20}})
local reversed=assert(Selection.new(page,{rtl},{x=15,y=25}))
eq('ב',reversed:text(),'right-to-left clusters use visual glyph coordinates')
local indented=item('　　庄周',{{text_index=1,x_advance=12},{text_index=2,x_advance=12},
    {text_index=3,x_advance=12},{text_index=4,x_advance=12}},2,3)
local offset=assert(Selection.new(page,{indented},{x=40,y=25}))
eq('庄',offset:text(),'layout indentation is excluded from selected source characters')
eq(3,offset.anchor.char,'selection keeps the original paragraph character position')
offset:move{x=10000,y=10000}
eq('庄周',offset:text(),'drag outside the page clamps to its last rendered character')
local wrap_first=item('foo',{{text_index=1,x_advance=10},{text_index=2,x_advance=10},{text_index=3,x_advance=10}})
wrap_first.element.next_char=5
local wrap_last=item('bar',{{text_index=1,x_advance=10},{text_index=2,x_advance=10},{text_index=3,x_advance=10}},0,5)
wrap_last.y=50
local wrap=assert(Selection.new(page,{wrap_first,wrap_last},{x=11,y=25},{paragraphs={'foo bar'}}))
wrap:move{x=39,y=55}
eq('foo bar',wrap:text(),'selection preserves source spaces that line wrapping does not paint')
return count
