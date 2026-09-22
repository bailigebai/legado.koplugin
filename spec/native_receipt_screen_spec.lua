local state=require('native_library_harness').install()
local A=require('assertions')
local count=0
local function eq(want,got,why) count=count+1;A.equal(want,got,why) end
local function check(value,why) count=count+1;A.truthy(value,why) end
local available,Receipt=pcall(require,'legado.ui.receipt_screen')
check(available,'receipt has an independent native floating widget')
local geom,event,input_container=require('ui/geometry'),require('ui/event'),require('ui/widget/container/inputcontainer')
local book={id='sample',name=string.rep('长书名',20),author=string.rep('长作者名',12)}
local back,edit,comment,rating,status=0
local model={book=book,seconds=108115,today_seconds=1800,day_count=36,fraction=.97,chapter_fraction=.5,
    position_label='章节位置',position_text='773 / 795',progress_text='约 97%',chapter_title=string.rep('长章节名称',10),
    status='reading',rating=4,date_text='2026-09-12',start_date='2026-08-01',comment=string.rep('这一段值得重读。',30),
    chapter_page=3,chapter_pages=12,chapter_remaining=60,book_remaining=4800,
    on_rating=function(value) rating=value end,on_status=function(value) status=value end}
local function tap(widget,x,y)
    check(widget:handleEvent(event:new('Gesture',{ges='tap',pos=geom:new{x=x,y=y}})),'receipt consumes taps over the reader')
end
local function tap_control(widget,control)
    tap(widget,control.dimen.x+control.dimen.w/2,control.dimen.y+control.dimen.h/2)
end
local function paint(widget)
    local painted={}
    local bb=setmetatable({}, {__index=function(_,name)
        if name=='getWidth' then return function() return state.dimensions.w end end
        if name=='getHeight' then return function() return state.dimensions.h end end
        return function(_,x,y,w,h)
            if name=='paintRect' or name=='paintBorder' or name=='paintRoundedRect' then
                painted[#painted+1]={x,y,w,h}
                A.truthy(x>=0 and y>=0 and w>0 and h>0 and x+w<=state.dimensions.w+1 and y+h<=state.dimensions.h+1,
                    'all receipt ink remains within screen bounds')
            end
        end
    end})
    widget:paintTo(bb,0,0)
    for _,p in ipairs(painted) do
        A.truthy(not (p[1]==0 and p[2]==0 and p[3]==state.dimensions.w and p[4]==state.dimensions.h),
            'receipt leaves the reader visible around the paper')
    end
    count=count+2 -- The two paint invariants above check every emitted rectangle.
    local function inspect(node)
        if node.spots then for i,child in ipairs(node) do
            local p,size=node.spots[i],child:getSize()
            check(p[1]>=0 and p[2]>=0 and p[1]+size.w<=node.dimen.w+1 and p[2]+size.h<=node.dimen.h+1,
                string.format('real native content fits its parent (%s %dx%d): %s at %d,%d size %d,%d parent %d,%d',
                    widget.style,state.dimensions.w,state.dimensions.h,tostring(child.text),p[1],p[2],size.w,size.h,node.dimen.w,node.dimen.h))
        end end
        for _,child in ipairs(node) do inspect(child) end
    end
    inspect(widget)
end
G_reader_settings.isFalse=function(_,name) return name=='flash_ui' end
for _,dim in ipairs{{600,800,1},{800,600,1},{1200,1600,2},{1600,1200,2}} do
    state.dimensions.w,state.dimensions.h=dim[1],dim[2]
    state.screen.scaleBySize=function(_,n) return math.floor(n*dim[3]+.5) end
    package.loaded['ui/font'].getFace=function(_,_,n) n=n or 20;return {size=n*dim[3],orig_size=n,
        -- Metrics from the official KOReader NotoSans font; glyphs exceed the em box.
        ftsize={getHeightAndAscender=function() return n*dim[3]*1.362,n*dim[3]*1.069 end}} end
    for _,style in ipairs{'classic','simple','calendar','bookshop','boarding','library','cinema','postcard','newspaper',
        'exhibition','passport','contact','archive','timeline','bookmark'} do
        for _,size in ipairs{{75,90},{50,55},{95,95},{50,95},{95,55}} do
            local widget=Receipt.new{reading_model=model,style=style,width_percent=size[1],height_percent=size[2],
                on_back=function() back=back+1 end,on_edit=function(value) edit=value end,on_comment=function(value) comment=value end}
            eq(style,widget.style,'selected receipt style must not silently become classic')
            paint(widget)
            eq(math.floor(dim[1]*size[1]/100),widget.paper.dimen.w,'paper width follows the configured screen percentage')
            eq(false,widget.controls_visible,'receipt controls start hidden')
            eq(true,widget.ges_events.Tap ~= nil,'root registers native Tap gesture on Kindle')
            eq(true,widget.is_always_active,'receipt stays in the touch dispatch path')
            for _,x in ipairs{4,dim[1]/2,dim[1]-4} do
                local handled=input_container.onGesture(widget,{ges='tap',pos=geom:new{x=x,y=widget.paper.dimen.y+12}})
                check(handled,'native ges_events dispatch reaches onTap')
                eq(true,widget.controls_visible,'top-quarter tap opens controls across receipt width')
                check(input_container.onGesture(widget,{ges='tap',pos=geom:new{x=x,y=widget.paper.dimen.y+12}}),'native ges_events dispatch toggles onTap')
                eq(false,widget.controls_visible,'top-quarter tap toggles controls')
            end
            eq(false,widget.covers_fullscreen,'overlay keeps the reader underneath visible')
            tap(widget,dim[1]/2,widget.paper.dimen.y+12);paint(widget)
            eq(true,widget.controls_visible,'top-center tap reveals controls at every configured size')
            tap(widget,dim[1]/2,widget.paper.dimen.y+12)
            eq(false,widget.controls_visible,'repeating top-center tap hides controls')
            tap(widget,dim[1]/2,widget.paper.dimen.y+widget.paper.dimen.h/4);paint(widget)
            eq(true,widget.controls_visible,'paper quarter-height tap reveals controls at every configured size')
            tap_control(widget,widget.control_buttons[2]);eq('size',edit,'size control routes to width and height settings')
            tap_control(widget,widget.control_buttons[3]);eq('style',edit,'style control routes to style picker')
            tap_control(widget,widget.comment_button);eq(model.comment,comment,'bottom comment opens current saved text for editing')
            if style=='classic' then
                tap_control(widget,widget.rating_buttons[5]);eq(5,rating,'receipt star writes selected rating')
                tap_control(widget,widget.status_buttons[2]);eq('paused',status,'receipt status writes selected state')
            end
            widget:closeForReplacement()
            local empty=Receipt.new{reading_model={},style=style,width_percent=size[1],height_percent=size[2]}
            paint(empty)
            empty:closeForReplacement()
        end
    end
end
eq(0,back,'settings replacement never navigates backwards')
state.dimensions.w,state.dimensions.h=600,800
state.screen.scaleBySize=function(_,n) return n end
for _,style in ipairs{'classic','simple','calendar','bookshop','boarding','library','cinema','postcard','newspaper',
    'exhibition','passport','contact','archive','timeline','bookmark'} do
    local loaded,cancelled,closed=0,0,0
    local widget=Receipt.new{reading_model=model,style=style,on_back=function() closed=closed+1 end,
        cover_loader=function(_,cb) loaded=cb;return {cancel=function() cancelled=cancelled+1 end} end}
    loaded('good.jpg');eq('good.jpg',widget.cells[1].cover[1].file,'asynchronous cover replaces the paper placeholder')
    eq(0,widget.cells[1].cover[1].scale_factor,'native image retains its aspect ratio')
    loaded('bad.jpg');eq(nil,widget.cells[1].cover[1].file,'failed image decode leaves a stable placeholder')
    widget:onClose();eq(1,closed,'back navigates exactly once');eq(1,cancelled,'closing cancels cover request')
    eq(false,widget.is_always_active,'closed receipt leaves the touch dispatch path')
    local dirty=state.dirty;loaded('late.jpg');eq(dirty,state.dirty,'cover completion after close cannot repaint')
    eq(false,widget:onClose(),'repeated close is inert')
end
local closed=0
local external=Receipt.new{reading_model=model,on_back=function() closed=closed+1 end}
state.ui:close(external);eq(0,closed,'external UI removal performs cleanup without backward navigation')
local function texts(node,found)
    found=found or {};if node.text then found[#found+1]=node.text end
    for _,child in ipairs(node) do texts(child,found) end
    return table.concat(found,'\n')
end
local saved=Receipt.new{reading_model=model}
eq(false,texts(saved.comment_button):find('点击编辑',1,true)~=nil,'saved comment has no editing label')
eq(model.comment,texts(saved.comment_button),'saved comment uses the whole comment area')
saved:closeForReplacement()
local blank=Receipt.new{reading_model={book=book},with_background=true}
eq(true,blank.covers_fullscreen,'history receipt has an opaque full-screen background')
eq(true,texts(blank.comment_button):find('短评 · 点击编辑',1,true)~=nil,'empty comment remains discoverable')
local white=false
local bb=setmetatable({}, {__index=function(_,name) return function(_,x,y,w,h,color)
    if name=='paintRect' and x==0 and y==0 and w==600 and h==800 and color==package.loaded['ffi/blitbuffer'].COLOR_WHITE then white=true end
end end})
blank:paintTo(bb,0,0)
eq(true,white,'history receipt paints white over the old review page')
local blocker=blank.paper[1]
local original_blocker=blocker.handleEvent
blocker.handleEvent=function() return true end
blank:handleEvent(event:new('Gesture',{ges='tap',pos=geom:new{x=300,y=(800-blank.paper.dimen.h)/2+blank.paper.dimen.h/4}}))
eq(true,blank.controls_visible,'root quarter tap wins even when a paper child consumes Gesture')
blocker.handleEvent=original_blocker
blank.controls_visible=false
blank:onGesture{ges='tap',x=300,y=(800-blank.paper.dimen.h)/2+blank.paper.dimen.h/4}
eq(true,blank.controls_visible,'direct x/y kindle gesture opens receipt controls')
blank:closeForReplacement()
return count
