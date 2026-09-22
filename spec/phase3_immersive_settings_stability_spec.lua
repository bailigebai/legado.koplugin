package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install();local ui=h.ui
ui.getTime=function() return 0 end
local R=require('legado.ui.leko_reader')
local reader=assert(R.new{book={id='b',name='Book'},chapter={uid='c',title='Chapter'},body='<p>正文</p>',ui_manager=ui,
    callbacks={pause=function() return true end,resume=function() return true end,flush=function() return true end,
        settings=function() error('settings callback panic') end,error=function() end}})
ui:show(reader);assert(reader:showMenu())
local target
for _,row in ipairs(reader.menu_dialog.buttons) do for _,button in ipairs(row) do if button.text=='插件设置' then target=button end end end
assert(target,'immersive settings action is present')
local ok=pcall(target.callback)
assert(ok,'settings callback panic never escapes KOReader menu event')
assert(reader.last_error and reader.last_error.code=='READER_ERROR','settings panic is converted to a reader error')
reader:close()
return 2
