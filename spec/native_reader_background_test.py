"""Check the production background pipeline with KOReader's unchanged BlitBuffer.

Only image decoding, PNG/file I/O and the platform loader are replaced. Scaling,
clipping, pixel composition, allocation and freeing use the actual KOReader code.
Run: .tools/python/python.exe spec/native_reader_background_test.py
"""
from pathlib import Path

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parent.parent

CHECK = r'''
local ffi=require('ffi')
ffi.cdef[[void *malloc(size_t); void *calloc(size_t,size_t); void free(void *);]]
package.loaded['ffi/posix_h']={}
package.loaded['ffi/util']={idiv=function(a,b) return math.floor(a/b) end}
ffi.loadlib=function() error('host check uses the native Lua BlitBuffer path') end
local BB=require('ffi/blitbuffer')
local allocated={}
local native_new=BB.new
BB.new=function(...)
    local buffer=native_new(...)
    allocated[#allocated+1]=buffer
    return buffer
end
local count=0
local function eq(want,got,label)
    count=count+1
    assert(want==got,label..': expected '..tostring(want)..', got '..tostring(got))
end
local function all_freed()
    for _,buffer in ipairs(allocated) do
        eq(0,buffer:getAllocated(),'native buffer memory released after prepare')
    end
end
local files={['/fixture.png']={mode='file',size=128,modification=1}}
package.loaded['libs/libkoreader-lfs']={attributes=function(path) return files[path] end}
package.loaded.datastorage={getDataDir=function() return '/data' end}
package.loaded['legado.lib.fs']={new=function() return {ensureDirectory=function() return true end} end}
local width,height=4,6
package.loaded.device={screen={getWidth=function() return width end,getHeight=function() return height end}}
package.loaded['ui/renderimage']={renderImageFile=function(_,_,_,w,h)
    eq(nil,w,'decoder retains source width');eq(nil,h,'decoder retains source height')
    local source=BB.new(2,2,BB.TYPE_BBRGB32)
    -- RenderImage returns premultiplied alpha for ordinary PNG/WebP images.
    source:setPixel(0,0,BB.ColorRGB32(0,0,0,0))
    source:setPixel(1,0,BB.ColorRGB32(64,64,64,128))
    source:setPixel(0,1,BB.ColorRGB32(128,128,128,255))
    source:setPixel(1,1,BB.ColorRGB32(192,192,192,255))
    return source
end}
local encoding_fails,rename_fails=false,false
-- Exercise the same typed FFI boundary as lodepng_encode_file: Color8* is not
-- implicitly convertible to const unsigned char*, even though its bytes fit.
local encoder_input=ffi.cast('int(*)(const uint8_t*)',function() return 0 end)
package.loaded['ffi/png']={encodeToFile=function(path,data,w,h,n)
    eq(0,encoder_input(data),'PNG encoder receives a byte pointer')
    eq(1,n,'cache uses grayscale channel')
    files[path]={mode='file',size=encoding_fails and 0 or w*h,pixels=ffi.string(data,w*h)}
    return not encoding_fails
end}
os.rename=function(source,dest)
    if rename_fails then return nil,'read-only output' end
    files[dest],files[source]=files[source],nil
    return true
end
os.remove=function(path) files[path]=nil;return true end
local values={reader_background='/fixture.png',reader_background_scale=100,
    reader_background_y=50,reader_background_x=0}
local settings={get=function(_,key) return values[key] end}
local Background=require('legado.lib.reader_background')
local output='/data/legado/reader-background.png'
local function pixels(expected,label)
    eq(output,Background.prepare(settings),label..' produces a cache')
    eq(#expected,#files[output].pixels,label..' byte length')
    for i,value in ipairs(expected) do eq(value,files[output].pixels:byte(i),label..' pixel '..i) end
    all_freed()
end
-- A square must remain 4x4 on a 4x6 screen, with white top/bottom letterboxing.
pixels({255,255,255,255, 255,255,191,191, 255,255,191,191,
    128,128,192,192, 128,128,192,192, 255,255,255,255},'aspect and alpha')
local before=#allocated
eq(output,Background.prepare(settings),'identical settings reuse the completed cache')
eq(before,#allocated,'cache hit retains no new native buffers')
-- Move the fitted image one pixel left and align its bottom with the screen.
values.reader_background_x,values.reader_background_y=-25,100
pixels({255,255,255,255, 255,255,255,255, 255,191,191,255,
    255,191,191,255, 128,192,192,255, 128,192,192,255},'offset clipping')
-- 200% creates an 8x8 image: crop its center into a 4x4 screen.
height=4;values.reader_background_scale,values.reader_background_x,values.reader_background_y=200,0,50
pixels({255,255,191,191, 255,255,191,191,
    128,128,192,192, 128,128,192,192},'oversized clipping')
local completed=files[output]
encoding_fails=true;values.reader_background_scale=150
eq(nil,Background.prepare(settings),'encoder failure rejects partial image')
eq(completed,files[output],'encoder failure preserves completed cache')
eq(nil,files[output..'.part.png'],'encoder failure removes temporary pixels')
all_freed()
encoding_fails=false;rename_fails=true
eq(nil,Background.prepare(settings),'publication failure is reported')
eq(completed,files[output],'publication failure preserves completed cache')
eq(nil,files[output..'.part.png'],'publication failure removes temporary pixels')
all_freed()
values.reader_background=''
before=#allocated
eq(nil,Background.prepare(settings),'blank background needs no texture')
eq(before,#allocated,'blank background allocates no buffers')
encoder_input:free()
return count
'''


if __name__ == '__main__':
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().root = ROOT.as_posix()
    runtime.execute("package.path=root..'/legado.koplugin/?.lua;'..root..'/.tools/koreader/base/?.lua;'..package.path")
    print(f'Native background pipeline: {runtime.execute(CHECK)} assertions passed')
