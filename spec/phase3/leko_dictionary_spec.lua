package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local word,calls
calls=0
local reader=assert(Reader.new{source_id='weread',book={id='b',name='书'},chapter={uid='c',title='作者简介'},
    body='<p>在《纽约时报》畅销榜上。</p><p>'..('后文'):rep(400)..'</p>',
    style={page_transition='off',indent=false},callbacks={dictionary=function(_,text) word=text;calls=calls+1;return true end}})
h.ui:show(reader)
eq(0,calls,'creating a reader never automatically fetches every title')
local line=reader.widgets[1]
for _,item in ipairs(reader.widgets) do if item.element.type=='line' then line=item;break end end
local Selection=require('legado.lib.leko_selection')
local title_rect=Selection.rectsForRange(reader.page,reader.widgets,
    {chapter=1,paragraph=1,char=3},{chapter=1,paragraph=1,char=6})[1]
reader:onTap(nil,{pos={x=title_rect.x+title_rect.w/2,y=title_rect.y+title_rect.h/2}})
eq(0,calls,'an unmarked book title never turns into an official dictionary tap')
reader:setProgressFraction(0)
for _,item in ipairs(reader.widgets) do if item.element.type=='line' then line=item;break end end
reader:onHold(nil,{pos={x=line.x+1,y=line.y+line.element.height/2}})
reader:onHoldRelease(nil,{pos={x=line.x+1,y=line.y+line.element.height/2}})
eq(true,reader.selection_dialog~=nil,'dictionary works without an AI service')
local dictionary_button
for _,row in ipairs(reader.selection_dialog.buttons) do for _,button in ipairs(row) do if button.text=='词典说明' then dictionary_button=button end end end
eq(true,dictionary_button~=nil,'long press offers dictionary for arbitrary selected text')
dictionary_button.callback()
eq('在',word,'selection query uses exact selected character')
reader:close()
local aligned=assert(Reader.new{source_id='weread',book={id='right'},chapter={uid='r',title='章'},
    body='<p align="right">在《纽约时报》。</p>',style={page_transition='off',indent=false},
    callbacks={dictionary=function(_,text) word=text;return true end}})
local aligned_line
for _,item in ipairs(aligned.widgets) do if item.element.type=='line' then aligned_line=item;break end end
eq(true,aligned_line.x>aligned.page.geometry.left,'right aligned paragraph uses its actual glyph origin')
word=nil
local right_rect=Selection.rectsForRange(aligned.page,aligned.widgets,
    {chapter=1,paragraph=1,char=3},{chapter=1,paragraph=1,char=6})[1]
aligned:onTap(nil,{pos={x=right_rect.x+right_rect.w/2,y=right_rect.y+right_rect.h/2}})
eq(nil,word,'alignment does not invent official dictionary annotations')
aligned:close()
return count
