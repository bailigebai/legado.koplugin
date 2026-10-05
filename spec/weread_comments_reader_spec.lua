package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local opened
local reader=assert(Reader.new{source_id='weread',book={id='b',name='微信书'},
    chapter={uid='c',title='第一章'},index=1,count=1,body='<p>庄周梦蝶的故事。</p>',
    style={page_transition='off'},callbacks={chapter_comments=function(_,range) opened=range;return true end}})
h.ui:show(reader)
reader:setChapterComments({{range='0-4',position={paragraph=1,char=1,last_char=4}},
    {range='10-14',abstract='错误位置',position=nil}})
local targets=reader:getCommentTargets()
eq(1,#targets,'only a verified visible quote receives a body marker')
eq(true,targets[1].w>=36,'comment marker has an accessible touch width')
eq(true,targets[1].x>=reader.page.geometry.left+reader.page.geometry.content_width,
    'comment marker stays in its reserved gutter without hiding body text')
local position=reader:getPosition()
reader:onTap(nil,{pos={x=targets[1].x+targets[1].w/2,y=targets[1].y+targets[1].h/2}})
eq('0-4',opened,'body marker opens comments for that exact range')
eq(position.char,reader:getPosition().char,'comment tap does not turn the page')
reader:showMenu()
local found
for _,row in ipairs(reader.menu_dialog.buttons) do for _,button in ipairs(row) do
    if button.text=='随文评论' then found=button end
end end
eq(true,found~=nil,'WeRead reading menu exposes the chapter comments action')
found.callback()
eq(nil,opened,'chapter comments menu opens all ranges')
reader:close()
return count
