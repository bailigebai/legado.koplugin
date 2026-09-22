-- Shared side-table-of-contents model and KOReader overlay.
-- The model is intentionally usable without KOReader UI modules so catalog
-- paging and request cancellation remain testable on the host.
local SideToc={}
SideToc.__index=SideToc
SideToc.ACTIVATION_ZONE={ratio_x=.75,ratio_y=.0625,ratio_w=.25,ratio_h=.125}
function SideToc.isActivationTap(x,y,width,height)
    local zone=SideToc.ACTIVATION_ZONE
    return x>=width*zone.ratio_x and x<=width and y>=height*zone.ratio_y and y<=height*(zone.ratio_y+zone.ratio_h)
end

local function copy_item(item,index)
    if type(item)~='table' then return {title=tostring(item or ''),index=index} end
    local value={}
    for key,entry in pairs(item) do value[key]=entry end
    value.index=tonumber(value.index) or index
    value.position=index
    value.title=value.title or value.text or ('第 '..tostring(value.index)..' 章')
    value.text=value.text or value.title
    return value
end

local function identity(item,index)
    return tostring(item.uid or item.id or item.url or item.position or item.index or index)
end

function SideToc.new(options)
    options=options or {}
    local self=setmetatable({
        page_size=math.max(1,math.floor(tonumber(options.page_size) or 15)),
        items={},complete=options.complete==true,current_index=tonumber(options.current_index),
        page=math.max(1,math.floor(tonumber(options.page) or 1)),
        on_load_page=options.on_load_page,on_select=options.on_select,on_update=options.on_update,
        on_close=options.on_close,position=options.position=='right' and 'right' or 'left',
        tab='toc',tab_page=1,on_tab_items=options.on_tab_items,
        pending={},generation=0,closed=false,loading=false,error=nil,widget=nil,
    },SideToc)
    self:setItems(options.items or {},self.complete)
    if self.current_index then self.page=math.max(1,math.floor((self.current_index-1)/self.page_size)+1) end
    self:_clampPage()
    return self
end

function SideToc:_clampPage()
    local pages=self:pageCount()
    if self.page<1 then self.page=1 end
    if self.complete and self.page>pages then self.page=pages end
end

function SideToc:pageCount()
    local count=#self.items
    return math.max(1,math.ceil(count/self.page_size))
end

function SideToc:knownCount()
    return #self.items
end

function SideToc:isPageLoaded(page)
    return self.complete or #self.items>=page*self.page_size
end

function SideToc:pagination()
    if self.tab=='toc' then return self.page,self:pageCount(),not self.complete end
    return self.tab_page,math.max(1,math.ceil(#(self.tab_items or {})/self.page_size)),false
end

function SideToc:pageItems(page)
    page=math.max(1,math.floor(tonumber(page) or self.page))
    local first=(page-1)*self.page_size+1
    local values={}
    for index=first,math.min(#self.items,first+self.page_size-1) do
        local item=self.items[index]
        item.current=tonumber(item.index)==self.current_index
        values[#values+1]=item
    end
    return values
end

function SideToc:menuItems(page)
    if self.tab~='toc' then
        local items=self.tab_items or {}
        local values={}
        for i=(self.tab_page-1)*self.page_size+1,math.min(#items,self.tab_page*self.page_size) do values[#values+1]=items[i] end
        return #values>0 and values or {{text='暂无内容',enabled=false}}
    end
    page=math.max(1,math.floor(tonumber(page) or self.page))
    local values={}
    if not self:isPageLoaded(page) then
        if self.pending[page] then return {{text='正在加载本页目录…',title='正在加载本页目录…',enabled=false,loading=true}} end
        if self.error and self.error_page==page then return {{text='目录加载失败，点击重试',callback=function() self:requestPage(page) end}} end
    end
    -- Build only visible rows: paging cost stays bounded for long novels.
    for index=(page-1)*self.page_size+1,math.min(#self.items,page*self.page_size) do
        local item=self.items[index]
        local value=copy_item(item,index)
        value.current=tonumber(value.index)==self.current_index
        value.bold=value.current
        value._toc_absolute_index=index
        values[#values+1]=value
    end
    if not self.complete and #values<self.page_size then
        values[#values+1]={title='加载下一页目录…',text='加载下一页目录…',load_more=true,
            _toc_absolute_index=#values+1}
    end
    if #values==0 then values[1]={text='当前文档没有目录',enabled=false} end
    return values
end

function SideToc:switchTab(tab)
    if self.closed or not ({toc=true,bookmarks=true,fonts=true,config=true})[tab] then return false end
    if self.tab~=tab then self.tab_page=1 end
    self.tab=tab
    if tab~='toc' then
        local ok,items=pcall(self.on_tab_items or function()return {}end,tab,self)
        self.tab_items=ok and items or {{text='功能暂时不可用',enabled=false}}
        self.tab_page=math.min(self.tab_page,math.max(1,math.ceil(#self.tab_items/self.page_size)))
    end
    self:_notify();return true
end

function SideToc:setItems(items,complete)
    local by_key,order={},{}
    local function add(item,index)
        local value=copy_item(item,index)
        local key=identity(value,index)
        if not by_key[key] then order[#order+1]=key end
        by_key[key]=value
    end
    for index,item in ipairs(self.items or {}) do add(item,index) end
    for index,item in ipairs(items or {}) do add(item,index) end
    local merged={}
    for _,key in ipairs(order) do
        if by_key[key] then merged[#merged+1]=by_key[key] end
    end
    table.sort(merged,function(a,b)
        local ai,bi=tonumber(a.index) or 0,tonumber(b.index) or 0
        return ai==bi and tostring(a.title)<tostring(b.title) or ai<bi
    end)
    self.items=merged
    -- Catalog requests may finish out of order. Once the end is known,
    -- a shorter, older response must not reopen an infinite next page.
    self.complete=self.complete or complete==true
    if not self.error_page or self:isPageLoaded(self.error_page) then self.error,self.error_page=nil,nil end
    self:_clampPage()
    self:_notify()
    return true
end

function SideToc:_notify()
    if not self.closed and self.widget then self:refresh() end
    if self.closed or type(self.on_update)~='function' then return end
    pcall(self.on_update,self)
end

function SideToc:requestPage(page,preserve_page)
    if self.closed then return nil end
    page=math.max(1,math.floor(tonumber(page) or self.page))
    if not preserve_page then self.page=page;self.error=nil end
    if self:isPageLoaded(page) then self:_notify();return nil end
    if type(self.on_load_page)~='function' then return nil end
    if self.pending[page] then self:_notify();return self.pending[page] end
    local generation=self.generation
    local finished=false
    local function done(items,complete,err)
        if finished then return end
        finished=true
        if self.closed or generation~=self.generation then return end
        self.pending[page]=nil;self.loading=next(self.pending)~=nil
        -- A provider may use done(items, error) for an immediate failure.
        if type(complete)=='table' and err==nil then err,complete=complete,false end
        if err then
            if self.page==page and not self:isPageLoaded(page) then self.error,self.error_page=err,page end
            self:_notify()
            return
        end
        self:setItems(items or {},complete==true)
    end
    -- Install the sentinel before invoking the provider: test doubles and
    -- cache hits are allowed to call done synchronously.
    self.pending[page]=true
    self.loading=true
    self:_notify()
    local ok,handle=pcall(self.on_load_page,page,done)
    if not ok then done(nil,false,{code='REQUEST_ERROR',message=tostring(handle)})
    elseif not finished then
        self.pending[page]=handle or true
    end
    return self.pending[page]
end

-- Warm the next known page without moving the visible page. Opening the
-- drawer stays instant while the next page is fetched in the background.
function SideToc:prefetchNextPage()
    if self.closed or self.complete or #self.items < self.page_size then return nil end
    local page=self.page+1
    return self:requestPage(page,true)
end

function SideToc:nextPage()
    return self:goPage((self.tab=='toc' and self.page or self.tab_page)+1)
end
function SideToc:previousPage()
    if self.tab~='toc' then return self:goPage(self.tab_page-1) end
    if self.page<=1 then return false end
    self.page=self.page-1;self:_notify();return true
end
function SideToc:goPage(page)
    page=math.max(1,math.floor(tonumber(page) or self.page))
    if self.tab~='toc' then
        self.tab_page=math.min(page,math.max(1,math.ceil(#(self.tab_items or {})/self.page_size)))
        self:_notify();return true
    end
    if self.complete then page=math.min(page,self:pageCount()) end
    if page==self.page and page==1 then return self:requestPage(page) end
    self.page=page
    local needed=page*self.page_size
    if self.complete or #self.items>=needed then self:_notify();return true end
    return self:requestPage(page) or true
end
function SideToc:setCurrent(index)
    if self.current_index==tonumber(index) then return false end
    self.current_index=tonumber(index)
    self:_notify();return true
end
function SideToc:_actionError(err)
    self.error=type(err)=='table' and err or {code='READER_ERROR',message='操作失败，请稍后重试'}
    self.error_page=nil
    self:_notify()
    if self.widget and self.ui_manager then
        pcall(function()
            local Info=require('ui/widget/infomessage')
            self.ui_manager:show(Info:new{text=self.error.message or '操作失败，已保留原数据'})
        end)
    end
    return nil,self.error
end
function SideToc:_selectItem(item,completion)
    if self.closed then return nil end
    if item and item.enabled==false then return false end
    if item and item.callback then
        local ok,result,err=pcall(item.callback)
        if not ok or err then
            return self:_actionError(err or result)
        end
        return result
    end
    if not item or type(self.on_select)~='function' then return nil end
    local completed,completed_ok,completed_error=false,nil,nil
    local ok,result,provider_error=pcall(self.on_select,item,function(success,err)
        if self.closed or completed then return end
        completed,completed_ok,completed_error=true,success~=false,err
        if success==false or err then self:_actionError(err or {code='READER_ERROR',message='章节打开失败'}) end
        if completion then pcall(completion,success,err) end
    end)
    if not ok then return self:_actionError(result) end
    if result==nil and provider_error then
        if not completed then return self:_actionError(provider_error) end
        return nil,provider_error
    end
    if completed and not completed_ok then return nil,completed_error end
    if completed and completed_error then return nil,completed_error end
    -- Preserve an asynchronous navigation handle so the host progress
    -- surface can cancel it without cancelling the side panel itself.
    if not completed then return result end
    return result==false and nil or true
end
function SideToc:select(position,completion)
    local offset=(self.page-1)*self.page_size
    return self:_selectItem(self.items[offset+math.floor(tonumber(position) or 0)],completion)
end
function SideToc:isOpen()
    return not self.closed and self.widget~=nil
end
function SideToc:close()
    if self.closed then return false end
    self.closed=true;self.generation=self.generation+1;self.loading=false
    for _,handle in pairs(self.pending) do if type(handle)=='table' and handle.cancel then pcall(handle.cancel,handle) end end
    self.pending={}
    local page_button=self.menu and self.menu.page_info_text
    if page_button and page_button.input_dialog then
        local dialog=page_button.input_dialog;page_button.input_dialog=nil
        pcall(self.ui_manager.close,self.ui_manager,dialog)
    end
    -- Release the catalog snapshot with the overlay. Late transport
    -- callbacks are ignored by generation checks and must not repopulate it.
    self.items,self.tab_items={},nil
    local widget=self.widget;self.widget=nil
    if widget and widget._side_close then pcall(widget._side_close,widget) end
    if self.on_close then pcall(self.on_close,self) end
    return true
end

-- KOReader overlay is loaded lazily, keeping the pure model usable in specs.
function SideToc:show(managed)
    if self.closed then return nil end
    if self.widget then return self.widget end
    local ok,WidgetContainer=pcall(require,'ui/widget/container/widgetcontainer')
    local Menu=pcall(require,'ui/widget/menu') and require('ui/widget/menu') or nil
    local Button=pcall(require,'ui/widget/button') and require('ui/widget/button') or nil
    local VerticalGroup=pcall(require,'ui/widget/verticalgroup') and require('ui/widget/verticalgroup') or nil
    local HorizontalGroup=pcall(require,'ui/widget/horizontalgroup') and require('ui/widget/horizontalgroup') or nil
    local HorizontalSpan=pcall(require,'ui/widget/horizontalspan') and require('ui/widget/horizontalspan') or nil
    local InputContainer=pcall(require,'ui/widget/container/inputcontainer') and require('ui/widget/container/inputcontainer') or nil
    local LeftContainer=pcall(require,'ui/widget/container/leftcontainer') and require('ui/widget/container/leftcontainer') or nil
    local RightContainer=pcall(require,'ui/widget/container/rightcontainer') and require('ui/widget/container/rightcontainer') or nil
    local OverlapGroup=pcall(require,'ui/widget/overlapgroup') and require('ui/widget/overlapgroup') or nil
    local UIManager=pcall(require,'ui/uimanager') and require('ui/uimanager') or nil
    if not ok or not WidgetContainer or not Menu or not Button or not VerticalGroup
        or not InputContainer or not LeftContainer or not RightContainer or not OverlapGroup or not UIManager then
        return nil,{code='UI_ERROR',message='侧边目录界面不可用'}
    end
    local Device=require('device');local screen=Device.screen
    local Geom=require('ui/geometry');local width=math.floor(screen:getWidth()*.46)
    local header_height=math.max(40,screen:scaleBySize(42))
    local menu=Menu:new{item_table=self:menuItems(),width=width,height=screen:getHeight()-header_height,
        items_per_page=self.page_size,items_font_size=18,no_title=true,is_borderless=true,is_popout=false,single_line=true}
    local owner=self
    menu.onMenuSelect=function(menu_widget,item)
        if item and item.load_more then owner:requestPage(owner.page);return true end
        return owner:_selectItem(item)
    end
    menu.onMenuHold=function(_,item)
        if item and item.delete_callback then
            UIManager:show(require('ui/widget/confirmbox'):new{text='删除这个书签？',ok_callback=function()
                if not owner.closed then return owner:_selectItem({callback=item.delete_callback}) end
            end})
        end
        return true
    end
    menu.onNextPage=function() owner:nextPage();return true end
    menu.onPrevPage=function() owner:previousPage();return true end
    menu.onGotoPage=function(_,page) owner:goPage(page);return true end
    menu.onFirstPage=function() owner:goPage(1);return true end
    menu.onLastPage=function()
        local _,pages,incomplete=owner:pagination()
        if not incomplete then owner:goPage(pages) end
        return true
    end
    -- Events reach children first: the nested Menu must close its mounted
    -- drawer, not try to remove itself from UIManager's window stack.
    menu.onClose=function() owner:close();return true end
    menu.onCloseAllMenus=menu.onClose
    -- Menu only holds this page's rows, so its built-in search/page dialog
    -- cannot navigate the full catalog. Keep a bounded, numeric page action.
    local page_button=menu.page_info_text
    -- The stock footer reserves full-screen gaps. Budget the narrow panel
    -- explicitly so its buttons never overlap the uncovered reading area.
    local gap=screen:scaleBySize(4)
    menu.page_info_spacer.width=gap
    local arrows_width=menu.page_info_first_chev:getSize().w+menu.page_info_last_chev:getSize().w
        +menu.page_info_left_chev:getSize().w+menu.page_info_right_chev:getSize().w
    self.footer_page_width=math.max(1,width-arrows_width-4*gap-screen:scaleBySize(8))
    page_button.text_font_size=16
    page_button.avoid_text_truncation=false
    local function page_limit()
        local page,pages,incomplete=owner:pagination()
        return incomplete and math.max(page,pages+1) or pages
    end
    page_button.hold_input={title='跳转页码',input_type='number',
        input_func=function()return tostring((owner:pagination()))end,
        hint_func=function()return '1 – '..tostring(page_limit())end,
        buttons={{
            {text='取消',id='close',callback=function()page_button:closeInputDialog()end},
            {text='跳转',callback=function()
                local page=tonumber(page_button.input_dialog:getInputText())
                if page and page==math.floor(page) and page>=1 and page<=page_limit() then
                    page_button:closeInputDialog()
                    if not owner.closed then owner:goPage(page) end
                end
            end},
        }}}
    page_button.tap_input=page_button.hold_input
    local open_input=page_button.onInput
    page_button.onInput=function(button,...)
        if owner.closed then return true end
        open_input(button,...)
        local dialog=button.input_dialog
        local on_close=dialog.onCloseWidget
        dialog.onCloseWidget=function(instance,...)
            if button.input_dialog==instance then button.input_dialog=nil end
            if on_close then return on_close(instance,...) end
        end
    end
    self.menu=menu
    local header_items={}
    for _,entry in ipairs{{'目录','toc'},{'书签','bookmarks'},{'字体','fonts'},{'配置','config'}} do
        local tab=entry[2]
        header_items[#header_items+1]=Button:new{text=entry[1],width=math.floor((width-32)/4),height=header_height,
            text_font_size=16,bordersize=0,callback=function() owner:switchTab(tab) end}
    end
    local close=Button:new{text='×',width=32,height=header_height,bordersize=0,
        callback=function() owner:close() end}
    header_items[#header_items+1]=close
    local header=HorizontalGroup:new(header_items)
    local panel=VerticalGroup:new{align='left',header,menu}
    local PanelContainer=(self.position=='right' and RightContainer or LeftContainer)
    local content=OverlapGroup:new{dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()},
        allow_mirroring=false,PanelContainer:new{dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()},
            allow_mirroring=false,panel}}
    local container=InputContainer:new{dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()},content}
    if container.registerTouchZones then
        pcall(container.registerTouchZones,container,{{id='legado_side_toc_outside',ges='tap',screen_zone={
            ratio_x=self.position=='right' and 0 or width/screen:getWidth(),ratio_y=0,
            ratio_w=1-width/screen:getWidth(),ratio_h=1},handler=function() owner:close();return true end}})
    end
    container._side_close=function()
        if UIManager.close then
            local ok,err=pcall(UIManager.close,UIManager,container)
            if not ok then
                container._side_close_error=err
                -- A reduced host harness may not provide KOReader's
                -- DocSettings dependency. Remove only this window entry as
                -- a safe fallback; real KOReader takes the normal path.
                if type(UIManager._window_stack)=='table' then
                    for index=#UIManager._window_stack,1,-1 do
                        if UIManager._window_stack[index].widget==container then
                            table.remove(UIManager._window_stack,index)
                        end
                    end
                end
            end
        end
        if not container._side_freed then
            container._side_freed=true
            pcall(container.free,container)
        end
        owner.menu=nil
    end
    container.onClose=function()
        owner:close()
        -- Presenter-owned overlays normally receive CloseWidget from the
        -- UI manager. Keep direct onClose calls (used by KOReader widgets)
        -- on the same pause/resume path.
        if container.onCloseWidget then pcall(container.onCloseWidget,container) end
        return true
    end
    container.onCloseWidget=function() if not owner.closed then owner:close() end end
    self.widget,self.ui_manager=container,UIManager
    self.refresh_region=Geom:new{x=self.position=='right' and screen:getWidth()-width or 0,y=0,w=width,h=screen:getHeight()}
    if not managed then
        local shown=pcall(UIManager.show,UIManager,container)
        if not shown then self.widget=nil;return nil,{code='UI_ERROR',message='侧边目录显示失败'} end
    end
    self:refresh()
    return container
end

function SideToc:refresh()
    if self.closed then return false end
    if self.menu then
        pcall(self.menu.switchItemTable,self.menu,nil,self:menuItems(),1)
        local page,pages,incomplete=self:pagination()
        if self.menu.page_info_text and self.menu.page_info_text.setText then
            pcall(self.menu.page_info_text.setText,self.menu.page_info_text,
                tostring(page)..' / '..(incomplete and '…' or tostring(pages)),self.footer_page_width)
            self.menu.page_info_text:enableDisable(incomplete or pages>1)
        end
        if self.menu.page_info_right_chev and self.menu.page_info_right_chev.enableDisable then
            pcall(self.menu.page_info_right_chev.enableDisable,self.menu.page_info_right_chev,
                incomplete or page<pages)
        end
        if self.menu.page_info_left_chev and self.menu.page_info_left_chev.enableDisable then
            pcall(self.menu.page_info_left_chev.enableDisable,self.menu.page_info_left_chev,page>1)
        end
        self.menu.page_info_first_chev:enableDisable(page>1)
        self.menu.page_info_last_chev:enableDisable(not incomplete and page<pages)
        self.menu.page_info:resetLayout()
    end
    if self.widget and self.ui_manager then self.ui_manager:setDirty(self.widget,'ui',self.refresh_region) end
    return true
end

return SideToc
