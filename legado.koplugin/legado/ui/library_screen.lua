local LibraryScreen = {}
local Safe = require("legado.lib.safe_functions")

local function optional(name)
    local ok, value = pcall(require, name)
    return ok and value or nil
end

local function dependencies(injected)
    injected = injected or {}
    return {
        focus = injected.focus or require("ui/widget/focusmanager"),
        button = injected.button or require("ui/widget/button"),
        horizontal = injected.horizontal or require("ui/widget/horizontalgroup"),
        vertical = injected.vertical or require("ui/widget/verticalgroup"),
        frame = injected.frame or require("ui/widget/container/framecontainer"),
        center = injected.center or require("ui/widget/container/centercontainer"),
        hspan = injected.hspan or require("ui/widget/horizontalspan"),
        vspan = injected.vspan or require("ui/widget/verticalspan"),
        image = injected.image or require("ui/widget/imagewidget"),
        text = injected.text or require("ui/widget/textwidget"),
        textbox = injected.textbox or require("ui/widget/textboxwidget"),
        scrolltext = injected.scrolltext or require("ui/widget/scrolltextwidget"),
        font = injected.font or require("ui/font"),
        ui = injected.ui or require("ui/uimanager"),
        device = injected.device or optional("device"),
        colors = injected.colors or require("ffi/blitbuffer"),
        geom = injected.geom or require("ui/geometry"),
        input = injected.input or require("ui/widget/container/inputcontainer"),
        gesture = injected.gesture or require("ui/gesturerange"),
    }
end

local function copy_events(events)
    local result = {}
    for name, value in pairs(events or {}) do result[name] = value end
    return result
end

function LibraryScreen.new(options)
    options = options or {}
    if options.reading_model and not options.custom_body then
        return require("legado.ui.reading_screen").new(options)
    end
    local deps = dependencies(options.dependencies)
    deps.ui = options.ui_manager or deps.ui
    local screen = deps.device and deps.device.screen
    local width = screen and screen:getWidth() or 600
    local height = screen and screen:getHeight() or 800
    local function scale(value) return screen and screen.scaleBySize and screen:scaleBySize(value) or value end
    local items, cells, layout, handles = options.items or {}, {}, {}, {}
    local mode = options.mode or ((items[1] and items[1].book) and "cards" or "list")
    local compact = options.compact == true
    local columns = mode == "grid" and (options.grid_columns or (compact and 4 or 3)) or 1
    local gap, margin = scale(compact and 4 or 6), scale(compact and 8 or 10)
    local content_width = width - margin * 2
    local cell_width = math.floor((content_width - gap * (columns - 1)) / columns)
    local cover_width = mode == "detail" and scale(150) or mode == "grid" and scale(compact and 96 or 76) or scale(110)
    local cover_height = mode == "detail" and scale(210) or mode == "grid" and scale(compact and 128 or 102) or scale(154)
    local closed = false
    local detail_intro, empty_widget

    local function face(size) return deps.font:getFace("cfont", size) end
    local function present(value, fallback)
        value = tostring(value or "")
        value = Safe.functions.htmldecode(value)
        return value:match("%S") and value or fallback
    end
    local function label(text, size, max_width, bold)
        return deps.text:new{ text = tostring(text or ""), face = face(size), max_width = max_width, bold = bold }
    end
    local function paragraph(text, size, box_width, box_height, lines)
        return deps.textbox:new{ text = tostring(text or ""), face = face(size), width = box_width,
            height = box_height, line_height = 0, height_overflow_show_ellipsis = true,
            lines_per_page = lines, alignment = "left" }
    end
    local function fixed(widget, box_width, box_height)
        return deps.center:new{ dimen = deps.geom:new{ w = box_width, h = box_height }, widget }
    end
    local function placeholder(box_width, box_height, text)
        return fixed(label(text or "无封面", 15, box_width - scale(4)), box_width, box_height)
    end
    local function cover_widget(path, box_width, box_height)
        if path then
            local image
            local ok = pcall(function()
                image = deps.image:new{ file = path, width = box_width, height = box_height, scale_factor = 0 }
                image:getSize() -- ImageWidget decodes lazily on first measurement.
            end)
            if ok then return fixed(image, box_width, box_height) end
            if image and type(image.free) == "function" then pcall(image.free, image) end
        end
        return placeholder(box_width, box_height, path and "封面不可用" or "无封面")
    end
    local function invoke(item)
        if item.enabled == false then return false end
        local ok, result = pcall(item.callback or options.on_select or function() return true end, item.book or item)
        if not ok then
            if options.on_error then pcall(options.on_error, result) end
            return false
        end
        return result
    end
    local function make_button(item, button_width, button_height)
        return deps.button:new{ text = tostring(item.title or item.text or "未命名"), width = button_width,
            height = button_height, enabled = item.enabled ~= false, avoid_text_truncation = false,
            text_font_size = compact and 15 or 20, text_font_bold = not compact,
            radius = scale(10), bordersize = compact and scale(1) or nil,
            background = item.active == true and deps.colors.COLOR_LIGHT_GRAY or nil,
            callback = function() return invoke(item) end }
    end
    local function reset(widget)
        if widget and type(widget.resetLayout) == "function" then widget:resetLayout() end
    end
    local function request_cover(book, callback)
        if not options.cover_loader then return end
        local ok, handle = pcall(options.cover_loader, book, function(path)
            if not closed then callback(path) end
        end)
        if ok and handle then handles[#handles + 1] = handle end
    end
    local body_rows = {}

    local function make_book_cell(item)
        local cover = cover_widget(nil, cover_width, cover_height)
        local visual, title, replace_cover
        local intro
        if mode == "detail" and compact then
            local inset = 2 * (scale(4) + scale(1))
            local inner_width = cell_width - inset
            local text_width = inner_width - cover_width - gap
            title = label(item.title or item.text or "未命名", 17, text_width, true)
            local meta = present(item.subtitle, "未知作者")
            if item.source_count then meta = meta .. " · " .. tostring(item.source_count) .. " 个来源" end
            local top = deps.horizontal:new{ cover, deps.hspan:new{ width = gap }, deps.vertical:new{
                title, label(meta, 13, text_width),
            } }
            intro = deps.scrolltext:new{ text = present(item.intro, "暂无简介"), face = face(14),
                width = inner_width, height = scale(280), scroll_by_pan = true, dialog = {} }
            detail_intro = intro
            visual = deps.vertical:new{ top, deps.vspan:new{ width = scale(6) }, intro }
            replace_cover = function(replacement) top[1] = replacement end
        elseif mode == "grid" and compact then
            local inset = 2 * (scale(4) + scale(1))
            local inner_width = cell_width - inset
            title = paragraph(item.title or item.text or "未命名", 13, inner_width, scale(32), 2)
            local cover_slot = fixed(cover, inner_width, cover_height)
            visual = deps.vertical:new{ cover_slot, deps.vspan:new{ width = scale(3) }, title }
            replace_cover = function(replacement) cover_slot[1] = replacement; reset(cover_slot) end
        else
            local frame_inset = 2 * (scale(5) + scale(1))
            local text_width = cell_width - frame_inset - cover_width - gap
            local intro_height = mode == "detail" and scale(compact and 176 or 112) or mode == "grid" and scale(38) or scale(62)
            title = label(item.title or item.text or "未命名", compact and 17 or mode == "grid" and 16 or 22,
                text_width, true)
            local meta = present(item.subtitle, "未知作者")
            if item.source_count then meta = meta .. " · " .. tostring(item.source_count) .. " 个来源" end
            intro = paragraph(present(item.intro, "暂无简介"), compact and 14 or mode == "detail" and 17 or mode == "grid" and 14 or 17,
                text_width, intro_height)
            local info = deps.vertical:new{
                title,
                label(meta, compact and 13 or mode == "detail" and 18 or mode == "grid" and 15 or 16, text_width),
                deps.vspan:new{ width = scale(3) },
                intro,
            }
            visual = deps.horizontal:new{ cover, deps.hspan:new{ width = gap }, info }
            replace_cover = function(replacement) visual[1] = replacement end
        end
        local framed = deps.frame:new{ padding = scale(compact and 4 or 5), bordersize = scale(1),
            radius = scale(8),
            color = compact and (mode == "grid" or mode == "detail") and deps.colors.COLOR_WHITE or nil,
            focus_border_size = compact and scale(1) or nil,
            focusable = not (compact and mode == "detail"), visual }
        local Card = deps.input:extend{}
        function Card:init()
            if not (compact and mode == "detail") then
                self.ges_events.TapSelect = { deps.gesture:new{ ges="tap", range=function() return self.dimen end } }
            end
        end
        function Card:onTapSelect() invoke(item); return true end
        function Card:onFocus() return framed:onFocus() end
        function Card:onUnfocus() return framed:onUnfocus() end
        local card = Card:new{ framed }
        if not (compact and mode == "detail") then card.callback = function() invoke(item); return true end end
        local cell = { item = item, visual = visual, button = card, title_widget = title,
            intro_widget = intro, frame = framed, cover = cover }
        cells[#cells + 1] = cell
        if options.cover_loader and item.book and (item.cover_url or item.book.is_local) then
            local function loaded(path)
                if closed then return end
                local replacement = cover_widget(path, cover_width, cover_height)
                local old = cell.cover
                replace_cover(replacement)
                cell.cover = replacement
                if old and type(old.free) == "function" then old:free() end
                reset(cell.visual)
                for _, row in ipairs(body_rows) do reset(row) end
                if deps.ui and type(deps.ui.setDirty) == "function" then deps.ui:setDirty(cell.frame, "ui") end
            end
            request_cover(item.book, loaded)
        end
        return card, card
    end

    if options.custom_body then
        -- Build after the header and footer have established the available height.
    elseif #items == 0 then
        empty_widget = paragraph(options.empty_text or "这里还没有内容", compact and 16 or 22,
            content_width - scale(40), scale(120))
        body_rows[1] = fixed(empty_widget,
            content_width, mode == "detail" and scale(300) or scale(360))
    elseif mode == "list" and (options.grid_columns or 1) > 1 then
        local list_columns = math.max(1, tonumber(options.grid_columns) or 2)
        for offset = 1, #items, list_columns do
            local visual_row, focus_row = {}, {}
            local count = math.min(list_columns, #items - offset + 1)
            local button_width = math.floor((content_width - gap * (count - 1)) / count)
            for index = offset, offset + count - 1 do
                local item = items[index]
                local button = make_button(item, button_width, scale(compact and 38 or 48))
                cells[#cells + 1] = { item = item, visual = button, button = button }
                visual_row[#visual_row + 1], focus_row[#focus_row + 1] = button, button
                if index < offset + count - 1 then visual_row[#visual_row + 1] = deps.hspan:new{width=gap} end
            end
            body_rows[#body_rows + 1] = deps.horizontal:new(visual_row)
            layout[#layout + 1] = focus_row
        end
    elseif mode == "list" then
        for _, item in ipairs(items) do
            local subtitle = present(item.subtitle, "")
            local title_width = subtitle ~= "" and math.floor(content_width * .62) or content_width
            local button = make_button(item, title_width, scale(compact and 36 or 48))
            local visual = button
            if subtitle ~= "" then
                visual = deps.horizontal:new{ button, deps.hspan:new{width=gap},
                    fixed(paragraph(subtitle, compact and 13 or 14, content_width-title_width-gap, scale(compact and 32 or 42)),
                        content_width-title_width-gap, scale(compact and 36 or 48)) }
            end
            cells[#cells + 1] = { item = item, visual = visual, button = button }
            body_rows[#body_rows + 1] = visual
            layout[#layout + 1] = { button }
        end
    else
        for offset = 1, #items, columns do
            local visual_row, focus_row = {}, {}
            for index = offset, math.min(offset + columns - 1, #items) do
                local visual, button = make_book_cell(items[index])
                visual_row[#visual_row + 1] = visual
                focus_row[#focus_row + 1] = button
                if index < math.min(offset + columns - 1, #items) then visual_row[#visual_row + 1] = deps.hspan:new{ width = gap } end
            end
            body_rows[#body_rows + 1] = deps.horizontal:new(visual_row)
            layout[#layout + 1] = focus_row
        end
    end

    local close_screen
    local back_button = deps.button:new{ text = "返回", width = scale(compact and 64 or 76),
        height = scale(compact and 36 or 42), text_font_size = compact and 15 or 20,
        text_font_bold = not compact, radius = scale(10),
        bordersize = compact and scale(1) or nil, callback = function() return close_screen(true) end }
    local back_size = back_button:getSize()
    local header_gap = scale(6)
    local header_action=options.header_action and make_button(options.header_action,scale(96),scale(36))
    local right_width=header_action and header_action:getSize().w or back_size.w
    local title_width = content_width - back_size.w - right_width - 2*header_gap
    local header_text = deps.vertical:new{
        label(options.title or "书源阅读", compact and 17 or 24, title_width),
        label(options.subtitle or "", compact and 13 or 14, title_width),
    }
    if options.progress then
        local ProgressWidget=require('ui/widget/progresswidget')
        table.insert(header_text,ProgressWidget:new{width=title_width,height=scale(10),percentage=options.progress})
    end
    local header_height = math.max(back_size.h, header_text:getSize().h)
    local header = deps.horizontal:new{ back_button, deps.hspan:new{ width = header_gap },
        fixed(header_text, title_width, header_height),
        deps.hspan:new{ width = header_gap }, header_action or deps.hspan:new{width=right_width} }
    table.insert(layout, 1, header_action and {back_button,header_action} or { back_button })

    local footer_rows, category_rows, category_buttons = {}, {}, {}
    local function controls(entries, max_columns, target_rows, insert_at)
        target_rows = target_rows or footer_rows
        for offset = 1, #(entries or {}), max_columns do
            local visual_row, focus_row = {}, {}
            local count = math.min(max_columns, #entries - offset + 1)
            local button_width = math.floor((content_width - gap * (count - 1)) / count)
            for index = offset, offset + count - 1 do
                local entry = entries[index]
                local button = make_button(entry, button_width, scale(compact and 36 or 42))
                visual_row[#visual_row + 1] = button
                focus_row[#focus_row + 1] = button
                if target_rows == category_rows then category_buttons[#category_buttons + 1] = button end
                if index < offset + count - 1 then visual_row[#visual_row + 1] = deps.hspan:new{ width = gap } end
            end
            target_rows[#target_rows + 1] = deps.horizontal:new(visual_row)
            if insert_at then
                table.insert(layout, insert_at, focus_row)
                insert_at = insert_at + 1
            else
                layout[#layout + 1] = focus_row
            end
        end
    end
    controls(options.categories, 4, category_rows, 2)
    local paging = {}
    if options.on_prev then paging[#paging + 1] = { text = "上一页", callback = options.on_prev } end
    if options.page_count then paging[#paging + 1] = { text = tostring(options.page or 1) .. "/" .. tostring(options.page_count), enabled = false } end
    if options.on_next then paging[#paging + 1] = { text = "下一页", callback = options.on_next } end
    if compact then
        controls(paging, 4)
        local commands = {}
        for _, entry in ipairs(options.actions or {}) do commands[#commands + 1] = entry end
        for _, entry in ipairs(options.navigation or {}) do commands[#commands + 1] = entry end
        controls(commands, math.max(1, #commands))
    else
        controls(options.actions, 4)
        controls(paging, 4)
        controls(options.navigation, 4)
    end

    local function spaced(rows)
        local widgets = {}
        for index, row in ipairs(rows) do
            widgets[#widgets + 1] = row
            if index < #rows then widgets[#widgets + 1] = deps.vspan:new{width=gap} end
        end
        return deps.vertical:new(widgets)
    end
    local categories = spaced(category_rows)
    local footer = spaced(footer_rows)
    local available_height = height - margin * 2
    local custom_body
    if options.custom_body then
        local body_height = available_height - header:getSize().h - scale(compact and 4 or 6)
            - categories:getSize().h - footer:getSize().h - gap
            - (#category_rows > 0 and gap or 0) - (#footer_rows > 0 and gap or 0)
        local focus_rows
        custom_body, focus_rows = options.custom_body{
            deps=deps, width=content_width, height=math.max(1,body_height), scale=scale,
            cover_widget=cover_widget, request_cover=request_cover, cells=cells,
        }
        body_rows[1] = custom_body
        local insert_at = 2 + #category_rows
        for _, row in ipairs(focus_rows or {}) do table.insert(layout,insert_at,row); insert_at=insert_at+1 end
    end
    local body = spaced(body_rows)
    local fixed_height = header:getSize().h + scale(compact and 4 or 6) + categories:getSize().h + body:getSize().h + footer:getSize().h
        + (#category_rows > 0 and gap or 0)
        + (#body_rows > 0 and gap or 0) + (#footer_rows > 0 and gap or 0)
    local spacer_height = math.max(0, available_height - fixed_height)
    local content = deps.vertical:new{ header, deps.vspan:new{width=scale(compact and 4 or 6)}, categories,
        deps.vspan:new{width=#category_rows > 0 and gap or 0}, body,
        deps.vspan:new{width=#body_rows > 0 and gap or 0}, deps.vspan:new{width=spacer_height}, footer,
        deps.vspan:new{width=#footer_rows > 0 and gap or 0} }
    local centered = deps.center:new{ dimen = deps.geom:new{ w = width, h = height },
        fixed(content, content_width, available_height) }
    local background = deps.frame:new{ padding = 0, bordersize = 0, background = deps.colors.COLOR_WHITE, centered }
    local Root = type(deps.focus.extend) == "function" and deps.focus:extend{} or deps.focus
    local widget = Root:new{ layout = layout, background }
    if detail_intro then detail_intro.dialog = widget end
    widget.kind, widget.items, widget.options, widget.cells = "library_screen", items, options, cells
    widget.covers_fullscreen=true
    widget.header, widget.category_buttons, widget.footer_rows, widget.alive = header, category_buttons, footer_rows, true
    widget.back_button, widget.empty_widget = back_button, empty_widget
    widget.grid_columns, widget.grid_rows, widget.detail_intro = columns, options.grid_rows or (compact and 3 or nil), detail_intro
    widget.body, widget.footer, widget.content, widget.content_height, widget.spacer_height = body, footer, content, available_height, spacer_height
    widget.reading_body = custom_body
    widget.key_events = copy_events(widget.key_events)
    if deps.device and type(deps.device.hasKeys) == "function" and deps.device:hasKeys()
        and deps.device.input and deps.device.input.group and deps.device.input.group.Back then
        widget.key_events.Close = { { deps.device.input.group.Back } }
    end
    local function cleanup()
        if closed then return false end
        closed, widget.alive = true, false
        for _, handle in ipairs(handles) do
            if type(handle.cancel) == "function" then pcall(handle.cancel, handle)
            elseif type(handle.free) == "function" then pcall(handle.free, handle) end
        end
        return true
    end
    close_screen = function(terminal)
        if closed then return false end
        if terminal and options.on_request_close and options.on_request_close() then return true end
        if deps.ui and type(deps.ui.close) == "function" then deps.ui:close(widget, "full") end
        if terminal and deps.ui and type(deps.ui.setDirty) == "function" then
            deps.ui:setDirty(nil, "full")
        end
        if not closed then cleanup() end
        if terminal then
            local callback = options.on_back or options.on_close
            if callback then
                -- KOReader removes the widget during this callback. Defer controller
                -- navigation one UI tick so the old catalog cannot repaint its shell.
                local function navigate() if not widget.alive then pcall(callback) end end
                if deps.ui and type(deps.ui.scheduleIn) == "function" then deps.ui:scheduleIn(0, navigate) else navigate() end
            end
        end
        return true
    end
    widget.onClose = function() return close_screen(true) end
    widget.closeForReplacement = function() return close_screen(false) end
    widget.onCloseWidget = cleanup
    return widget
end

return LibraryScreen
