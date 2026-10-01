require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local Json=require('legado.lib.json_codec')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end

local shown={}
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,close=function() end}}
local function last() return shown[#shown] end
local source_books={}
for index=1,19 do source_books[index]={id='source-'..index,name='书源书'..index} end
local remote_books={}
for index=1,18 do remote_books[index]={id='account:remote-'..index,remote_id='remote-'..index,
    source_id='weread',name='微信书'..index,read_at=19-index} end
local app=App.new{storage={listShelf=function() return source_books end,listProgress=function() return {} end},
    local_library={scan=function() return {{id='local-1',name='本地书',is_local=true}} end},
    weread_auth={hasSession=function() return true end,session=function() return {vid='account'} end},
    fs={readBounded=function() return Json.encode{account_id='account',books=remote_books,read_time_schema=2} end},
    weread_shelf_path='weread-shelf.json',show=function(view) return presenter:show(view) end}
presenter.app=app
local function choose(index)
    last().header_action.callback()
    eq('切换书架',last().title,'each mode opens the same switch menu')
    return last().items[index].callback()
end

app:openBookshelf('sources')
last().on_next()
eq(2,last().page,'source page advances')
choose(2)
eq('微信读书',last().title,'source menu enters WeRead shelf')
eq(5,#last().items,'WeRead first page has one large and four small books')
last().on_next()
eq(2,last().page,'WeRead page advances independently')
choose(3)
eq('本地书架',last().title,'WeRead menu enters local shelf')
eq('local-1',last().items[1].book.id,'local shelf uses local identity')
choose(1)
eq(2,last().page,'source page remains two after visiting two modes')
choose(2)
eq(2,last().page,'WeRead page remains two after visiting two modes')
eq('remote-6',last().items[1].book.remote_id,'restored WeRead page keeps account-specific books')

return count
