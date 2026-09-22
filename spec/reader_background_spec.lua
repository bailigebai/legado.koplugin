local h=require('native_library_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Settings=require('legado.lib.settings')
local s=Settings.new({})
eq('',s:get('reader_background'),'reading background starts blank')
local Background=require('legado.lib.reader_background')
local g=Background.layout(600,800,300,400,100,50,0)
eq(600,g.w,'image fits screen uniformly');eq(800,g.h,'aspect ratio preserved')
g=Background.layout(600,800,400,400,50,100,10)
eq(300,g.w,'scale is relative to fitted image');eq(300,g.h,'no distortion')
eq(210,g.x,'horizontal offset is screen percent');eq(500,g.y,'vertical ratio positions within free height')
local files={['/pictures']={mode='directory'},['/pictures/a.png']={mode='file',size=123},['/pictures/z.jpg']={mode='file',size=200}}
local lfs={attributes=function(p) return files[p] end,dir=function() local i=0;local list={'.','z.jpg','a.png'};return function() i=i+1;return list[i] end end}
eq('/pictures/a.png',Background.resolve('/pictures',lfs),'directory selects first supported image deterministically')
eq(nil,Background.resolve('/missing',lfs),'missing image is rejected')
eq(nil,Background.resolve('https://example.test/bg.jpg',lfs),'only local image paths accepted')
local current,cleared
local doc={setBackgroundImage=function(_,v) current=v;cleared=true end,resetCallCache=function() end}
eq(true,Background.apply(doc,s),'blank can be applied without loading image libraries')
eq(true,cleared,'blank clears previous image');eq(nil,current,'blank passes nil to native renderer')
for key,value in pairs{reader_background_scale=50,reader_background_y=80,reader_background_x=-20} do
    eq(value,s:set(key,value),'background transform persists')
end
local denied={attributes=lfs.attributes,dir=function() error('access denied') end}
eq(nil,Background.resolve('/pictures',denied),'unreadable directory returns an error instead of throwing')
-- Exercise the full decode/transform/write lifecycle; the host decoder must retain original dimensions.
local decoded,freed,writes=0,0,0
local blit,scaled_size
package.loaded['libs/libkoreader-lfs']=lfs
package.loaded.datastorage={getDataDir=function() return '/data' end}
package.loaded['legado.lib.fs']={new=function() return {ensureDirectory=function() return true end} end}
local function free() freed=freed+1 end
package.loaded['ui/renderimage']={renderImageFile=function(_,path,frames,w,h)
    eq(nil,w,'decoder must not stretch to requested width');eq(nil,h,'decoder must not stretch to requested height')
    decoded=decoded+1
    return {getWidth=function() return 400 end,getHeight=function() return 400 end,free=free,
        scale=function(_,w2,h2) scaled_size={w2,h2};return {free=free} end}
end}
package.loaded['ffi/blitbuffer']={TYPE_BB8=1,COLOR_WHITE=255,new=function(w,h)
    eq(600,w,'background texture matches screen width');eq(800,h,'background texture matches screen height')
    return {data='pixels',free=free,fill=function() end,pmulalphablitFrom=function(_,_,dx,dy,sx,sy,cw,ch) blit={dx,dy,sx,sy,cw,ch} end}
end}
package.loaded['ffi/png']={encodeToFile=function(path) writes=writes+1;files[path]={mode='file',size=200};return true end}
local rename,remove=os.rename,os.remove
os.rename=function(a,b) files[b]=files[a];files[a]=nil;return true end
os.remove=function(p) files[p]=nil;return true end
s:set('reader_background','/pictures');s:set('reader_background_scale',50);s:set('reader_background_y',100);s:set('reader_background_x',10)
eq('/data/legado/reader-background.png',Background.prepare(s),'transformed image cache generated')
eq(300,scaled_size[1],'square image stays square');eq(300,scaled_size[2],'source aspect preserved')
eq(210,blit[1],'real pipeline applies horizontal offset');eq(500,blit[2],'real pipeline applies vertical position')
eq(3,freed,'decoder,scaled and canvas buffers freed once')
Background.prepare(s);eq(1,decoded,'same settings reuse image across chapters');eq(1,writes,'cached texture not rewritten')
package.loaded['ffi/png'].encodeToFile=function(path) files[path]={mode='file',size=0};return false end
s:set('reader_background_scale',75)
eq(nil,Background.prepare(s),'encoding failure with partial file is rejected')
eq(nil,files['/data/legado/reader-background.png.part.png'],'failed image temporary file is cleaned')
eq(200,files['/data/legado/reader-background.png'].size,'failed encoding preserves previous completed image')
package.loaded['ui/renderimage'].renderImageFile=function() error('decode failure') end
s:set('reader_background_scale',75)
local failed,err=Background.apply(doc,s)
eq(false,failed,'decode failure is reported');eq(true,type(err)=='string','failure has a message');eq(nil,current,'failure safely restores blank')
os.rename,os.remove=rename,remove
return n
