package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local ok,R=pcall(require,'legado.ui.leko_reader');eq(true,ok,'independent reader exists without ReaderUI')
local changes,chapters,actions={}, {}, {};local closed,cancelled=0,0
local reader=assert(R.new{book={id='book',name='测试小说'},chapter={uid='c2',title='第二章'},index=2,count=3,
    body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',150)..'</p>',style={page_transition='off'},
    callbacks={page_changed=function(_,page,total) changes[#changes+1]={page,total} end,
        chapter=function(_,index,options) chapters[#chapters+1]={index=index,options=options};return {cancel=function() cancelled=cancelled+1 end} end,
        toc=function() actions[#actions+1]='toc' end,receipt=function() actions[#actions+1]='receipt' end,
        toggle_reader=function() actions[#actions+1]='toggle' end,close=function() closed=closed+1 end}})
h.ui:show(reader)
reader.background=function(_,bb) bb:fill(77) end;reader:refreshBackground()
reader:paintTo(h.screen.bb,0,0)
eq(true,(h.screen.bb.masks or 0)>0,'chapter title uses an alpha mask and does not paint a white background box')
local label_sizes={};local paint_label=reader._paintLabel
reader._paintLabel=function(self,bb,text,x,y,width,align,size)
    label_sizes[#label_sizes+1]=size;return paint_label(self,bb,text,x,y,width,align,size)
end
reader:paintTo(h.screen.bb,0,0)
eq(11,label_sizes[1],'independent header defaults to 11 points')
eq(11,label_sizes[4],'independent footer defaults to 11 points')
reader.settings={get=function(_,key) return ({reader_header_font_size=14,reader_footer_font_size=15})[key] end}
reader:refreshAppearance();label_sizes={};reader:paintTo(h.screen.bb,0,0)
eq(14,label_sizes[1],'independent header honors the existing header size setting')
eq(15,label_sizes[4],'independent footer honors its separate size setting')
reader.settings=nil;reader._paintLabel=nil;reader:refreshAppearance()
eq(nil,reader:getReadingContext().chapter_pages,'unknown totals remain unknown before background pagination')
eq(nil,changes[1][2],'unknown total is not sent as zero or one')
local original=reader:getPosition()
reader:nextPage();eq(true,reader:getProgressFraction()>0,'page-forward changes actual text position')
reader:previousPage();eq(original.char,reader:getPosition().char,'backward restores the exact initial cursor')
reader:previousPage();eq(1,chapters[#chapters].index,'first page requests previous chapter')
eq(true,chapters[#chapters].options.last_page,'previous chapter requests its last page')
h:drain()
local context=reader:getReadingContext();eq(true,context.chapter_pages>1,'background pagination supplies real chapter total')
reader:setProgressFraction(1);reader:nextPage();eq(3,chapters[#chapters].index,'last page requests next chapter')
reader:runAction('toc');reader:resumeReading();reader:runAction('receipt');reader:resumeReading();reader:runAction('toggle_reader')
eq('toggle',actions[3],'mode toggle delegates without destroying the old page')
eq(false,reader.closed,'toggle waits for host replacement success')
reader:resumeReading();reader:showMenu()
local menu=reader.menu_dialog
eq(true,menu~=nil and h.shown==menu,'native ButtonDialog is actually shown')
local toggle
for _,row in ipairs(menu.buttons) do for _,button in ipairs(row) do if button.text=='关闭无感阅读' then toggle=button end end end
assert(toggle,'mode toggle is reachable from the visible native menu');toggle.callback()
eq('toggle',actions[4],'visible toggle button invokes host mode switch')
reader:resumeReading();reader:showLayoutMenu()
eq(true,reader.layout_dialog~=nil,'native layout controls can be rendered')
local layout_font
for _,row in ipairs(reader.layout_dialog.buttons or {}) do
    for _,button in ipairs(row) do if button.text=='字体' then layout_font=button end end
end
eq(true,layout_font~=nil,'reading settings uses the compact font label from the reference layout')
reader:_closeDialog('layout_dialog');reader:resumeReading()
local before=reader:getPosition();local changed,why=reader:applyStyle{body_font_size=0}
eq(nil,changed,'invalid layout change fails')
eq(before.char,reader:getPosition().char,'failed style change keeps old page')
local stored=0
reader.callbacks.style_changed=function() stored=stored+1;return nil,{code='STORAGE_ERROR'} end
local changed,err=reader:applyStyle{body_font_size=32}
eq(nil,changed,'failed persistence does not apply the requested layout')
eq(27,reader:getReaderSettings().body_font_size,'old style survives save rejection')
eq(1,stored,'one user style choice has one persistence request')
reader.callbacks.style_changed=nil
assert(reader:applyStyle{body_font='example.ttc',body_font_index=2,title_font='example.ttc',title_font_index=2})
assert(reader:applyStyle{body_font='cfont',title_font='cfont'})
eq(nil,reader:getReaderSettings().body_font_index,'selecting system font clears the previous TTC face index')
reader:setProgressFraction(.3);h:drain()
local current=reader:getProgressFraction();reader:previousPage()
eq(true,reader:getProgressFraction()<current,'back from a restored mid-page cursor reaches a canonical boundary')
reader:animateEntry('forward',true);h:drain()
h.dimensions.w,h.dimensions.h=800,600;reader:onSetDimensions{w=800,h=600}
eq(800,reader.page.geometry.screen_width,'rotation reflows against the actual host dimensions')
local final_fraction=reader:getProgressFraction()
reader:close();eq(1,closed,'close callback runs once');reader:close();eq(1,closed,'close is idempotent')
eq(final_fraction,reader:getProgressFraction(),'closed proxy retains its last reading position for host finalization')
eq(true,cancelled>=1,'outstanding chapter handles are cancelled')
eq(0,#h.tasks,'close cancels page-count and clock jobs')
eq(nil,package.loaded['apps/reader/readerui'],'no ReaderUI was loaded')
local late_cancel=0
local other=assert(R.new{book={id='b'},chapter={uid='x',title='短章'},body='<p>正文</p>',index=1,count=2,
    callbacks={chapter=function(view) view:close();return {cancel=function() late_cancel=late_cancel+1 end} end}})
other:nextPage();eq(1,late_cancel,'a handle returned after synchronous replacement is immediately cancelled')
local protected=assert(R.new{book={id='b'},chapter={uid='x',title='短章'},body='<p>正文</p>',
    callbacks={flush=function() return nil,{code='STORAGE_ERROR'} end}})
local refused=protected:close();eq(nil,refused,'close can refuse data loss after a failed save')
eq(false,protected.closed,'failed save leaves current page available')
protected.callbacks.flush=nil;protected:close()
local restore_body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',150)..'</p>'
local restore_checksum=require('legado.lib.identity').hash(restore_body)
for _,invalid in ipairs{{paragraph=0/0,char=1},{paragraph=math.huge,char=1},{paragraph=1.5,char=1},
    {paragraph=0,char=1},{paragraph=2,char=1},{paragraph=1,char=0/0},{paragraph=1,char=math.huge},
    {paragraph=1,char=1.5},{paragraph=1,char=0},{paragraph=1,char=2000}} do
    invalid.chapter_uid='restore';invalid.content_checksum=restore_checksum
    local restored=R.new{book={id='b'},chapter={uid='restore',title='恢复章'},body=restore_body,position=invalid,fraction=.4}
    eq(true,restored~=nil,'invalid persisted cursor falls back to the saved fraction')
    eq(.4,restored:getProgressFraction(),'invalid coordinates never produce an empty or wrong page')
    restored:close()
end
local restored=assert(R.new{book={id='b'},chapter={uid='restore',title='恢复章'},body=restore_body,fraction=.4,
    position={chapter_uid='restore',content_checksum=restore_checksum,paragraph=1,char=21}})
eq(21,restored:getPosition().char,'valid exact cursor takes precedence over the approximate fraction')
restored:close()

-- Measure the unmodified KOReader TextWidget with a high-DPI face whose glyph
-- height exceeds the point size; fixed offsets cannot keep these bands apart.
local Font=require('ui/font');local TextWidget=require('ui/widget/textwidget')
local original_face,original_scale=Font.getFace,h.screen.scaleBySize
local progress_faces=0
h.dimensions.w,h.dimensions.h=1200,1600
h.screen.scaleBySize=function(_,size) return size*2 end
Font.getFace=function(self,name,size,...)
    if name=='cfont' and size==22 then progress_faces=progress_faces+1 end
    local face=original_face(self,name,(size or 20)*2,...);face.orig_size=size or 20
    face.ftsize.getHeightAndAscender=function() return face.size+25,math.floor(face.size*.75)+13 end
    return face
end
local chrome_settings={reader_header_font_size=18,reader_footer_font_size=18,progress_bar_font_size=22,progress_bar_height=16}
local high=assert(R.new{book={id='high',name='高分屏'},chapter={uid='high1',title='第一章'},body=restore_body,
    style={page_transition='off'},settings={get=function(_,key) return chrome_settings[key] end}})
h.ui:show(high);h:drain();high:_startPagination();h:drain()
local pagination_progress_faces=progress_faces
local labels,bars={},{};local collecting=false
local text_paint=TextWidget.paintTo;local high_paint_label=high._paintLabel
TextWidget.paintTo=function(self,bb,x,y)
    if collecting then local size=self:getSize();labels[#labels+1]={x=x,y=y,w=size.w,h=size.h} end
    return text_paint(self,bb,x,y)
end
high._paintLabel=function(self,...)
    collecting=true;high_paint_label(self,...);collecting=false
end
local bb=h:buffer(1200,1600);local rect=bb.paintRect
bb.paintRect=function(self,x,y,w,height,color)
    if color==require('ffi/blitbuffer').COLOR_LIGHT_GRAY then bars[#bars+1]={x=x,y=y,w=w,h=height} end
    return rect(self,x,y,w,height,color)
end
high:paintTo(bb,0,0)
eq(6,#labels,'three header labels, two footer labels and one progress detail are painted')
local geometry=high.page.geometry;local body_start=geometry.body_top+geometry.header_height
for i=1,3 do
    eq(true,labels[i].y>=h.screen:scaleBySize(4),'header retains scaled outer padding')
    eq(true,labels[i].y+labels[i].h<=body_start,'real header glyphs stay above the body')
end
local footer_start=high.dimen.h-geometry.footer_height
for _,item in ipairs(high.widgets) do
    eq(true,item.y+item.widget:getSize().h<=footer_start,'body widgets do not enter the footer')
end
for i=4,5 do
    eq(true,labels[i].y>=footer_start,'footer labels start within the reserved footer')
    eq(true,labels[i].y+labels[i].h<labels[6].y,'chapter footer and progress details have a separate row')
end
eq(1,#bars,'one progress track is drawn')
eq(true,labels[6].y+labels[6].h<bars[1].y,'22 point progress glyphs clear the bar at minimum block height')
eq(true,bars[1].y+bars[1].h<=high.dimen.h-h.screen:scaleBySize(4),'progress bar retains scaled bottom padding')
eq(16,bars[1].x,'horizontal chrome padding scales with the screen')
eq(4,bars[1].h,'progress bar thickness scales with the screen')
eq(1,pagination_progress_faces,'progress glyph height is measured once across initial and repeated background pagination')
local dirty_region;local original_dirty=h.ui.setDirty
h.ui.setDirty=function(self,widget,kind,region) dirty_region=region;return original_dirty(self,widget,kind,region) end
h.ui:unschedule(high.clock_job);high.clock_job()
eq(body_start,dirty_region.h,'clock dirties the complete real header band')
high:close();h.ui.setDirty=original_dirty;TextWidget.paintTo=text_paint
Font.getFace=original_face;h.screen.scaleBySize=original_scale;h.dimensions.w,h.dimensions.h=600,800

local resumed=0
local visible=assert(R.new{book={id='visible'},chapter={uid='visible1',title='可见性'},body=restore_body,
    style={page_transition='off'},callbacks={resume=function() resumed=resumed+1 end}})
h.ui:show(visible)
for _,pos in ipairs{{x=1,y=1},{x=599,y=95},{x=300,y=400}} do
    local cursor=visible:getPosition().char
    visible:onTap(nil,{pos=pos})
    eq(true,visible.menu_dialog~=nil,'top left, top right and center taps all open the menu')
    eq(cursor,visible:getPosition().char,'menu entry never turns a page')
    visible:_closeDialog('menu_dialog');h.shown=visible;visible:resumeReading()
end
local Device=require('device');local original_frontlight=Device.hasFrontlight
local original_broadcast=h.ui.broadcastEvent;local overlay={}
Device.hasFrontlight=function() return true end
h.ui.broadcastEvent=function() h.shown=overlay end
visible:showLayoutMenu();local brightness
for _,row in ipairs(visible.layout_dialog.buttons) do for _,button in ipairs(row) do
    if button.text=='屏幕亮度' then brightness=button end
end end
assert(brightness);brightness.callback()
eq(overlay,h.shown,'real brightness button opens the native overlay')
eq(true,visible.paused,'native brightness overlay keeps reading paused')
local resumes_before=resumed
visible:onResume();visible:onReadingResumed()
eq(true,visible.paused,'resume broadcasts do not resume beneath an overlay')
eq(resumes_before,resumed,'covered resume broadcasts never reach the session clock')
h.shown=visible;visible:onTap(nil,{pos={x=590,y=500}})
eq(false,visible.paused,'first reading tap after native overlay closes resumes timing')
eq(resumes_before+1,resumed,'tap restores the session clock once')
visible:pauseReading();h.shown=overlay;visible:onPageForward()
eq(true,visible.paused,'page keys beneath an overlay cannot resume timing')
h.shown=visible;visible:onPageBackward()
eq(false,visible.paused,'first visible page key restores timing')
visible:pauseReading();visible:onResume()
eq(false,visible.paused,'device resume restores timing when the reading page is visible')
visible:pauseReading();visible:onReadingResumed()
eq(false,visible.paused,'reading resume restores timing when the page is visible')
visible:close();Device.hasFrontlight=original_frontlight;h.ui.broadcastEvent=original_broadcast
return n
