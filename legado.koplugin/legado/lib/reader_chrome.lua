local Chrome = {}
Chrome.__index = Chrome
local defaults = require('legado.lib.settings').DEFAULTS

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end
local function call(object, method, ...)
    if not object or type(object[method]) ~= 'function' then return nil end
    local ok, value = pcall(object[method], object, ...)
    if ok then return value end
end
local function clean(value)
    return tostring(value or ''):gsub('[\r\n\t]', ' ')
end

function Chrome.progressText(footer)
    local fraction=tonumber(call(footer,'getChapterProgress',true))
    local percent=fraction and fraction==fraction and fraction>=0 and fraction<=1
        and string.format('%d%%',math.floor(fraction*100+.5)) or '—%'
    local ui=footer.ui or {}
    local left=tonumber(call(ui.toc,'getChapterPagesLeft',footer.pageno,true)
        or call(ui.document,'getTotalPagesLeft',footer.pageno))
    local remaining=left and left>=0 and call(ui.statistics,'getTimeForPages',left)
    return percent..' · '..(type(remaining)=='string' and remaining~='' and clean(remaining) or '时间待估算')
end

function Chrome.new(reader, settings, proxy)
    local device, Text, Font, UI = optional('device'), optional('ui/widget/textwidget'), optional('ui/font'), optional('ui/uimanager')
    if not (reader and reader.view and reader.view.registerViewModule and device and device.screen and Text and Font and UI) then return nil end
    return setmetatable({reader=reader, settings=settings, proxy=proxy, manager=UI, screen=device.screen,
        Text=Text, Font=Font, colors=optional('ffi/blitbuffer'), labels={}, closed=false}, Chrome)
end

function Chrome:setting(key)
    return call(self.settings, 'get', 'reader_corner_'..key) or defaults['reader_corner_'..key]
end

function Chrome:enabled(top)
    for _,key in ipairs(top and {'tl','tc','tr'} or {'bl','br'}) do
        if self:setting(key) ~= 'off' then return true end
    end
    return false
end

function Chrome:fontSize(top)
    return call(self.settings,'get',top and 'reader_header_font_size' or 'reader_footer_font_size') or 11
end

function Chrome:band(top)
    return math.ceil(self:fontSize(top)*1.5)+6
end

function Chrome:values()
    local r, proxy = self.reader, self.proxy
    local document = r.document
    local page = tonumber(call(r,'getCurrentPage')) or tonumber(r.paging and r.paging.current_page) or 1
    local pages = tonumber(call(document,'getPageCount')) or tonumber(r.paging and r.paging.number_of_pages) or 0
    local fraction = tonumber(call(proxy,'getProgressFraction')) or tonumber(call(r.rolling,'getLastPercent'))
        or tonumber(call(r.paging,'getLastPercent')) or (pages > 0 and page/pages or 0)
    fraction = math.max(0,math.min(1,fraction))
    local state = proxy and proxy.reading_state
    local book = state and state.book or proxy and proxy.book or {}
    local title = book.name or (r.doc_props and (r.doc_props.display_title or r.doc_props.title)) or (document and document.title)
    local chapter = state and state.chapters[state.index]
    local chapter_title = chapter and chapter.title or call(r.toc,'getTocTitleByPage',page)
    local progress
    if state then
        if state.catalog_complete == false or #state.chapters == 0 then progress = '目录加载中'
        else
            -- ponytail: chapter-weighted estimate; exact book pages require downloading and typesetting the entire novel.
            progress = string.format('约 %.1f%%', math.min(1,(state.index-1+fraction)/#state.chapters)*100)
        end
    else
        progress = string.format('%.1f%%',fraction*100)
        local chapter_pages = tonumber(call(r.toc,'getChapterPageCount',page))
        local done = tonumber(call(r.toc,'getChapterPagesDone',page))
        if chapter_pages and chapter_pages > 0 and done then page,pages=done+1,chapter_pages end
    end
    return {time=os.date('%H:%M'),title=clean(title),chapter=clean(chapter_title),
        chapter_page=pages>0 and string.format('%d/%d',math.max(1,math.min(page,pages)),pages) or '—/—',progress=progress,off=''}
end

function Chrome:paintTo(bb,x,y)
    if self.closed then return end
    local width,height = self.screen:getWidth(),self.screen:getHeight()
    local scale = function(n) return self.screen:scaleBySize(n) end
    local pad,top_band,band = scale(8),scale(self:band(true)),scale(self:band(false))
    local footer = self.reader.view.footer_visible and self.reader.view.footer
    local footer_height = tonumber(call(footer,'getHeight')) or 0
    if footer_height>0 then footer_height=footer_height+scale(4) end
    local values = self:values()
    local available = width-2*pad
    local quarter = math.floor(available/4)
    local positions = {
        tl={pad,0,quarter-pad,'left'},tc={pad+quarter,0,available-2*quarter,'center'},
        tr={width-pad-quarter,0,quarter,'right'},
        bl={pad,height-footer_height-band,math.floor(available*.7)-pad,'left'},
        br={pad+math.floor(available*.7),height-footer_height-band,available-math.floor(available*.7),'right'},
    }
    local color = self.reader.view.page_bgcolor or (self.colors and self.colors.COLOR_WHITE)
    for _,top in ipairs({true,false}) do
        if self:enabled(top) then bb:paintRect(x,y+(top and 0 or height-footer_height-band),width,top and top_band or band,color) end
    end
    for _,key in ipairs({'tl','tc','tr','bl','br'}) do
        local position = positions[key]
        local widget = self.labels[key]
        local top=key:sub(1,1)=='t'
        local font_size=self:fontSize(top)
        if widget and widget.legado_font_size~=font_size then widget:free();widget=nil end
        if not widget then
            widget = self.Text:new{text='',face=self.Font:getFace('cfont',font_size)}
            widget.legado_font_size=font_size
            self.labels[key] = widget
        end
        widget:setMaxWidth(position[3])
        widget:setText(values[self:setting(key)] or '')
        local size = widget:getSize()
        local offset = position[4]=='right' and position[3]-size.w or position[4]=='center' and math.floor((position[3]-size.w)/2) or 0
        widget.dimen = {x=x+position[1]+offset,y=y+position[2]+math.floor(((top and top_band or band)-size.h)/2),w=size.w,h=size.h}
        widget:paintTo(bb,widget.dimen.x,widget.dimen.y)
    end
end

function Chrome:refresh()
    if self.closed then return end
    local background=require('legado.lib.reader_background')
    background.apply(self.reader.document,self.settings)
    local typeset = self.reader.typeset
    if typeset and typeset.unscaled_margins and typeset.onSetPageMargins then typeset:onSetPageMargins(typeset.unscaled_margins) end
    local rolling = self.reader.rolling
    if self.native_header and rolling and rolling.onSetStatusLine then rolling:onSetStatusLine(self:enabled(true) and 1 or 0) end
    if self.manager.setDirty then self.manager:setDirty(self.reader,'ui') end
end

function Chrome:start()
    if self.started or self.closed then return self end
    self.started = true
    self.reader.view:registerViewModule('legado_chrome',self)
    local typeset = self.reader.typeset
    if typeset and typeset.onSetPageMargins then
        self.original_margins = typeset.onSetPageMargins
        self.apply_margins = function(instance,margins,...)
            local adjusted={margins[1],math.max(margins[2],self:enabled(true) and self:band(true) or 0),
                margins[3],math.max(margins[4],self:enabled(false) and (self:band(false)+(self.reader.view.footer_visible and 4 or 0)) or 0)}
            return self.original_margins(instance,adjusted,...)
        end
        typeset.onSetPageMargins = self.apply_margins
    end
    self.native_header = self.reader.rolling and self.reader.rolling.cre_top_bar_enabled
    self:refresh()
    self.tick = function()
        if self.closed then return end
        -- Do not refresh behind menus, the library or the screensaver.
        if call(self.manager,'getTopmostVisibleWidget') == self.reader then
            local Geom=optional('ui/geometry')
            if Geom then
                for _,keys in ipairs({{'tl','tc','tr'},{'bl','br'}}) do
                    local height=self.screen:scaleBySize(self:band(keys[1]=='tl'))
                    for _,key in ipairs(keys) do
                        if self:setting(key)=='time' then
                            local footer=self.reader.view.footer_visible and self.reader.view.footer
                            local footer_height=tonumber(call(footer,'getHeight')) or 0
                            if footer_height>0 then footer_height=footer_height+self.screen:scaleBySize(4) end
                            local y=keys[1]=='tl' and 0 or self.screen:getHeight()-footer_height-height
                            self.manager:setDirty(self.reader,'ui',Geom:new{x=0,y=y,w=self.screen:getWidth(),h=height})
                            break
                        end
                    end
                end
            end
        end
        if self.manager.scheduleIn then self.manager:scheduleIn(60,self.tick) end
    end
    if self.manager.scheduleIn then self.manager:scheduleIn(60,self.tick) end
    return self
end

function Chrome:close()
    if self.closed then return false end
    self.closed = true
    if self.manager.unschedule and self.tick then self.manager:unschedule(self.tick) end
    local view,typeset = self.reader.view,self.reader.typeset
    if view.view_modules and view.view_modules.legado_chrome==self then view.view_modules.legado_chrome=nil end
    if typeset and typeset.onSetPageMargins==self.apply_margins then typeset.onSetPageMargins=self.original_margins end
    for _,widget in pairs(self.labels) do widget:free() end
    return true
end

return Chrome
