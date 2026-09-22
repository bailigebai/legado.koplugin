local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Side=require('legado.ui.side_toc')
local function chapters(count)
    local t={};for i=1,count do t[i]={uid='c'..i,index=i,title='Chapter '..i}end;return t
end
local replies={}
local side=Side.new{items=chapters(15),on_load_page=function(page,done)
    replies[page]=done;return {cancel=function()end}
end}
side:goPage(2);side:goPage(3)
replies[3](chapters(40),true)
replies[2](chapters(30),false)
eq(true,side.complete,'an older partial response cannot undo known catalog completion')
eq(40,side:knownCount(),'an older response does not truncate known catalog')
eq('Chapter 31',side:menuItems()[1].title,'late response leaves current page unchanged')
side:close()
-- A larger shared response may fulfill another request before it completes.
replies={}
side=Side.new{items=chapters(15),on_load_page=function(page,done)
    replies[page]=done;return {cancel=function()end}
end}
side:goPage(3);side:goPage(2)
replies[3](chapters(45),false)
eq('Chapter 16',side:menuItems()[1].title,'fulfilled visible page is shown without waiting for its own response')
replies[2](nil,false,{code='NETWORK_ERROR'})
eq('Chapter 16',side:menuItems()[1].title,'redundant failed request cannot hide cached content')
side:close()
replies={}
side=Side.new{items=chapters(15),on_load_page=function(page,done)
    replies[page]=done;return {cancel=function()end}
end}
side:goPage(2);side:goPage(3);side:previousPage()
eq(true,side:menuItems()[1].loading,'returning to an earlier in-flight page shows its loading state')
side:goPage(3);replies[3](nil,false,{code='NETWORK_ERROR'})
replies[2](chapters(30),false)
eq('function',type(side:menuItems()[1].callback),'a shorter successful response preserves the visible failed page retry')
side:close()
return n
