local Navigation = require("legado.ui.navigation")

local Catalog = {}
Catalog.__index = Catalog

function Catalog.new(chapters, cache_lookup, on_select)
    local items = {}
    for index, chapter in ipairs(chapters or {}) do
        items[index] = {
            chapter = chapter, index = chapter.index or index, position = index,
            title = chapter.title or ("第 " .. index .. " 章"),
            cached = type(cache_lookup) == "function" and cache_lookup(chapter) == true or false,
        }
    end
    return setmetatable({ kind = "catalog", items = items, on_select = on_select, reverse = false,
        navigation = Navigation.new({ count = #items, columns = 1 }) }, Catalog)
end

function Catalog:setOrder(reverse)
    reverse = reverse == true
    if reverse == self.reverse then return end
    local reversed = {}; for index = #self.items, 1, -1 do reversed[#reversed + 1] = self.items[index] end
    self.items, self.reverse = reversed, reverse
    self.navigation:setCount(#self.items)
end
function Catalog:onKey(key) return self.navigation:onKey(key) end
function Catalog:focused() return self.items[self.navigation:index()] end
function Catalog:select(position, callback)
    local item = self.items[tonumber(position) or 0]
    if not item or type(self.on_select) ~= "function" then return nil, { code = "INVALID_INPUT", message = "章节不可用" } end
    return self.on_select(item.chapter, item.position, callback or function() end)
end

return Catalog
