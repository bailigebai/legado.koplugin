package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Text=require('legado.lib.leko_text')
local P=require('legado.lib.leko_paginator')
local src='../images/chapter_1_checked.png'
local assets={[src]={path='/cache/weread/book/images/chapter_1_checked.png',width=1200,height=1800}}
local html='<p>甲<img src="'..src..'">乙</p><p>后文</p>'
local model,err=Text.parse(html,'图片章',true,assets)
eq(nil,err,'verified images are accepted by immersive parser')
assert(model)
eq(4,#model.paragraphs,'inline image separates preceding and following text')
eq('甲',model.paragraphs[1],'text before image survives')
eq('',model.paragraphs[2],'image keeps the string paragraph interface')
eq('乙',model.paragraphs[3],'text after image survives')
eq(assets[src],model.images[2],'image uses the verified cache descriptor')
local lazy=Text.parse('<img data-src="original.png" src="'..src..'">','',false,assets)
eq(assets[src],lazy and lazy.images[1],'immersive parser selects real src rather than data-src')
eq(3,model.source_positions[3].first,'image block does not add original text offsets')
local marker=Text.locateQuote(model,'乙','2-3')
eq(3,marker and marker.paragraph,'inline comment still locates text after image')
eq(1,Text.positionLength(model,2),'image contributes one reading position')
eq(2,Text.positionAt(model,Text.fraction(model,{paragraph=2,char=1})).paragraph,'image position round trips through progress')
local rejected,missing=Text.parse('<img src="https://evil.test/x">','图片章',false,assets)
eq(nil,rejected,'unprepared image is never silently dropped')
eq('STORAGE_ERROR',missing and missing.code,'unprepared image has actionable cache error')
local images=assert(Text.parse('<IMG SRC="'..src..'"><img src="'..src..'">','',true,assets))
local style={body_font_size=27,title_font_size=34,margin_left=28,margin_right=28,show_header=true,show_footer=true,indent=false}
local book={chapters={{id='c'}},models={model}}
local position={chapter=1,paragraph=1,char=1};local order={};local pages=0
repeat
    local page=assert(P:makePage(book,position,style));pages=pages+1
    eq(true,page.used_height<=page.geometry.content_height,'text and images fit body area')
    for _,element in ipairs(page.elements) do
        if element.type=='line' then order[#order+1]=element.text
        elseif element.type=='image' then
            order[#order+1]='IMAGE'
            eq(assets[src].path,element.path,'paginator keeps validated file path')
            eq(true,element.width<=page.geometry.content_width,'image width stays in body')
            eq(true,math.abs(element.width/element.height-2/3)<.01,'image retains aspect ratio')
        end
    end
    if page.at_end then break end
    eq(true,Text.positionLess(position,page.next_position),'image pagination always advances')
    position=page.next_position
    assert(pages<20,'image pagination must terminate')
until false
eq('甲IMAGE乙后文',table.concat(order),'multi-page image and text order is exact')
eq(true,pages>=3,'large image occupies a page between text pages')
local first=assert(P:makePage({chapters={{id='c'}},models={images}},{chapter=1,paragraph=1,char=1},style))
eq('image',first.elements[1].type,'image-only chapter emits a page with an image')
eq(2,first.next_position.paragraph,'consecutive large images advance to the next image')
local second=assert(P:makePage({chapters={{id='c'}},models={images}},first.next_position,style))
eq(true,second.at_end,'last image terminates chapter normally')

-- Execute the unmodified host ImageWidget. Substitute only native decoding
-- and image registry; lazy decode, sizing, paint and free remain host code.
local decoded={};local fail_file;local return_nil=false;local alpha_image=false
require('util').getFileNameSuffix=function(path) return path:match('%.([^%.]+)$') end
package.loaded.cache={new=function() return {check=function() end,insert=function() error('reader images must not enter global file cache') end} end}
package.loaded['document/documentregistry']={isImageFile=function() return true end}
package.loaded['ui/renderimage']={renderImageFile=function(_,path,frames,width,height)
    if path==fail_file then if return_nil then return nil end;error('decoder failed') end
    eq(false,frames,'chapter picture decodes only a still frame')
    eq(true,width~=nil and height~=nil,'decode uses the pre-fitted page dimensions')
    local buffer=h:buffer(width,height);buffer:fill(42)
    if alpha_image then buffer.getType=function() return 2 end;buffer:fill(0) end
    decoded[#decoded+1]=buffer;return buffer
end,renderCheckerboard=function(_,width,height) return h:buffer(width,height) end,
    scaleBlitBuffer=function() error('pre-fitted image must not allocate a second scaled bitmap') end}
package.loaded['ui/widget/imagewidget']=nil
local Reader=require('legado.ui.leko_reader')
local options={book={id='b'},chapter={uid='c',title=''},index=1,count=1,body='<img src="'..src..'"><img src="'..src..'">',
    images=assets,style={page_transition='off'}}
local function reader(options)
    local view,err=Reader.new(options)
    assert(view,err and err.message or 'reader did not open')
    return view
end
local view=reader(options)
eq(1,#decoded,'only the visible image page allocates a bitmap')
h:drain()
eq(1,#decoded,'background pagination holds dimensions without bitmaps')
local image_painted=false;local blit=h.screen.bb.blitFrom
h.screen.bb.blitFrom=function(target,buffer,x,y,...)
    if buffer==decoded[1] then image_painted=buffer.pixels[0]==42 and x==view.widgets[1].x and y==view.widgets[1].y end
    return blit(target,buffer,x,y,...)
end
view:paintTo(h.screen.bb,0,0)
h.screen.bb.blitFrom=blit
eq(true,image_painted,'real host ImageWidget paints cached image pixels at the fitted position')
local old=decoded[1]
view:nextPage()
eq(1,old.freed,'turning image pages frees the previous page bitmap')
eq(2,view:getPosition().paragraph,'image page cursor is preserved')
local saved=view:getPosition()
view:close()
eq(1,decoded[2].freed,'closing reader frees the current image bitmap')
options.position=saved
view=reader(options)
eq(2,view:getPosition().paragraph,'reopening restores an empty-string image paragraph cursor')
local live=decoded[#decoded]
h.dimensions.w,h.dimensions.h=800,600
view:onSetDimensions{w=800,h=600}
eq(1,live.freed,'screen orientation change frees the previous image layout')
eq(true,view.page.elements[1].width<=view.page.geometry.content_width,'orientation change refits image width')
local before=view.page
local broken_src='../images/next_2_checked.png'
local next_assets={[src]={path=assets[src].path,width=100,height=100},[broken_src]={path='/cache/broken.png',width=100,height=100}}
local candidate={book={id='b'},chapter={uid='next',title=''},index=2,count=2,images=next_assets,
    body='<img src="'..src..'"><img src="'..broken_src..'">',style={page_transition='off'}}
local prepared=assert(Reader.prepare(candidate))
fail_file=next_assets[broken_src].path
local changed,paint_error=view:replaceChapter(candidate,prepared,function() return true end)
eq(nil,changed,'failed candidate image does not replace the reader')
eq('READER_ERROR',paint_error and paint_error.code,'decode exception becomes a reader error')
eq(before,view.page,'failed image chapter retains the readable old page')
eq(1,decoded[#decoded].freed,'failed candidate frees previously constructed image widgets')
return_nil=true
changed,paint_error=view:replaceChapter(candidate,prepared,function() return true end)
eq(nil,changed,'native decoder returning nil must not silently commit a checkerboard')
eq('READER_ERROR',paint_error and paint_error.code,'native nil decode is an actionable reader failure')
eq(before,view.page,'nil decode preserves the old readable page')
eq(1,decoded[#decoded].freed,'nil decode frees other candidate image widgets')
view:close();view:close()
alpha_image=true
require('ffi/blitbuffer').TYPE_BB8A=2
options.position=nil
local alpha_view=reader(options)
local alpha_buffer=decoded[#decoded];local blended=false
h.screen.bb.pmulalphablitFrom=function(_,buffer) if buffer==alpha_buffer then blended=true end end
alpha_view:paintTo(h.screen.bb,0,0)
eq(true,blended,'transparent PNG/GIF uses the real host premultiplied alpha branch rather than copying black transparent pixels')
alpha_view:close()
for _,buffer in ipairs(decoded) do eq(1,buffer.freed,'each decoded bitmap has exactly one owner and release') end
return n
