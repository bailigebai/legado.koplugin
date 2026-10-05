local h=require('native_library_harness').install()
local A=require('assertions')
local Body=require('legado.ui.discussion_body')
local Screen=require('legado.ui.library_screen')
local Event=require('ui/event')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
eq('',Body.metadata({}),'unknown numbers have no placeholder')
eq('赞 0 · 回复 2',Body.metadata({likes_count=0,comments_count=2}),'real zero and reply count are independent')
local active,dirty={},{}
h.ui.setDirty=function(_,target,region) dirty[#dirty+1]={target=target,region=region} end
h.ui.close=function(_,widget) widget:handleEvent(Event:new('CloseWidget')) end
local opened=0
for _,size in ipairs{{600,800},{800,600},{758,1024}} do
    h.dimensions.w,h.dimensions.h=size[1],size[2]
    local items={}
    for i=1,6 do items[i]={row={id=tostring(i),author=string.rep('名字',30),content=string.rep('长内容',100),
        abstract='对应原句',avatar_url='https://wx.qlogo.cn/test/'..i,likes_count=i==1 and 0 or nil},callback=function() opened=opened+1 end} end
    local screen=Screen.new{title='章节讨论',compact=true,items=items,custom_body=Body.new{items=items,show_quote=true},page_count=1,
        cover_loader=function(person,cb) local r={person=person,cb=cb};active[#active+1]=r
            return {cancel=function() r.cancelled=true end} end,ui_manager=h.ui,on_back=function() end}
    h.ui:show(screen)
    eq(6,#screen.cells,'all visible cards are native focusable cells')
    eq(true,screen.cells[1].intro_widget.text:find('长内容',1,true)==1,'even landscape passage card prioritizes comment content')
    eq(true,screen.content:getSize().h<=screen.content_height,'cards fit the actual native viewport')
    eq(true,screen.cells[1].button.dimen.w<=screen.reading_body.dimen.w,'long author remains in card width')
    screen.cells[1].button.callback();eq(size[1]==600 and 1 or size[1]==800 and 2 or 3,opened,'hardware callback opens the selected thought')
    local start=#active-5
    local original_height=screen.reading_body:getSize().h
    active[start].cb('avatar.jpg')
    eq(original_height,screen.reading_body:getSize().h,'avatar arrival does not change pagination geometry')
    eq(screen,dirty[#dirty].target,'async avatar repaints the shown top-level window')
    eq('function',type(dirty[#dirty].region),'dirty rectangle is resolved after actual paint')
    local refresh= #dirty
    screen:closeForReplacement()
    eq(false,screen.alive,'replacement closes native screen')
    eq(true,active[start+5].cancelled,'all visible avatar requests are cancelled')
    active[start+1].cb('late.jpg')
    eq(refresh,#dirty,'late avatar does not repaint a closed window')
end
return n
