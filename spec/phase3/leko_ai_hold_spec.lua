package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local Reader=require('legado.ui.leko_reader')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local selected,sends=nil,0
local reader=assert(Reader.new{book={id='b',name='书'},chapter={uid='c',title='第一章'},
    index=1,count=1,body='<p>庄周梦蝶的故事。</p><p>'..('后续正文'):rep(500)..'</p>',
    style={page_transition='off',indent=false},
    callbacks={ai=function(_,text) selected=text;sends=sends+1;return true end}})
h.ui:show(reader)
local line
for _,item in ipairs(reader.widgets) do if item.element and item.element.type=='line' then line=item;break end end
eq(true,line~=nil,'reader renders a selectable body line')
local y=line.y+line.element.height/2
local step=reader.page.geometry.body_face.size
reader:onHold(nil,{pos={x=line.x+2.5*step,y=y}})
eq(0,sends,'long press does not submit text to AI')
eq('梦',reader:getSelectedText(),'long press selects the touched Chinese character')
reader:onHoldPan(nil,{pos={x=line.x+3.5*step,y=y}})
eq('梦蝶',reader:getSelectedText(),'drag extends the selection to the touched character')
eq(0,sends,'dragging remains a local operation')
local before=reader:getProgressFraction()
reader:onSwipe(nil,{direction='west',pos={x=line.x+3.5*step,y=y}})
eq(before,reader:getProgressFraction(),'selection swipe cannot turn the page')
local rects=reader:getSelectionRects()
eq(true,#rects>0 and rects[1].w>0,'selected text has a visible highlight rectangle')
local painted,buffer=0,h:buffer(reader.dimen.w,reader.dimen.h)
local paint=buffer.paintRect
function buffer:paintRect(x,y,w,hh,color)
    if color==require('ffi/blitbuffer').COLOR_LIGHT_GRAY then painted=painted+1 end
    return paint(self,x,y,w,hh,color)
end
reader:paintTo(buffer,0,0)
eq(true,painted>0,'production reader paint draws the selection highlight')
buffer:free()
reader:onHoldRelease(nil,{pos={x=line.x+3.5*step,y=y}})
eq(true,reader.selection_dialog~=nil,'release shows explicit selection actions')
reader.selection_dialog.buttons[1][1].callback()
eq('梦蝶',selected,'only explicit AI action submits the exact selected text')
eq(1,sends,'selection sends exactly one AI request')
eq(nil,reader.selection,'successful submission clears the selection')
reader:onHold(nil,{pos={x=line.x+3.5*step,y=y}})
reader:onHoldPan(nil,{pos={x=line.x+.5*step,y=y}})
eq('庄周梦蝶',reader:getSelectedText(),'backward dragging normalizes the selection range')
reader:onHoldRelease(nil,{pos={x=line.x+.5*step,y=y}})
reader.selection_dialog.buttons[1][2].callback()
eq(nil,reader.selection,'cancel removes the selection')
eq(1,sends,'cancel does not request AI')
reader:onHold(nil,{pos={x=line.x+1.5*step,y=y}})
reader:onHoldPan(nil,{pos={x=line.x+3.5*step,y=y}})
reader:onHoldRelease(nil,{pos={x=line.x+3.5*step,y=y}})
reader.selection_dialog.buttons[2][1].callback()
reader:onHoldPan(nil,{pos={x=line.x+.5*step,y=y}})
eq('庄周梦蝶',reader:getSelectedText(),'start handle can be dragged while the end stays fixed')
reader:onHoldRelease(nil,{pos={x=line.x+.5*step,y=y}})
local stale_dialog=reader.selection_dialog
reader:showMenu()
eq(nil,reader.selection,'opening the reading menu clears selection state')
stale_dialog.buttons[1][1].callback()
eq(1,sends,'old selection actions cannot send after the selection is cleared')
reader:_closeDialog('menu_dialog')
reader:onSwipe(nil,{direction='west'})
eq(true,reader:getProgressFraction()>before,'ordinary swipe still turns the page')
local current_line
for _,item in ipairs(reader.widgets) do if item.element.type=='line' then current_line=item;break end end
reader:onHold(nil,{pos={x=current_line.x+1,y=current_line.y+current_line.element.height/2}})
reader:onHoldRelease(nil,{pos={x=current_line.x+1,y=current_line.y+current_line.element.height/2}})
local previous_selection_actions=reader.selection_dialog
local next_options={book=reader.book,chapter={uid='next',title='第二章'},index=2,count=2,
    body='<p>第二章的正文</p>',style=reader.style,callbacks=reader.callbacks}
assert(reader:replaceChapter(next_options,assert(Reader.prepare(next_options)),function() return true end))
eq(nil,reader.selection,'chapter replacement clears the old page selection')
previous_selection_actions.buttons[1][1].callback()
eq(1,sends,'old chapter selection actions cannot submit after replacement')
local resize_line
for _,item in ipairs(reader.widgets) do if item.element.type=='line' then resize_line=item;break end end
reader:onHold(nil,{pos={x=resize_line.x+1,y=resize_line.y+resize_line.element.height/2}})
reader:onRotation()
eq(nil,reader.selection,'rotation clears selection tied to the previous screen geometry')
eq(false,reader.paused,'rotation resumes reading after cancelling selection')
reader:onHold(nil,{pos={x=resize_line.x+1,y=resize_line.y+resize_line.element.height/2}})
reader:onSuspend()
eq(nil,reader.selection,'suspend discards selection and its old dialog actions')
eq(true,reader.paused,'suspend keeps the reading session paused')
h.ui:show(reader)
reader:onResume()
eq(false,reader.paused,'resume restores the reading session without stale selection')
reader:close()
local limited=assert(Reader.new{book={id='large',name='书'},chapter={uid='large-c',title='章'},
    body='<p>'..('字'):rep(5000)..'</p>',style={page_transition='off',indent=false,body_font_size=12,
        margin_left=0,margin_right=0,line_spacing=0,show_header=false,show_footer=false},
    callbacks={ai=function() sends=sends+1 end}})
h.ui:show(limited)
local first,last
for _,item in ipairs(limited.widgets) do if item.element.type=='line' then first=first or item;last=item end end
limited:onHold(nil,{pos={x=first.x+1,y=first.y+first.element.height/2}})
limited:onHoldPan(nil,{pos={x=last.x+last.widget:getSize().w-1,y=last.y+last.element.height/2}})
eq(true,#limited:getSelectedText()>4000,'fixture selects more than the AI byte limit on one visible page')
limited:onHoldRelease(nil,{pos={x=last.x+last.widget:getSize().w-1,y=last.y+last.element.height/2}})
limited.selection_dialog.buttons[1][1].callback()
eq(1,sends,'oversized selection never reaches the AI callback')
eq(true,limited.last_error.message:find('4000',1,true)~=nil,'oversized selection explains how to shorten it')
limited:close()
eq(nil,limited.selection,'closing the reader clears selection resources')
local rejected=assert(Reader.new{book={id='retry',name='书'},chapter={uid='retry',title='第一章'},
    index=1,count=1,body='<p>保留选中的原文。</p>',style={page_transition='off',indent=false},
    callbacks={ai=function() return nil,{code='UI_ERROR',message='测试打开失败'} end}})
local selected_line
for _,item in ipairs(rejected.widgets) do if item.element and item.element.type=='line' then selected_line=item;break end end
rejected:onHold(nil,{pos={x=selected_line.x+1,y=selected_line.y+1}})
local original=rejected:getSelectedText()
rejected:onHoldRelease(nil,{pos={x=selected_line.x+1,y=selected_line.y+1}})
rejected.selection_dialog.buttons[1][1].callback()
eq(original,rejected:getSelectedText(),'failed AI dialog opening preserves the selected text for retry')
rejected:close()
return count
