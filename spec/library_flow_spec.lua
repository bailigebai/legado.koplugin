local A = require("assertions")
local App = require("legado.ui.app")
local Presenter = require("legado.ui.presenter")
local Models = require("legado.lib.models")
local shown, windows, saved, progress, finish, info_callback = {}, {}, {}, nil, nil, nil
local ui = {show=function(_, w) shown[#shown+1]=w; windows[w]=true end,
    close=function(_,w) windows[w]=nil end}
local widget = {new=function(_,opts) return opts end}
local function screen(opts)
    opts.kind="library_screen"
    function opts:closeForReplacement() ui:close(self) end
    function opts:onClose() self:closeForReplacement(); (self.on_back or self.on_close)() end
    return opts
end
local source={id="alpha",bookSourceName="甲站",bookSourceUrl="https://alpha.test",exploreUrl="玄幻::/sort/1"}
local book=Models.book(source,{name="测试书",author="作者",url="/book/1",intro="列表简介",coverUrl="/cover.jpg"})
local alternative=Models.book({id="beta",bookSourceName="乙站"},{name="测试书",author="作者",url="https://beta.test/1"})
local service={
    search=function(_,keyword,ids,page,callback,on_progress)
        A.equal("测试书",keyword,"name reaches aggregate service")
        A.equal(nil,ids,"search never requires selecting one source")
        finish,progress=callback,on_progress
        return {cancel=function() end}
    end,
    exploreCategories=function() return {{title="玄幻",url="/sort/1"},{title="动态榜单",error={code="UNSUPPORTED_RULE"}}} end,
    explore=function(_,id,index,page,callback)
        A.equal("alpha",id,"selected site reaches explore service")
        A.equal(1,index,"selected category reaches explore service")
        callback({groups={{book=book,alternatives={book}}},errors={}})
        return {cancel=function() end}
    end,
    getBookInfo=function(_,_,_,callback) info_callback=callback; return {cancel=function() end} end,
}
local storage={listSources=function() return {source} end,listShelf=function() return saved end,
    createBook=function(_,b) saved[#saved+1]=b; return b end,getProgress=function() end}
local presenter=Presenter.new({ui_manager=ui,menu=widget,input_dialog=widget,info_message=widget,library_screen_factory=screen})
local read_failure=true
local app=App.new({storage=storage,book_service=service,show=function(view) return presenter:show(view) end,
    reading_hook=function(_,_,_,callback)
        A.equal("library_screen", next(windows) and next(windows).kind, "reader keeps a plugin loading surface during preparation")
        if read_failure then callback(nil,{code="HTTP_ERROR"}) else callback({},nil) end
        return {}
    end})
presenter.app=app
presenter.detail_factory=function(b,alternatives) return app:createBookDetail(b,alternatives) end
local function last() return shown[#shown] end
local function action(label)
    for _,item in ipairs(last().actions or {}) do if item.text==label then return item.callback() end end
    for _,item in ipairs(last().items or {}) do if (item.text or item.title)==label then return item.callback() end end
    for _,item in ipairs(last().actions or {}) do if item.text=="更多" then item.callback(); return action(label) end end
    error("missing action: "..label)
end
app:openHome()
A.equal("library_screen",last().kind,"empty home is plugin fullscreen")
A.equal(3,#last().navigation,"home keeps three compact main destinations")
app:openSearch()
last().buttons[1][2].callback("测试书")
A.equal("library_screen",last().kind,"search starts directly with a results screen")
progress({groups={{book=book,alternatives={book,alternative}}},errors={},completed=1,total=2,succeeded=1,failed=0})
A.equal(1,#last().items,"early matches are visible before completion")
A.equal(2,last().items[1].source_count,"same title carries matching sources")
A.equal("列表简介",last().items[1].intro,"cards include introductions")
last().items[1].callback()
A.equal("detail",last().mode,"selecting a result opens independent details")
local detail=last()
finish({groups={},errors={},completed=2,total=2})
A.equal(detail,last(),"late search does not replace details")
info_callback(Models.book(source,{name="测试书",author="作者",url="/book/1",intro="完整简介",coverUrl="/cover.jpg"}))
A.equal("完整简介",last().items[1].intro,"detail metadata refreshes the card")
action("加入书架")
A.equal("完整简介",saved[1].intro,"plugin shelf persists full metadata")
action("开始阅读")
A.equal("detail",last().mode,"read failure restores actionable detail screen")
A.truthy(last().subtitle:find("HTTP_ERROR",1,true),"read failure shown inline")
read_failure=false
action("开始阅读")
A.equal(presenter.backdrop,next(windows),"successful reading retains only the session background below the reader")
app:openDiscovery()
last().items[1].callback()
A.equal("甲站",last().title,"site opens categories")
A.equal("玄幻",last().items[1].title,"real categories are listed")
A.equal(false,last().items[2].enabled,"unsupported category stays visible with status")
last().items[1].callback()
A.equal("cards",last().mode,"category opens cover and introduction cards")
A.equal("完整简介",last().items[1].intro,"cards reuse refreshed metadata")
last():onClose()
A.equal("甲站",last().title,"back returns to site categories")
local manager=require("legado.ui.source_manager").new({storage=storage})
app.source_manager=manager
app:openSources()
app:openSources()
A.equal(true,manager.alive,"reselecting source tab keeps singleton manager usable")
app:openBookshelf()
last().items[1].callback()
action("切换站点书源")
A.equal("library_screen",last().kind,"shelf source switching searches matching alternatives directly")
return 24
