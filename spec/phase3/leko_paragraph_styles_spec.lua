package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(expected,actual,message) n=n+1;A.equal(expected,actual,message) end
local T=require('legado.lib.leko_text')
local P=require('legado.lib.leko_paginator')
local Cleaner=require('legado.lib.content_cleaner')
local assets={['page.png']={path='page.png',width=80,height=240}}
local body='<h1>章名</h1><h5>作者</h5><p align="center">甲<strong>重点</strong>乙</p>'
    ..'<blockquote><p>书信</p></blockquote><p><em>Latin emphasis</em></p>'
    ..'<p><strong>整段粗体</strong></p><img src="page.png">'
    ..'<p style="font-size:0.9em;text-align:right;text-indent:0">😀éﬁ中文</p>'
local model=assert(T.parse(body,'章名',true,assets))
eq('table',type(model.paragraph_styles),'semantic paragraph styles survive parsing')
eq(5,model.paragraph_styles[1].heading_level,'h5 retains its heading level after duplicate chapter title removal')
eq(1.1,model.paragraph_styles[1].font_scale,'a secondary heading is larger than body')
eq(true,model.paragraph_styles[1].bold,'heading keeps its semantic bold')
eq('center',model.paragraph_styles[2].alignment,'legacy paragraph center alignment is retained')
eq(nil,model.paragraph_styles[2].bold,'partial strong does not bold the whole paragraph')
eq(true,model.paragraph_styles[3].quote,'blockquote semantics inherit into its paragraph')
eq(false,model.paragraph_styles[3].indent,'quote blocks do not gain body first-line indentation')
eq(true,model.paragraph_styles[4].italic,'whole paragraph em retains italic semantics')
eq(true,model.paragraph_styles[5].bold,'whole paragraph strong retains bold semantics')
eq(nil,model.paragraph_styles[6],'image block does not acquire a text style')
eq('right',model.paragraph_styles[7].alignment,'inline right alignment is retained')
eq(.9,model.paragraph_styles[7].font_scale,'safe source paragraph font size is retained')
eq(false,model.paragraph_styles[7].indent,'source zero text indent is retained')
local unstyled=body:gsub('%s+align="[^"]*"',''):gsub('%s+style="[^"]*"','')
    :gsub('</?strong>',''):gsub('</?em>','')
local reference=assert(T.parse(unstyled,'章名',true,assets))
eq(#reference.paragraphs,#model.paragraphs,'style metadata does not create paragraphs')
for index,text in ipairs(model.paragraphs) do
    eq(reference.paragraphs[index],text,'metadata never changes decoded source characters')
    local source,original=model.source_positions[index],reference.source_positions[index]
    if source then
        eq(original.first,source.first,'source start remains unchanged')
        eq(original.last,source.last,'source end remains unchanged')
    else eq(false,source,'image source coordinate stays false') end
end
eq(require('legado.lib.identity').hash(body),model.checksum,'checksum remains the hash of the exact input body')
eq(assets['page.png'],model.images[6],'image identity survives metadata and title removal')
eq(T.fraction(reference,{paragraph=7,char=3}),T.fraction(model,{paragraph=7,char=3}),'reading fractions remain unchanged')
local annotated=assert(T.parse(require('legado.lib.weread_text_coordinates').body(body),'章名',true,assets))
local source_offset=T.utf8Length(body:match('^(.-)ﬁ'))+1 -- The preceding emoji occupies two UTF-16 units.
eq(4,assert(T.locateQuote(annotated,'ﬁ',source_offset..'-'..(source_offset+1))).char,'combining characters do not shift quote ranges')

local cleaned=assert(Cleaner.normalize('<h5 style="font-size:1.1em;text-align:right;color:red;background:url(x);font-family:Remote">作者</h5>'
    ..'<p align="center" onclick="bad()">居中</p><p style="text-align:center">   </p>'))
local cleaned_model=assert(T.parse(cleaned,'different'))
eq(2,#cleaned_model.paragraphs,'styled empty paragraphs remain empty')
eq('right',cleaned_model.paragraph_styles[1].alignment,'cleaner passes safe paragraph alignment')
eq(1.1,cleaned_model.paragraph_styles[1].font_scale,'cleaner passes safe paragraph size')
eq('center',cleaned_model.paragraph_styles[2].alignment,'cleaner passes legacy alignment')
eq(nil,cleaned:find('onclick',1,true),'cleaner still removes event handlers')
eq(nil,cleaned:find('url(',1,true),'cleaner does not pass remote style resources')
eq(nil,cleaned:find('font-family',1,true),'unimplemented font families are not silently accepted')
local invalid=assert(T.parse('<h5 style="font-size:999em;text-align:garbage">标题</h5><p>普通</p>','different'))
eq(1.1,invalid.paragraph_styles[1].font_scale,'invalid source size falls back to heading semantics')
eq(nil,invalid.paragraph_styles[2],'body after a heading stays ordinary')
local mixed=assert(T.parse('<p><strong>甲</strong>乙</p><p>甲<em>乙</em></p><h5><em>标题</em></h5>','different'))
eq(nil,mixed.paragraph_styles[1],'mixed strong is not rendered as whole-block bold')
eq(nil,mixed.paragraph_styles[2],'mixed em is not rendered as whole-block italic')
eq(5,mixed.paragraph_styles[3].heading_level,'nested emphasis retains the outer heading')
eq(true,mixed.paragraph_styles[3].italic,'whole heading emphasis is preserved')
for level=1,6 do
    local heading=assert(T.parse('<h'..level..'>标题</h'..level..'><p>正文</p>','different'))
    eq(level,heading.paragraph_styles[1].heading_level,'all six heading levels retain their semantics')
    eq(true,heading.paragraph_styles[1].bold,'each heading level has bold emphasis')
    eq(false,heading.paragraph_styles[1].indent,'each heading disables artificial body indentation')
end
local plain_body='<p>甲乙</p><p>丙丁</p>'
local plain=assert(T.parse(plain_body,'different',true))
eq(nil,next(plain.paragraph_styles),'ordinary p blocks retain the ordinary style')
eq(2,plain.source_positions[1].first,'ordinary p opening keeps its established source newline')
eq(3,plain.source_positions[1].last,'ordinary p last source position is unchanged')
eq(6,plain.source_positions[2].first,'ordinary paragraph boundaries remain unchanged')
local with_css=assert(T.parse('<style>p{font-size:3em} h5{font-size:2em}</style>'..plain_body,'different',true))
eq(nil,next(with_css.paragraph_styles),'head CSS is stripped without pretending external CSS support')
for index,text in ipairs(plain.paragraphs) do
    eq(text,with_css.paragraphs[index],'head CSS does not change paragraphs')
    eq(plain.source_positions[index].first,with_css.source_positions[index].first,'head CSS does not shift source coordinates')
end
local only_images=assert(T.parse('<img src="page.png"><img src="page.png">','images',true,assets))
eq(2,#only_images.paragraphs,'pure images preserve their position blocks')
eq(nil,next(only_images.paragraph_styles),'pure images do not enter semantic text styling')
eq(false,only_images.source_positions[1],'pure first image keeps false source coordinates')
eq(false,only_images.source_positions[2],'pure second image keeps false source coordinates')
local around=assert(T.parse('<p><strong>前<img src="page.png">后</strong></p>','images',true,assets))
local around_plain=assert(T.parse('<p>前<img src="page.png">后</p>','images',true,assets))
eq(true,around.paragraph_styles[1].bold,'whole strong before an image is retained')
eq(true,around.paragraph_styles[3].bold,'whole strong after an image is retained')
eq(around_plain.source_positions[3].first,around.source_positions[3].first,'inline images do not shift the following source text')
local ambiguous=assert(T.parse('<p>&<strong>amp;</strong></p>','different',true))
eq('&',ambiguous.paragraphs[1],'legacy malformed cross-tag entity text is retained')
eq(nil,next(ambiguous.paragraph_styles),'ambiguous cross-tag entities discard styling rather than shift coordinates')
local deep=assert(T.parse(string.rep('<strong>',65)..'甲'..string.rep('</strong>',65),'different',true))
eq('甲',deep.paragraphs[1],'deep markup still displays the original text')
eq(nil,next(deep.paragraph_styles),'deep markup stays within the metadata stack bound')
local cleaned_reference=assert(T.parse(assert(Cleaner.normalize(unstyled)),'章名',true,assets))
local cleaned_styled=assert(T.parse(assert(Cleaner.normalize(body)),'章名',true,assets))
for index,text in ipairs(cleaned_styled.paragraphs) do
    eq(cleaned_reference.paragraphs[index],text,'cleaner presentation attributes do not alter plain text')
    if cleaned_styled.source_positions[index] then
        eq(cleaned_reference.source_positions[index].first,cleaned_styled.source_positions[index].first,'cleaner style retention does not shift word ranges')
    end
end

local style={body_font_size=27,title_font_size=34,margin_left=28,margin_right=28,
    show_header=true,show_footer=true,indent=true}
local book={chapters={{id='styled'}},models={model}}
local page=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
local lines={}
for _,element in ipairs(page.elements) do
    if element.type=='line' then lines[element.paragraph]=lines[element.paragraph] or element end
end
eq(30,lines[1].face.size,'heading font size is used for pagination')
eq(true,lines[1].bold,'heading carries bold to the renderer')
eq(0,lines[1].prefix_chars,'heading has no body indent prefix')
eq('center',lines[2].alignment,'center alignment reaches the line renderer')
eq(0,lines[2].prefix_chars,'centered text has no artificial body indent')
eq(true,lines[3].offset_x>0,'quotes have a visible horizontal inset')
eq(true,lines[3].width<page.geometry.content_width,'quote measurement uses its reduced width')
eq(true,lines[4].italic,'emphasis carries italic semantics to the renderer')
eq(true,lines[5].bold,'whole-block strong reaches the renderer')

-- Many pages with differently sized blocks must advance without losing source text.
local long=assert(T.parse('<h5>'..string.rep('标题',100)..'</h5><p>'..string.rep('正文',1100)
    ..'</p><img src="page.png"><p style="font-size:1.4em;text-align:right">尾声</p>','long',true,assets))
book.models[1]=long
local position={chapter=1,paragraph=1,char=1};local seen,images,pages={},0,0
repeat
    page=assert(P:makePage(book,position,style));pages=pages+1
    eq(true,page.used_height<=page.geometry.content_height,'styled lines fit the actual page height')
    for _,element in ipairs(page.elements) do
        if element.type=='line' then
            seen[element.paragraph]=(seen[element.paragraph] or '')..T.utf8Window(element.text,(element.prefix_chars or 0)+1,10000)
        elseif element.type=='image' then images=images+1 end
    end
    if page.at_end then break end
    eq(true,T.positionLess(position,page.next_position),'styled page boundaries always advance')
    position=page.next_position
    assert(pages<100)
until false
for index,text in pairs(seen) do eq(long.paragraphs[index],text,'styling neither drops nor repeats text across pages') end
eq(1,images,'image block remains in the same source order and is emitted once')
local original_height=h.dimensions.h
h.dimensions.h=120
book.models[1]=assert(T.parse('<h5 style="font-size:3em">短屏标题</h5><p>正文</p>','short',true))
local short=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
eq(true,short.used_height<=short.geometry.content_height,'oversize first styled row fits a short screen')
eq(true,short.at_end or T.positionLess(short.start_position,short.next_position),'a styled first row never emits a non-advancing title-only page')
h.dimensions.h=original_height
local Font=require('ui/font')
local original_get_face=Font.getFace
local reject_italic=false
Font.getFace=function(self,name,size,index)
    if reject_italic and name=='NotoSans-Italic.ttf' then error('italic companion missing') end
    local face=original_get_face(self,name,size,index)
    face.realname=name=='cfont' and 'NotoSans-Regular.ttf' or name
    return face
end
book.models[1]=assert(T.parse('<p><em>Latin emphasis</em></p>','emphasis',true))
local function first_line(styled_page)
    for _,element in ipairs(styled_page.elements) do if element.type=='line' then return element end end
end
page=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
eq('NotoSans-Italic.ttf',first_line(page).face.realname,'whole em selects a known same-family italic face')
reject_italic=true
page=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
eq('NotoSans-Regular.ttf',first_line(page).face.realname,'missing italic companion preserves a readable body face')
reject_italic=false;style.body_font='Custom-Regular.ttf'
page=assert(P:makePage(book,{chapter=1,paragraph=1,char=1},style))
eq('Custom-Regular.ttf',first_line(page).face.realname,'unknown custom font is not replaced by an unrelated italic font')
style.body_font=nil;Font.getFace=original_get_face
return n
