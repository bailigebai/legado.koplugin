local h=require('native_library_harness').install()
local A=require('assertions')
local count=0
local function eq(want,got,why) count=count+1;A.equal(want,got,why) end
local path='/mnt/us/pictures/背景.jpg'
local decodes,releases=0,0
local missing=false
package.loaded['libs/libkoreader-lfs']={attributes=function(file)
    if file=='/directory' then return {mode='directory',size=20} end
    if file=='/large.jpg' then return {mode='file',size=9*1024*1024} end
    if file==path and missing then return end
    if file==path or file=='/broken.jpg' then return {mode='file',size=100} end
end}
package.loaded['ui/renderimage']={renderImageFile=function(_,file,frames,w,h)
    decodes=decodes+1
    eq(false,frames,'background uses only a still image')
    eq(nil,w,'decode does not stretch image width')
    eq(nil,h,'decode does not stretch image height')
    if file=='/broken.jpg' then error('corrupt image') end
    return {free=function() releases=releases+1 end}
end}
-- Display backend substitute owns and frees the supplied decoded image like ImageWidget.
local Image=package.loaded['ui/widget/imagewidget']
Image.free=function(self) if self.image then self.image:free();self.image=nil end end
local Receipt=require('legado.ui.receipt_screen')
for _,file in ipairs{'https://example.com/bg.jpg','relative.jpg','/missing.jpg','/directory','/large.jpg','/bad\0.jpg'} do
    local image,err=Receipt.loadBackground(file)
    eq(nil,image,'invalid background is rejected')
    eq('string',type(err),'invalid background explains the error')
end
eq(0,decodes,'bad paths and oversized files never reach native decoder')
local image,err=Receipt.loadBackground('/broken.jpg')
eq(nil,image,'corrupt decoder cannot crash the receipt')
eq('string',type(err),'corrupt decoder error becomes a usable message')
local stack={}
h.ui.show=function(_,w) stack[#stack+1]=w end
h.ui.close=function(_,w) for i=#stack,1,-1 do if stack[i]==w then table.remove(stack,i) end end end
local function top() return stack[#stack] end
local values,fail={},false
local settings=require('legado.lib.settings').new{read=function() return values end,write=function(v)
    if fail then return nil,{code='STORAGE_ERROR'} end;values=v;return true
end}
local simple={new=function(_,v) return v end}
package.loaded['ui/widget/pathchooser']=simple
local presenter=require('legado.ui.presenter').new{app={settings=settings},ui_manager=h.ui,input_dialog=simple,info_message=simple}
local refreshes=0
local function edit() presenter:_receiptBackground(function() refreshes=refreshes+1 end) end
edit();local dialog=top()
dialog.buttons[2][2].callback('/missing.jpg')
eq('',settings:get('receipt_background'),'invalid save preserves the old background')
eq(0,refreshes,'invalid save does not replace history page')
h.ui:close(top())
dialog.buttons[1][1].callback();local picker=top()
eq(false,picker.select_directory,'native picker selects files rather than folders')
eq(true,picker.file_filter('PHOTO.JPEG'),'native picker accepts uppercase image extensions')
eq(false,picker.file_filter('book.epub'),'native picker excludes books')
picker.onConfirm(path);h.ui:close(picker)
eq(path,settings:get('receipt_background'),'native picker persists the selected image path')
eq(1,refreshes,'successful background change refreshes the originating review')
eq(1,releases,'validation releases its temporary decoded image')
local widget=Receipt.new{with_background=true,background_path=path,reading_model={book={name='书名'}}}
eq(true,widget.covers_fullscreen,'custom background covers the record page')
eq(0,widget.background_widget.scale_factor,'native ImageWidget preserves image proportions')
local bg,paper=widget.background_widget,widget.paper
widget:onGesture{ges='tap',pos={x=300,y=(800-paper.dimen.h)/2+paper.dimen.h/4}}
eq(true,widget.controls_visible,'custom-background receipt controls open')
widget:onGesture{ges='tap',pos={x=0,y=0}}
eq(false,widget.controls_visible,'outside tap hides controls')
eq(bg,widget[1],'hiding controls retains the background image')
eq(paper,widget[2],'hiding controls retains the receipt paper')
widget:closeForReplacement()
eq(2,releases,'closing receipt releases decoded image')
edit();dialog=top();fail=true;dialog.buttons[1][2].callback()
eq(path,settings:get('receipt_background'),'failed reset preserves selected image')
h.ui:close(top());fail=false;dialog.buttons[1][2].callback()
eq('',settings:get('receipt_background'),'reset restores blank white background')
eq(2,refreshes,'reset refreshes without losing review navigation')
missing=true
widget=Receipt.new{with_background=true,background_path=path}
eq(nil,widget.background_widget,'removed image safely falls back to white')
eq(true,widget.covers_fullscreen,'removed image still hides underlying review')
widget:closeForReplacement()
return count
