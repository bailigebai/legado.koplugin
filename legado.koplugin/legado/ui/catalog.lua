local Navigation = require("legado.ui.navigation")

local Catalog = {}
Catalog.__index = Catalog

function Catalog.new(chapters, cache_lookup)
    local items = {}
    for index, chapter in ipairs(chapters or {}) do
        items[index] = {
            chapter = chapter, index = chapter.index or index,
            title = chapter.title or ("第 " .. index .. " 章"),
            cached = type(cache_lookup) == "function" and cache_lookup(chapter) == true or false,
        }
    end
    return setmetatable({ kind = "catalog", items = items, navigation = Navigation.new({ count = #items, columns = 1 }) }, Catalog)
end

function Catalog:onKey(key) return self.navigation:onKey(key) end
function Catalog:focused() return self.items[self.navigation:index()] end

return Catalog
