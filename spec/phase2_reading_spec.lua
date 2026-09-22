local h=require('native_library_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Cleaner=require('legado.lib.content_cleaner')
eq('<p>正文</p>',Cleaner.normalize('<p>正文</p><p><br>&#160;　</p><br><br>'),'empty tail markup does not become blank reading pages')
eq('<p><img src="https://x.test/p.png"></p>',Cleaner.normalize('<p><img src="https://x.test/p.png"></p>'),'image paragraph is not removed as empty text')
local long=string.rep('中文长段落。',12000)
eq('<p>'..long..'</p>',Cleaner.normalize('<p>'..long..'</p>'),'long paragraph preserves all characters')
local Settings=require('legado.lib.settings');local settings=Settings.new({})
eq(11,settings:get('reader_header_font_size'),'smaller default header')
eq(11,settings:get('reader_footer_font_size'),'smaller default footer')
eq(8,settings:set('reader_header_font_size',1),'font lower limit')
eq(18,settings:set('reader_footer_font_size',99),'font upper limit')
local Adapter=require('legado.lib.koreader_reader_ui')
for _,width in ipairs{600,1072,1448} do
    for _,size in ipairs{20,32,48,64} do
        local values=Adapter.marginValues(width,size,1)
        for i=2,5 do
            eq(true,values[i]>values[i-1],'each margin preset is visibly different')
            eq(true,math.floor((width-2*values[i])/size)<math.floor((width-2*values[i-1])/size),'each wider preset removes a full Chinese column')
        end
    end
end
local zones
local reader={view={},rolling={setupTouchZones=function() zones=true end}}
Adapter:applyTouchZones(reader)
local forward,backward=reader.view:getTapZones()
eq(true,zones,'native touch zones are registered again after changing the current view')
eq(.75,forward.ratio_w,'next page owns three quarters of body width')
eq(.25,backward.ratio_w,'previous page remains reachable')
eq(.12,forward.ratio_y,'top menu remains outside page-turn zone')
eq(.76,forward.ratio_h,'bottom settings remain outside page-turn zone')
local applied
local native={document={getFontSize=function() return 32 end},typeset={configurable={},onSetPageHorizMargins=function(_,value) applied=value end}}
eq(true,Adapter:applyMarginPreset(native,3),'margin menu applies to native typeset')
eq(applied[1],applied[2],'margins are symmetric')
eq(applied[1],native.typeset.configurable.h_page_margins[1],'native SaveSettings will persist margin preference')
return n
