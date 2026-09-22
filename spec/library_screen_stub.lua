-- Controller tests inject rendering; native_library_screen_spec executes upstream widgets.
local Screen={}
function Screen.new(input)
    local options={}
    for key,value in pairs(input) do options[key]=value end
    options.kind="library_screen"
    options.item_table={}
    for _,item in ipairs(options.items or {}) do
        item.text=item.text or item.title
        options.item_table[#options.item_table+1]=item
    end
    for _,action in ipairs(options.actions or {}) do options.item_table[#options.item_table+1]=action end
    if options.on_prev then options.item_table[#options.item_table+1]={text="上一页",callback=options.on_prev} end
    if options.on_next then options.item_table[#options.item_table+1]={text="下一页",callback=options.on_next} end
    function options:closeForReplacement()
        if self.closed then return false end
        self.closed=true
        if self.ui_manager and self.ui_manager.close then self.ui_manager:close(self) end
        return true
    end
    function options:onClose()
        if not self:closeForReplacement() then return false end
        return (self.on_back or self.on_close)()
    end
    options.close_callback=function() return options:onClose() end
    return options
end
package.loaded["legado.ui.library_screen"]=Screen
package.loaded['legado.ui.receipt_screen']={new=function(options)
    options.kind='receipt_overlay'
    function options:closeForReplacement()
        if self.closed then return false end
        self.closed=true
        if self.ui_manager then self.ui_manager:close(self) end
        return true
    end
    function options:onClose() if self:closeForReplacement() and self.on_back then return self.on_back() end end
    return options
end}
return Screen
