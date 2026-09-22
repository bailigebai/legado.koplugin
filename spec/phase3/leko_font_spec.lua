package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
package.loaded.fontlist={getFontList=function() return {'/fonts/book.ttc'} end,
    getLocalizedFontName=function() return '测试宋体' end,
    fontinfo={['/fonts/book.ttc']={{index=0,style_name='Regular',scripts='zh-CN'},{index=1,bold=true,style_name='Bold',scripts='zh-CN'}}}}
local F=require('legado.ui.leko_font_selection')
local items,selection=F.buildItems{body_font='/fonts/book.ttc',body_font_index=1}
eq(3,#items,'system font and each TTC face remain independently selectable')
eq(3,selection,'current TTC face is selected by path plus face index')
eq(true,items[2].text:find('常规',1,true)~=nil,'regular face display is in Chinese')
eq(true,items[3].text:find('粗体',1,true)~=nil,'bold face display is in Chinese')
local font=assert(F.validateSelection(items[3]));eq(1,font.face_index,'localized label never changes the native face index')
local original=require('ui/font').getFace
require('ui/font').getFace=function(self,path,...) if path=='missing.ttf' then error('font removed') end;return original(self,path,...) end
local absent=F.validateSelection{font_path='missing.ttf',face_index=0}
eq(nil,absent,'missing fonts are not accepted as a successful selection')
local R=require('legado.ui.leko_reader')
local view=assert(R.new{book={id='b'},chapter={uid='c',title='章'},body='<p>正文</p>',style={body_font='missing.ttf'}})
eq('cfont',view:getReaderSettings().body_font,'reopening a removed font repairs only this reader style')
view:close()
return n
