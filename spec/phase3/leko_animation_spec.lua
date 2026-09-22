package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local ok,Animation=pcall(require,'legado.lib.leko_animation');eq(true,ok,'independent animation exists')
local a=Animation:new{screen=h.screen,ui_manager=h.ui,device=require('device')}
local target={paintTo=function(_,bb) bb:fill(42) end};local completed=0
local buffers=#h.buffers
eq(nil,a:begin(target,'forward',function() completed=completed+1 end,{page_animation_enabled=false}),'disabled animation bypasses backend')
eq(buffers,#h.buffers,'disabled animation allocates no target')
assert(a:begin(target,'forward',function() completed=completed+1 end,{effect='swipe',refresh_mode='fast'}))
h:step();eq('Fast',h.refreshes[1].kind,'Swipe option uses requested device refresh mode')
eq(true,h.refreshes[1].x>0,'forward wipe begins at right edge')
h:drain();eq(1,completed,'completed transition reports once')
for x=0,599 do eq(42,h.screen.bb.pixels[x],'wipe reaches every target column') end
-- Some Kindle builds expose only refreshUI. Fast mode must fall back cleanly.
h.screen.refreshFast={}
local refresh_count_before_fallback=#h.refreshes
assert(a:begin(target,'forward',function() completed=completed+1 end,{effect='swipe',refresh_mode='fast'}))
h:drain();eq(2,completed,'fast swipe falls back when refreshFast is unavailable')
eq(refresh_count_before_fallback+8,#h.refreshes,'fallback still submits every swipe strip')
assert(a:begin(target,'backward',function() completed=completed+1 end,{effect='swipe'}))
a:cancel();h:drain();eq(2,completed,'cancelled callback cannot mutate later UI')
eq(0,#h.tasks,'cancel removes pending frames')
require('device').canDoSwipeAnimation=function() return true end
assert(a:begin(target,'forward',function() completed=completed+1 end,{effect='original'}))
eq(true,h.swipe,'original mode requests native swipe when available')
h:drain();eq(false,h.swipe,'one-shot native state is cleared before other UI')
assert(a:begin(target,'forward',function() completed=completed+1 end,{effect='original',chapter_changed=true,chapter_clean_wave_enabled=true}))
h:drain();eq(4,completed,'chapter wave completes and releases its page')
for i=2,#h.buffers do eq(1,h.buffers[i].freed,'every animation target is freed exactly once') end
return n
