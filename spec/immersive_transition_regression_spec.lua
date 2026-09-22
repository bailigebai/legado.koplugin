local A=require('assertions')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end

-- A thrown reader error must reach the presenter. Replacing it with a generic
-- Storage_error makes a real Kindle failure impossible to diagnose.
local App=require('legado.ui.app')
local values={immersive_reader=false}
local settings={get=function(_,key) return values[key] end,
    set=function(_,key,value) values[key]=value;return value end}
local book={id='book',source_id='source',name='Book'}
local state={book=book,source={id='source'},chapters={{uid='c1'}},index=1,catalog_complete=true}
local shown
local app=App.new{settings=settings,reader_session={open=function()
    error({code='READER_ERROR',message='字体加载失败'})
end},show=function(view) shown=view;return view end}
local document={backend='native',reading_state=state,closed=false,getProgressFraction=function() return .2 end}
local result=app:toggleImmersiveReader(document)
eq(result,shown,'mode failure is presented')
eq(true,type(shown)=='table' and tostring(shown.text):find('字体加载失败',1,true)~=nil,
    'mode failure preserves the original reader error')

-- A chapter prepared for the current layout should not synchronously repaint a
-- second off-screen page during the handoff. That repaint was the dominant
-- source of the 3-4 second Kindle pause at chapter boundaries.
package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local Adapter=require('legado.lib.leko_reader_ui')
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',120)..'</p>'
local reading_state={book={id='book',source_id='source'},source={id='source'},
    chapters={{uid='c1'},{uid='c2'}},index=1,catalog_complete=true}
local owner={settings={get=function() end},ui_manager=h.ui,prepared_chapters={}}
local first=assert(Adapter.open(owner,{state=reading_state,body=body,progress={immersive_style={body_font_size=30}}},{}))
owner.current_document=first
eq(true,Adapter.prepare(owner,reading_state,reading_state.chapters[2],body),'next chapter is prepared')
reading_state.index=2
local methods=getmetatable(first.widget).__index
local original_validate=methods.validatePaint
local validations=0
methods.validatePaint=function()
    validations=validations+1
    return nil,{code='READER_ERROR',message='validation should be deferred'}
end
local second,err=Adapter.open(owner,{state=reading_state,body=body,progress={immersive_style={body_font_size=30}}},{})
methods.validatePaint=original_validate
eq(true,second~=nil,'prepared chapter opens even when transition validation is unavailable')
eq(0,validations,'prepared transition skips duplicate synchronous validation')
if second then second:close() end
if first and not first.closed then first:close() end

return n
