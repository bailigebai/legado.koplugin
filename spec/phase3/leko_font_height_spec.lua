package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
G_reader_settings.nilOrTrue=function(_,key) return key~='use_xtext' end
G_reader_settings.has=function() return false end
require('util').splitFilePathName=function(path) return path:match('^(.-)([^/]+)$') end
package.loaded.fontlist={fontdir='fonts',getFontList=function() return {} end}
-- Keep Font/TextWidget/TextBoxWidget code real; supply deterministic tall
-- Noto metrics at the native rasterizer boundary unavailable on Windows.
package.loaded['ffi/freetype']={newFaceSize=function(_,size)
    return {getHeightAndAscender=function() return size*1.362,size*1.069 end,
        getEmboldenHalfStrength=function() return 1 end}
end}
package.loaded['ui/font']=nil
local Reader=require('legado.ui.leko_reader')
for _,height in ipairs{166,600} do
    h.dimensions.h=height
    local view=assert(Reader.new{book={id='height'},chapter={uid='c',title=''},
        body='<p style="font-size:3em">Large</p><p>正文</p>',
        style={body_font_size=27,title_font_size=34,show_header=true,show_footer=true,indent=false,page_transition='off'}})
    local geometry=view.page.geometry
    local bottom=geometry.body_top+geometry.header_height+geometry.content_height
    for _,item in ipairs(view.widgets) do if item.element.type=='line' then
        eq(true,item.widget:getSize().h<=item.element.height,'allocated styled row includes its actual glyph height')
        eq(true,item.y+item.widget:getSize().h<=bottom,'tall font never paints over the footer')
    end end
    eq(true,view.page.at_end or require('legado.lib.leko_text').positionLess(view.page.start_position,view.page.next_position),
        'tall-font page keeps forward progress')
    view:close()
end
return count
