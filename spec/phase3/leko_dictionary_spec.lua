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
local targets=reader:getDictionaryTargets()
eq(1,#targets,'visible title phrase has a dictionary lookup underline')
eq('纽约时报',targets[1].word,'lookup excludes brackets and surrounding prose')
eq(0,calls,'creating a reader never automatically fetches every title')
local position=reader:getPosition()
local target=targets[1]
reader:onTap(nil,{pos={x=target.x+target.w/2,y=target.y+target.h/2}})
eq(1,calls,'tap dispatches exactly one dictionary action')
eq('纽约时报',word,'tap submits the complete lookup phrase')
eq(position.char,reader:getPosition().char,'lookup tap does not turn a page')
local line=reader.widgets[1]
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
eq(0,#reader:getDictionaryTargets(),'closed reader exposes no stale dictionary targets')
local ordinary=assert(Reader.new{source_id='source',book={id='s'},chapter={uid='s',title='章'},body='<p>《书名》正文</p>'})
eq(0,#ordinary:getDictionaryTargets(),'sources without dictionary action retain ordinary page taps')
ordinary:close()
local aligned=assert(Reader.new{source_id='weread',book={id='right'},chapter={uid='r',title='章'},
    body='<p align="right">在《纽约时报》。</p>',style={page_transition='off',indent=false},
    callbacks={dictionary=function(_,text) word=text;return true end}})
local aligned_line
for _,item in ipairs(aligned.widgets) do if item.element.type=='line' then aligned_line=item;break end end
eq(true,aligned_line.x>aligned.page.geometry.left,'right aligned paragraph uses its actual glyph origin')
local aligned_target=aligned:getDictionaryTargets()[1]
eq(true,aligned_target.x>=aligned_line.x,'dictionary underline follows paragraph alignment')
aligned:onTap(nil,{pos={x=aligned_target.x+1,y=aligned_target.y+1}})
eq('纽约时报',word,'right aligned lookup has a matching clickable target')
aligned:close()
return count
