-- Adapted from jnjnnjzch/leko-reader, 57dff8958dd43a5d95cb2dac22ca363d874de29b.
-- Upstream: AGPL-3.0-or-later. See phase3-core-interface.md for source mapping.
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")

local FontList = require("fontlist")

local FontSelectionView = Menu:extend{
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    modal = false,
    -- Let KOReader Menu paginate the complete face list. In particular, a TTC
    -- face is an item of its own and must not be hidden behind a second dialog.
    items_per_page = 12,
}

local SYSTEM_FONT = "cfont"
local SYSTEM_DISPLAY_NAME = "系统默认（简体中文优先）"

local function lower(value)
    return tostring(value or ""):lower()
end

local function addMetadata(value, output, depth)
    if depth > 3 then return end
    if type(value) == "string" or type(value) == "number" then
        output[#output + 1] = tostring(value)
        return
    end
    if type(value) ~= "table" then return end
    for key, item in pairs(value) do
        if type(key) == "string" then output[#output + 1] = key end
        addMetadata(item, output, depth + 1)
    end
end

local function metadataText(face)
    local values = {}
    if type(face) == "table" then
        addMetadata(face.name, values, 0)
        addMetadata(face.family_name, values, 0)
        addMetadata(face.style_name, values, 0)
        addMetadata(face.names, values, 0)
        addMetadata(face.langs, values, 0)
        addMetadata(face.scripts, values, 0)
    end
    return lower(table.concat(values, " "))
end

local function hasAny(value, patterns)
    for _, pattern in ipairs(patterns) do
        if value:find(pattern) then return true end
    end
    return false
end

local function filenameText(path)
    return lower(tostring(path or ""):gsub("^.*[\\/]", ""))
end

local function metadataString(value)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local localizedName

local function faceStyleName(face)
    if type(face) ~= "table" then return nil end
    local explicit = metadataString(face.style_name)
    if explicit then return explicit end
    -- KOReader currently exposes FreeType's bold/italic flags in fontinfo,
    -- but not FT_FaceRec.style_name. These are style metadata; a filename is not.
    if face.bold and face.italic then return "粗斜体" end
    if face.bold then return "粗体" end
    if face.italic then return "斜体" end
    return nil
end

local function faceStyleRank(face)
    if type(face) ~= "table" then return 1 end
    if face.bold and face.italic then return 4 end
    if face.italic then return 3 end
    if face.bold then return 2 end
    return 1
end

local function displayName(path, face_index, face)
    local name = localizedName(path, face_index, face)
    local style = faceStyleName(face)
    local names = { Regular = "常规", Bold = "粗体", Italic = "斜体", ["Bold Italic"] = "粗斜体" }
    style = names[style] or style
    if style and not lower(name):find(lower(style), 1, true) then
        name = name .. " — " .. style
    end
    return name
end

local function sortRank(path, face)
    local metadata = metadataText(face)
    local filename = filenameText(path)
    local simplified = {
        "zh[%s_%-]?hans", "zh[%s_%-]?cn", "simplified", "简体", "sc[%s_%-]?cn",
    }
    local traditional = {
        "zh[%s_%-]?hant", "zh[%s_%-]?tw", "zh[%s_%-]?hk", "traditional", "繁体", "tc[%s_%-]?tw",
    }
    local japanese = { "japanese", "jpan", "日本", "[%-_]ja[%-_ ]?" }
    local korean = { "korean", "kore", "한국", "[%-_]ko[%-_ ]?" }
    local generic_cjk = { "cjk", "han", "chinese", "中文", "zh" }

    -- FontList metadata is authoritative. Filename hints only fill in the
    -- common case where a vendor omitted language tags from the face record.
    if hasAny(metadata, simplified) then return 1, metadata end
    if hasAny(metadata, traditional) then return 2, metadata end
    if hasAny(metadata, japanese) then return 4, metadata end
    if hasAny(metadata, korean) then return 5, metadata end
    if hasAny(metadata, generic_cjk) then return 3, metadata end
    if hasAny(filename, simplified) then return 1, metadata end
    if hasAny(filename, traditional) then return 2, metadata end
    if hasAny(filename, japanese) then return 4, metadata end
    if hasAny(filename, korean) then return 5, metadata end
    if hasAny(filename, generic_cjk) then return 3, metadata end
    return 6, metadata
end

local function callFontList(method, ...)
    if type(FontList[method]) ~= "function" then return nil end
    local ok, result = pcall(FontList[method], FontList, ...)
    if ok then return result end
    ok, result = pcall(FontList[method], ...)
    if ok then return result end
    return nil
end

localizedName = function(path, face_index, face)
    local getter = FontList.getLocalizedFontName
    if type(getter) == "function" then
        local ok, name = pcall(getter, FontList, path, face_index)
        if not ok or type(name) ~= "string" or name == "" then
            ok, name = pcall(getter, path, face_index)
        end
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(face) == "table" then
        if type(face.name) == "string" and face.name ~= "" then return face.name end
        if type(face.family_name) == "string" and face.family_name ~= "" then
            return face.family_name
        end
    end
    local name = tostring(path or ""):gsub("^.*[\\/]", "")
        :gsub("%.[Tt][Tt][Ff]$", "")
        :gsub("%.[Tt][Tt][Cc]$", "")
        :gsub("%.[Oo][Tt][Ff]$", "")
        :gsub("%.[Cc][Ff][Ff]$", "")
        :gsub("%.[Ww][Oo][Ff][Ff]2?$", "")
    return name ~= "" and name or "未命名字体"
end

local function faceIndex(face, fallback)
    local value = type(face) == "table" and tonumber(face.index) or nil
    if value == nil then value = fallback end
    return math.max(0, math.floor(value or 0))
end

local function sameSelection(style, item)
    if item.system then return tostring(style.body_font or SYSTEM_FONT) == SYSTEM_FONT end
    return tostring(style.body_font or SYSTEM_FONT) == tostring(item.font_path)
        and (tonumber(style.body_font_index or 0) or 0) == (tonumber(item.face_index or 0) or 0)
end

local function containsSelection(style, item)
    if type(item.variants) == "table" then
        for _, variant in ipairs(item.variants) do
            if sameSelection(style, variant) then return true end
        end
        return false
    end
    return sameSelection(style, item)
end

function FontSelectionView.buildItems(style)
    style = style or {}
    local items = {
        {
            text = SYSTEM_DISPLAY_NAME,
            font_path = SYSTEM_FONT,
            face_index = nil,
            display_name = SYSTEM_DISPLAY_NAME,
            system = true,
            action = "select-font",
        },
    }
    local paths = callFontList("getFontList") or {}
    local faces = {}
    for path_index, path in ipairs(paths) do
        local info = type(FontList.fontinfo) == "table" and FontList.fontinfo[path] or nil
        if type(info) == "table" then
            for info_index, face in ipairs(info) do
                local index = faceIndex(face, info_index - 1)
                local base_display = localizedName(path, index, face)
                local display = displayName(path, index, face)
                local rank, metadata = sortRank(path, face)
                faces[#faces + 1] = {
                    text = display,
                    font_path = path,
                    face_index = index,
                    display_name = display,
                    action = "select-font",
                    sort_rank = rank,
                    sort_key = lower(base_display) .. string.format("\0%02d", faceStyleRank(face))
                        .. "\0" .. lower(display) .. "\0" .. lower(tostring(path))
                        .. string.format("\0%06d\0%06d", index, path_index),
                    metadata = metadata,
                }
            end
        end
    end

    table.sort(faces, function(left, right)
        if left.sort_rank ~= right.sort_rank then return left.sort_rank < right.sort_rank end
        return left.sort_key < right.sort_key
    end)
    local groups, group_order = {}, {}
    for _, face in ipairs(faces) do
        local key = lower(face.display_name)
        local group = groups[key]
        if not group then
            group = {
                text = face.display_name,
                display_name = face.display_name,
                action = "choose-font-path",
                variants = {},
            }
            groups[key] = group
            group_order[#group_order + 1] = group
        end
        group.variants[#group.variants + 1] = face
    end
    for _, group in ipairs(group_order) do
        if #group.variants == 1 then
            items[#items + 1] = group.variants[1]
        else
            items[#items + 1] = group
        end
    end

    local selection = 1
    for index, item in ipairs(items) do
        if containsSelection(style, item) then
            item.bold = true
            item.mandatory = "当前"
            selection = index
        end
    end
    return items, selection
end

local function getFace(path, size, index)
    local ok, face
    if index == nil then
        ok, face = pcall(Font.getFace, Font, path, size)
    else
        ok, face = pcall(Font.getFace, Font, path, size, index)
    end
    if ok and face then return face end
    return nil
end

function FontSelectionView.validateSelection(selection)
    if not selection or selection.system or selection.font_path == SYSTEM_FONT then
        return {
            font_path = SYSTEM_FONT,
            face_index = nil,
            display_name = SYSTEM_DISPLAY_NAME,
            system = true,
        }
    end
    local path = tostring(selection.font_path or "")
    local index = tonumber(selection.face_index or 0) or 0
    if path == "" then return nil, "字体路径为空" end
    if not getFace(path, 27, index) or not getFace(path, 34, index) then
        return nil, "字体文件无法加载"
    end
    return {
        font_path = path,
        face_index = math.max(0, math.floor(index)),
        display_name = tostring(selection.display_name or path),
        system = false,
    }
end

function FontSelectionView:getDisplayName(style)
    style = style or self.style or {}
    if tostring(style.body_font or SYSTEM_FONT) == SYSTEM_FONT then
        return SYSTEM_DISPLAY_NAME
    end
    if type(style.body_font_display_name) == "string" and style.body_font_display_name ~= ""
            and style.body_font_display_name ~= SYSTEM_DISPLAY_NAME then
        return style.body_font_display_name
    end
    local items = self.buildItems(style)
    for _, item in ipairs(items) do
        if containsSelection(style, item) then return item.display_name end
    end
    return tostring(style.body_font or SYSTEM_DISPLAY_NAME)
end

function FontSelectionView:init()
    self.title = "选择字体"
    self.title_bar_left_icon = "home"
    self.onLeftButtonTap = function() self:onReturn() end
    self.item_table, self.selection = self.buildItems(self.style)
    self.onMenuSelect = function(menu, item)
        if not item then return end
        if item.action == "choose-font-path" then
            self:showFontPaths(item)
            return
        end
        if item.action ~= "select-font" then return end
        local selection, err = FontSelectionView.validateSelection(item)
        if not selection then
            UIManager:show(Notification:new{ text = "字体不可用：" .. tostring(err or "无法加载") })
            return
        end
        UIManager:close(menu, "full")
        if type(self.on_selected) == "function" then self.on_selected(selection) end
        if type(self.on_return) == "function" then self.on_return() end
    end
    self.close_callback = function() return self:onReturn() end
    Menu.init(self)
    self:switchItemTable(self.title, self.item_table, self.selection)
end

function FontSelectionView:showFontPaths(group)
    self._path_group = group
    local items, selection = {}, 1
    local same_path_counts = {}
    for _, variant in ipairs(group.variants or {}) do
        local path = tostring(variant.font_path or "")
        same_path_counts[path] = (same_path_counts[path] or 0) + 1
    end
    for _, variant in ipairs(group.variants or {}) do
        local item = {}
        for key, value in pairs(variant) do item[key] = value end
        item.text = tostring(variant.font_path or "未知路径")
        if same_path_counts[item.text] > 1 then
            item.text = item.text .. "（字体面 " .. tostring((tonumber(item.face_index) or 0) + 1) .. "）"
        end
        if sameSelection(self.style or {}, item) then
            item.bold = true
            item.mandatory = "当前"
            selection = #items + 1
        end
        items[#items + 1] = item
    end
    self:switchItemTable("选择字体位置", items, selection)
end

function FontSelectionView:onReturn()
    if self._path_group then
        self._path_group = nil
        self.item_table, self.selection = self.buildItems(self.style)
        self:switchItemTable("选择字体", self.item_table, self.selection)
        return true
    end
    UIManager:close(self, "full")
    if type(self.on_return) == "function" then
        if type(UIManager.nextTick) == "function" then
            UIManager:nextTick(function() self.on_return() end)
        else
            self.on_return()
        end
    end
    return true
end

FontSelectionView.SYSTEM_FONT = SYSTEM_FONT
FontSelectionView.SYSTEM_DISPLAY_NAME = SYSTEM_DISPLAY_NAME

return FontSelectionView
