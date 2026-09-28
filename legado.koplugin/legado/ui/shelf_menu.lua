local ShelfMenu = {}

local titles = {
    find = "找书",
    manage = "整理书架",
    sources = "书源与下载",
    more = "更多",
}

local function return_to_shelf(presenter, view, page)
    return function()
        if view.alive then return presenter:_shelf(view, page) end
        return presenter.app:openBookshelf(view.source_mode, {
            page = page, reading_state = view.reading_state, category = view.category,
            batch_select = view.batch_select, selected_books = view.selected_books,
        })
    end
end

local function category_menu(presenter, view, page)
    local model = view:page(page, "text", 12)
    local choices = {{text = "全部分类", callback = function()
        view:setFilter(view.reading_state, nil)
        return presenter:_shelf(view, 1)
    end}}
    for _, category in ipairs(model.categories or {}) do
        choices[#choices + 1] = {text = category.name, subtitle = tostring(category.count) .. " 本", callback = function()
            view:setFilter(view.reading_state, category.name)
            return presenter:_shelf(view, 1)
        end}
    end
    return presenter:_library(view, {title = "书架分类", items = choices, secondary = true,
        navigation = {}, subpage = "shelf_categories",
        on_back = function() return ShelfMenu.open(presenter, view, page, "manage") end})
end

local function batch_books(view)
    local selected, copies = view.selected_books or {}, {}
    for _, book in ipairs(view.storage and view.storage.listShelf and view.storage:listShelf() or {}) do
        if selected[book.id] then
            local copy = {}
            for key, value in pairs(book) do
                if key == "custom_categories" and type(value) == "table" then
                    local categories = {}
                    for index, name in ipairs(value) do categories[index] = name end
                    copy[key] = categories
                else
                    copy[key] = value
                end
            end
            copies[#copies + 1] = copy
        end
    end
    return copies
end

local function manage_items(presenter, view, page)
    local items = {}
    for _, entry in ipairs({{"全部", "all"}, {"在读", "reading"}, {"未读", "unread"}}) do
        items[#items + 1] = {text = entry[1], callback = function()
            view:setFilter(entry[2], view.category)
            return presenter:_shelf(view, 1)
        end}
    end
    items[#items + 1] = {text = "分类", callback = function() return category_menu(presenter, view, page) end}
    items[#items + 1] = {text = "编辑分类", callback = function()
        return presenter:_editCategories(return_to_shelf(presenter, view, page))
    end}
    if view.batch_select then
        items[#items + 1] = {text = "批量分类", callback = function()
            local books = batch_books(view)
            if #books == 0 then return presenter:_info("请先选择要分类的书籍。", "批量分类") end
            return presenter:_editCategories(return_to_shelf(presenter, view, page), nil, books)
        end}
        items[#items + 1] = {text = "退出批量选择", callback = function()
            view.batch_select, view.selected_books = false, {}
            return presenter:_shelf(view, page)
        end}
    else
        items[#items + 1] = {text = "批量选择", callback = function()
            view.batch_select, view.selected_books = true, view.selected_books or {}
            return presenter:_shelf(view, page)
        end}
    end
    return items
end

function ShelfMenu.open(presenter, view, page, group)
    local app, back = presenter.app, return_to_shelf(presenter, view, page)
    local items
    if group == "find" then
        items = {
            {text = "搜索", callback = function() return app:openSearch(nil, back) end},
            {text = "发现", callback = function() return app:openDiscovery(back) end},
            {text = "微信读书", callback = function() return app:openWeRead(back) end},
        }
    elseif group == "manage" then
        items = manage_items(presenter, view, page)
    elseif group == "sources" then
        items = {
            {text = "书源管理", callback = function() return app:openSources(back) end},
            {text = "缓存书籍", callback = function() return app:openDownloads(back, true) end},
            {text = "下载管理", callback = function() return app:openDownloads(back) end},
        }
    elseif group == "more" then
        items = {
            {text = "阅读回顾", callback = function() return app:openReadingReview(nil, nil, back) end},
            {text = "AI 服务", callback = function() return app:openSettings(nil,nil,back,'ai') end},
            {text = "插件缓存", callback = function() return app:openSettings(nil,nil,back,'cache') end},
            {text = "设置", callback = function() return app:openSettings(nil, nil, back) end},
            {text = "关于", callback = function() return app:openAbout(back) end},
            {text = "检查更新", callback = function() return presenter:_checkUpdates(view,page) end},
        }
    else
        return nil
    end
    return presenter:_library(view, {title = titles[group], items = items, secondary = true,
        navigation = {}, subpage = "shelf_" .. group, on_back = back})
end

function ShelfMenu.groups(presenter, view, page)
    local items = {}
    for _, group in ipairs({"find", "manage", "sources", "more"}) do
        items[#items + 1] = {text = titles[group], callback = function()
            return ShelfMenu.open(presenter, view, page, group)
        end}
    end
    return items
end

return ShelfMenu
