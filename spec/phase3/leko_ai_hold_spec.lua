package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local selected
local reader=assert(Reader.new{book={id='b',name='书'},chapter={uid='c',title='第一章'},
    index=1,count=1,body='<p>庄周梦蝶的故事。</p>',style={page_transition='off'},
    callbacks={ai=function(_,text) selected=text;return true end}})
h.ui:show(reader)
local top=reader.page.geometry.body_top+reader.page.geometry.header_height
local touched
for _,element in ipairs(reader.page.elements) do
    if element.type=='gap' then top=top+element.height
    else
        top=top+(element.top_gap or 0)
        if element.type=='line' and not touched then touched=top+math.floor(element.height/2) end
        top=top+element.height+(element.bottom_gap or 0)
    end
end
eq(true,touched~=nil,'reader renders a selectable body line')
reader:onHold(nil,{pos={x=100,y=touched}})
eq(true,type(selected)=='string' and selected:find('庄周梦蝶',1,true)~=nil,
    'long press passes the selected line to AI')
eq(nil,reader.menu_dialog,'AI selection does not open the generic reader menu')
reader:close()
return count
