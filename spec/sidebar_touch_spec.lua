package.path='spec/phase3/?.lua;'..package.path
require('leko_reader_harness').install()
local graph_stub=package.loaded.depgraph
package.loaded.depgraph=nil
for key,value in pairs(require('depgraph')) do graph_stub[key]=value end
local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Adapter=require('legado.lib.koreader_reader_ui')
local zone,toc,passed=nil,0,nil
local doc={};local reader={view={},registerTouchZones=function(_,zones)zone=zones[1]end}
local adapter=Adapter.new{on_toc=function(value)toc=toc+1;passed=value;return true end}
adapter:applyTouchZones(reader,doc)
eq('legado_sidebar',zone and zone.id,'native reader registers a named sidebar zone')
eq(.0625,zone.screen_zone.ratio_y,'zone starts below the status line')
eq(.125,zone.screen_zone.ratio_h,'zone spans the upper eighth of the reading surface')
zone.handler();eq(1,toc,'native tap opens sidebar');eq(doc,passed,'tap passes current proxy')
doc.closed=true;zone.handler();eq(1,toc,'closed reader cannot reopen an old sidebar')
local Container=require('ui/widget/container/inputcontainer')
local native=Container:new{view={}}
local menu_hits=0
native:registerTouchZones{{id='readermenu_ext_tap',ges='tap',
    screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=.25},handler=function()menu_hits=menu_hits+1;return true end}}
doc.closed=false;adapter:applyTouchZones(native,doc)
native:onGesture{ges='tap',pos={x=575,y=100,w=0,h=0}}
eq(2,toc,'actual native gesture dispatcher gives sidebar precedence over the top menu')
eq(0,menu_hits,'overlapping menu does not consume the sidebar shortcut')
native:onGesture{ges='tap',pos={x=300,y=20,w=0,h=0}}
eq(1,menu_hits,'native top menu still receives taps outside the shortcut')
local Reader=require('legado.ui.leko_reader')
local view=assert(Reader.new{book={id='b',name='test'},chapter={uid='c',title='test'},body='<p>test</p>',index=1,count=1,callbacks={toc=function()end}})
view.runAction=function(_,name)passed=name;return true end
view.showMenu=function()passed='menu';return true end
view._resumeIfVisible=function()end
view.nextPage=function()passed='next';return true end
view:onTap(nil,{pos={x=575,y=100}});eq('toc',passed,'independent reader uses the same right-upper shortcut')
view:onTap(nil,{pos={x=300,y=20}});eq('menu',passed,'ordinary top menu remains accessible')
view:onTap(nil,{pos={x=575,y=400}});eq('next',passed,'normal right-side page turn remains accessible')
view:close()
return n
