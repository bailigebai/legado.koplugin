package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local R=require('legado.ui.leko_reader')
local errors=0
local reader=assert(R.new{book={id='b',name='Book'},chapter={uid='c',title='Chapter'},body='<p>正文</p>',ui_manager=h.ui,
    callbacks={error=function() errors=errors+1 end}})
reader.animation.settle=function() error('animation boundary') end
local ok=pcall(function() reader:onTap(reader,{pos={x=reader.dimen.w*.8,y=reader.dimen.h*.8}}) end)
assert(ok,'tap errors must not escape the immersive reader')
ok=pcall(function() reader:onSwipe(reader,{direction='west'}) end)
assert(ok,'swipe errors must not escape the immersive reader')
ok=pcall(function() reader:onRotation() end)
assert(ok,'rotation errors must not escape the immersive reader')
assert(errors>0,'event failures are reported through the reader error callback')
reader._dispose=function() error('dispose boundary') end
local closed,close_error=reader:close()
assert(closed==nil and close_error and close_error.code=='READER_ERROR','close failures become reader errors')
assert(pcall(function() reader:onCloseWidget() end),'close widget errors must not escape KOReader')
return 4
