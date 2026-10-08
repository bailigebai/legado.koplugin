package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local sent,sends=nil,0
local reader=assert(Reader.new{book={id='range',name='书'},chapter={uid='c',title='章'},
    body='<p>天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏。</p><p>前后段落都需要完整选中。</p><p>保留原句换行。</p>',
    style={page_transition='off',indent=false,body_font_size=32},
    callbacks={ai=function(_,text) sent=text;sends=sends+1;return true end}})
h.ui:show(reader)
local function pos(paragraph,char)
    for _,item in ipairs(reader.widgets) do
        local line=item.element
        if line.type=='line' and line.paragraph==paragraph and char>=line.start_char and char<line.next_char then
            return {x=item.x+(char-line.start_char+(line.prefix_chars or 0)+.5)*reader.page.geometry.body_face.size,
                y=item.y+line.height/2}
        end
    end
    error('fixture character is not on the page')
end
local function drag(p0,p1)
    reader:onHold(nil,{pos=p0});reader:onHoldPan(nil,{pos=p1});reader:onHoldRelease(nil,{pos=p1})
end
local function button(label)
    for _,row in ipairs(reader.selection_dialog.buttons) do
        for _,entry in ipairs(row) do if entry.text==label then return entry end end
    end
    error('missing selection action: '..label)
end
drag(pos(1,10),pos(1,3))
eq('玄黄宇宙洪荒日月',reader:getSelectedText(),'backward drag selects the original text in reading order')
button('调整起点').callback()
reader:onHoldPan(nil,{pos=pos(1,5)});reader:onHoldRelease(nil,{pos=pos(1,5)})
eq('宇宙洪荒日月',reader:getSelectedText(),'adjust start after backward drag keeps the later endpoint fixed')
button('调整终点').callback()
reader:onHoldPan(nil,{pos=pos(1,12)});reader:onHoldRelease(nil,{pos=pos(1,12)})
eq('宇宙洪荒日月盈昃',reader:getSelectedText(),'adjust end after backward drag keeps the earlier endpoint fixed')
button('调整起点').callback()
reader:onHoldPan(nil,{pos=pos(1,15)});reader:onHoldRelease(nil,{pos=pos(1,15)})
eq('昃辰宿列',reader:getSelectedText(),'moving one endpoint past the other keeps a valid ordered range')
button('调整终点').callback()
reader:onHoldPan(nil,{pos=pos(1,18)});reader:onHoldRelease(nil,{pos=pos(1,18)})
eq('昃辰宿列张寒来',reader:getSelectedText(),'endpoint labels still refer to reading order after endpoints cross')
button('取消').callback()
drag(pos(1,19),pos(3,4))
local expected='暑往秋收冬藏。\n前后段落都需要完整选中。\n保留原句'
eq(expected,reader:getSelectedText(),'forward drag across wrapped lines and paragraphs preserves source newlines')
eq(0,sends,'moving either endpoint and selecting paragraphs sends no network request')
button('AI 解释').callback()
eq(expected,sent,'explicit AI confirmation receives exactly the cross-paragraph range')
eq(1,sends,'selected text is submitted once')
drag(pos(3,4),pos(1,19))
eq(expected,reader:getSelectedText(),'backward cross-paragraph drag matches the same forward range')
button('取消').callback()
reader:close()
return n
