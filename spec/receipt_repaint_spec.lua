-- Exercise the real event AND repaint queues, not a manual paintTo after tapping.
local h=require('native_library_harness').install()
local A=require('assertions')
local count=0
local function eq(want,got,why) count=count+1;A.equal(want,got,why) end
local function noop() end
package.loaded.device._UIManagerReady=noop
package.loaded['ffi/util']={}
package.loaded['ui/time'].now=function() return 0 end
package.loaded.dbg.v=noop
G_reader_settings.isFalse=function(_,name) return name=='flash_ui' end
local screen=h.screen
screen.beforePaint,screen.afterPaint=noop,noop
screen.getDPI=function() return 300 end
for _,name in ipairs{'refreshA2','refreshFast','refreshUI','refreshPartial','refreshNoMergeUI',
    'refreshNoMergePartial','refreshFlashUI','refreshFlashPartial','refreshFull'} do screen[name]=noop end
screen.bb=setmetatable({}, {__index=function(_,name)
    if name=='getWidth' then return function() return h.dimensions.w end end
    if name=='getHeight' then return function() return h.dimensions.h end end
    return noop
end})
local manager_file=os.getenv('LEGADO_DEVICE_UIMANAGER')
package.loaded['ui/uimanager']=nil
local ui=manager_file and dofile(manager_file) or require('ui/uimanager')
package.loaded['ui/uimanager']=ui
local receipt_file=os.getenv('LEGADO_DEVICE_RECEIPT')
local Receipt=receipt_file and dofile(receipt_file) or require('legado.ui.receipt_screen')
local Event,Geom=require('ui/event'),require('ui/geometry')
local Text=require('ui/widget/textwidget')
local original_paint=Text.paintTo
local labels={}
Text.paintTo=function(self,...)
    labels[self.text]=true
    return original_paint(self,...)
end
local function frame()
    labels={}
    ui:_repaint()
end
local function tap(x,y)
    ui:sendEvent(Event:new('Gesture',{ges='tap',pos=Geom:new{x=x,y=y}}))
    frame()
end
local function press(button)
    tap(button.dimen.x+button.dimen.w/2,button.dimen.y+button.dimen.h/2)
end
local headings={classic='READ RECEIPT',simple='章节',calendar='总进度',bookshop='书与时光',
    boarding='阅读登机牌',library='私人图书馆',cinema='CINEMA / 阅读放映室',postcard='寄给未来的自己',newspaper='阅读日报',
    exhibition='阅读展览',passport='阅读护照',contact='READING / CONTACT SHEET',archive='阅读档案',
    timeline='阅读时间轴',bookmark='BOOKMARK'}
for _,background in ipairs{false,true} do
    for _,style in ipairs{'classic','simple','calendar','bookshop','boarding','library','cinema','postcard','newspaper',
        'exhibition','passport','contact','archive','timeline','bookmark'} do
        h.dimensions.w,h.dimensions.h=1272,1696 -- attached Kindle Paperwhite 6
        local back,edit,load_cover=0,nil,nil
        local reader_taps=0
        local reader={covers_fullscreen=true,paintTo=noop,is_always_active=true,
            handleEvent=function(_,event)
                if event.handler=='onGesture' then reader_taps=reader_taps+1;return true end
            end}
        ui:show(reader)
        local receipt=Receipt.new{with_background=background,style=style,
            reading_model={book={name='示例',author='作者'}},
            on_back=function() back=back+1 end,
            on_edit=function(value) edit=value end,
            cover_loader=function(_,callback) load_cover=callback end}
        ui:show(receipt)
        frame()
        eq(nil,labels['宽度 / 高度'],'initial frame has no hidden toolbar')
        for _,x in ipairs{4,636,1268} do
            tap(x,1696/8)
            eq(true,receipt.controls_visible,'tap changes toolbar state')
            eq(true,labels['宽度 / 高度'],'tap must DRAW the toolbar through UIManager')
            eq(true,labels['返回'],'back button must be painted')
            eq(true,labels['样式'],'style button must be painted')
            tap(x,1696/8)
            eq(false,receipt.controls_visible,'second tap hides controls')
            eq(nil,labels['宽度 / 高度'],'hide redraws the receipt without toolbar')
            eq(true,labels[headings[style]],
                'hide must repaint underlying paper to erase the toolbar')
        end
        eq(0,reader_taps,'header gestures do not reach reader clock')
        tap(636,1696/8)
        press(receipt.control_buttons[2]);eq('size',edit,'painted size control is clickable')
        press(receipt.control_buttons[3]);eq('style',edit,'painted style control is clickable')
        -- Delayed cover must also request repaint, without waiting for another gesture.
        load_cover('good.jpg');frame()
        eq(true,labels['宽度 / 高度'],'cover completion repaints the visible receipt')
        press(receipt.control_buttons[1]);eq(1,back,'painted back control closes once')
        eq(reader,ui._window_stack[#ui._window_stack].widget,'back leaves the underlying reader')
        load_cover('late.jpg');frame()
        eq(nil,labels['宽度 / 高度'],'closed receipt is never repainted')
        ui:close(reader)
    end
end
return count
