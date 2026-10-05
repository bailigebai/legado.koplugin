package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local opened,dictionary
local reader=assert(Reader.new{source_id='weread',book={id='b',name='书'},chapter={uid='c',title='章'},index=1,count=1,
    body='<p>甲乙《纽约时报》丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥。</p><p>第二段正文。</p>',
    style={page_transition='off'},callbacks={chapter_comments=function(_,range) opened=range;return true end,
        dictionary=function(_,word) dictionary=word;return true end}})
h.ui:show(reader)
local page,widgets=reader.page,reader.widgets
reader:setChapterComments({
    {range='a',position={paragraph=1,char=3,last_char=21}},
    {range='a',position={paragraph=1,char=3,last_char=21}},
    {range='b',position={paragraph=1,char=6,last_paragraph=2,last_char=3}},
    {range='invalid',position=nil},
})
local targets=reader:getCommentUnderlines()
eq(true,#targets>=3,'wrapped and cross-paragraph comments receive visible underlines')
eq(page,reader.page,'arriving comments never repaginate the visible body')
eq(widgets,reader.widgets,'arriving comments never replace its text widgets')
local found_second=false
for _,t in ipairs(targets) do
    eq(true,t.x>=reader.page.geometry.left,'underline starts within the rendered text area')
    eq(true,t.x+t.w<=reader.page.geometry.left+reader.page.geometry.content_width+1,'underline stays within text width')
    if t.range=='b' and t.y==widgets[#widgets].y then found_second=true end
end
eq(true,found_second,'cross-paragraph underline continues into its final paragraph')
local first=targets[1]
local rects={}
local bb=h:buffer(reader.dimen.w,reader.dimen.h)
local paint=bb.paintRect
function bb:paintRect(x,y,w,height,color)
    if height==1 then rects[#rects+1]={x=x,y=y,w=w} end
    return paint(self,x,y,w,height,color)
end
reader:paintTo(bb,0,0)
local dashed=false
for _,rect in ipairs(rects) do if rect.y==first.y+first.h-2 and rect.w<=4 then dashed=true end end
eq(true,dashed,'comment underline is visibly dashed to distinguish dictionary links')
local term=reader:getDictionaryTargets()[1]
reader:onTap(nil,{pos={x=term.x+term.w/2,y=term.y+term.h/2}})
eq('纽约时报',dictionary,'word text still opens its dictionary when it overlaps a passage comment')
local before=reader:getPosition()
reader:onTap(nil,{pos={x=term.x+term.w/2,y=term.y+term.h-2}})
eq('table',type(opened),'the passage underline collects overlapping comment ranges')
eq('a',opened[1],'overlapping click includes the first passage')
eq('b',opened[2],'overlapping click includes the second passage')
eq(before.char,reader:getPosition().char,'comment click never flips a page')
reader:setChapterComments({})
eq(0,#reader:getCommentUnderlines(),'removing comments invalidates cached underlines')
reader:close();bb:free()
eq(0,#reader:getCommentUnderlines(),'closed reader has no active passive targets')
local long=assert(Reader.new{source_id='weread',book={id='long',name='书'},chapter={uid='c',title='章'},index=1,count=1,
    body='<p>'..string.rep('连续正文。',200)..'</p>',style={page_transition='off'},
    callbacks={chapter_comments=function() return true end}})
h.ui:show(long)
long:setChapterComments({{range='whole',position={paragraph=1,char=1,last_char=1000}}})
local first_page=long:getCommentUnderlines()
h:drain();long:setProgressFraction(.6)
eq(true,#long:getCommentUnderlines()>0,'a long passage stays underlined on a later page')
eq(false,first_page==long:getCommentUnderlines(),'pagination invalidates old glyph rectangle cache')
long:close()
return n
