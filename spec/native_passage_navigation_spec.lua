package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Comments=require('legado.lib.weread_comments')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
for _,size in ipairs{{600,800},{800,600},{758,1024}} do
    h.dimensions.w,h.dimensions.h=size[1],size[2]
    local avatar_calls=0
    local c=Comments.new{client={},book_id='b',chapter_uid='7'}
    c.loaded=true
    for i=1,8 do c.rows[i]={id=tostring(i),range=tostring(i)..'-'..(i+1),abstract=string.rep('原文片段',30),
        content=string.rep('读者评论',50),author='读者'..i,avatar_url='https://wx.qlogo.cn/a/0'} end
    local resumes=0
    local p=Presenter.new{ui_manager=h.ui,avatar_loader=function() avatar_calls=avatar_calls+1 end}
    local doc={reading_state={index=1,chapters={{title='第一章'}}},resumeReading=function() resumes=resumes+1 end}
    local groups=p:showChapterComments(c,doc)
    eq(0,avatar_calls,'passage groups never download or invent reader avatars')
    eq(6,#groups.cells,'native source page contains six focusable passage cards')
    eq(true,groups.content:getSize().h<=groups.content_height,'source cards fit the actual portrait or landscape viewport')
    groups.cells[1].button:onTapSelect()
    local readers=c.panel_widget
    eq(2,#readers.cells,'native reader page contains a source header and corresponding reader card')
    eq(1,avatar_calls,'only the corresponding visible reader avatar is requested')
    eq('读者1',readers.cells[2].title_widget.text,'selected range retains its real author')
    eq(true,readers.cells[2].intro_widget.text:find('读者评论',1,true)==1,'source quote does not displace reader content')
    readers.cells[1].button:onTapSelect()
    eq('原文',c.panel_widget.options.title,'source header opens the original full passage')
    c.panel_widget:onClose();h:drain()
    c.panel_widget:onClose();h:drain()
    eq(6,#c.panel_widget.cells,'native Back restores passage groups')
    c.panel_widget:onClose();h:drain()
    eq(1,resumes,'closing the root returns to reading once')
    avatar_calls=0
    local overlapping=p:showChapterComments(c,doc,{'2-3','4-5'})
    eq(2,#overlapping.cells,'overlapping click first offers only its two verified passages')
    eq(0,avatar_calls,'overlapping source selection does not mix reader cards')
    overlapping.cells[1].button:onTapSelect()
    eq('读者2',c.panel_widget.cells[2].title_widget.text,'choosing an overlapping source displays its own reader')
    c.panel_widget:onClose();h:drain()
    eq(2,#c.panel_widget.cells,'Back preserves the overlapping source filter')
    for _,action in ipairs(c.panel_widget.options.actions) do
        if action.text=='全部原文片段' then action.callback();break end
    end
    eq(6,#c.panel_widget.cells,'explicit all passages clears the overlap filter')
    c.panel_widget:onClose();h:drain()
end
return n
