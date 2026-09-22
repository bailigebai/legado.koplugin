local Categories={}
Categories.__index=Categories
local function invalid(message) return nil,{code='INVALID_INPUT',message=message} end
function Categories.new(storage,settings) return setmetatable({storage=storage,settings=settings},Categories) end
function Categories:list()
    local result,seen={},{}
    local function add(name) if type(name)=='string' and name~='' and not seen[name] then result[#result+1]=name;seen[name]=true end end
    for _,name in ipairs(self.settings:get('shelf_categories') or {}) do add(name) end
    local books,err=self.storage:listShelf()
    if err then return nil,err end
    for _,book in ipairs(books or {}) do for _,name in ipairs(type(book.custom_categories)=='table' and book.custom_categories or {}) do add(name) end end
    table.sort(result)
    return result
end
function Categories:add(name)
    name=tostring(name or ''):match('^%s*(.-)%s*$')
    if name=='' or #name>40 or name:find('%c') then return invalid('请输入一个分类名称（最多约 13 个汉字）。') end
    local names,err=self:list();if not names then return nil,err end
    for _,value in ipairs(names) do if value==name then return invalid('此分类已存在。') end end
    names[#names+1]=name
    local saved,save_error=self.settings:set('shelf_categories',names)
    return saved and name or nil,save_error
end
function Categories:remove(name)
    local names,err=self:list();if not names then return nil,err end
    -- Persist legacy book-only names before changing memberships, so a failed final
    -- registry write leaves the category available for an explicit retry.
    local registered,registry_error=self.settings:set('shelf_categories',names)
    if not registered then return nil,registry_error end
    local kept={};for _,value in ipairs(names) do if value~=name then kept[#kept+1]=value end end
    local books,read_error=self.storage:listShelf();if not books then return nil,read_error end
    local changed={}
    for _,book in ipairs(books) do
        local categories,found={},false
        for _,value in ipairs(type(book.custom_categories)=='table' and book.custom_categories or {}) do
            if value==name then found=true else categories[#categories+1]=value end
        end
        if found then book.custom_categories=categories;changed[#changed+1]=book end
    end
    if #changed>0 then local saved,save_error=self.storage:updateBooks(changed);if not saved then return nil,save_error end end
    -- A registry write failure leaves an empty category visible for retry, never deletes a book.
    local saved,save_error=self.settings:set('shelf_categories',kept)
    return saved and true or nil,save_error
end
return Categories
