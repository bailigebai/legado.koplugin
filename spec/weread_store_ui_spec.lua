require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, searched, added, synced = {}, nil, nil, 0
local client = { search = function(_, keyword, _, callback)
    searched = keyword
    callback({ books = {{ bookId = "store-1", title = "发现的书", intro = "书城简介" }} })
    return { cancel = function() end }
end, addToShelf = function(_, book_id, callback)
    added = book_id
    callback({ errCode = 0 })
    return { cancel = function() end }
end, shelfSync = function(_, callback)
    synced = synced + 1
    callback({ books = {{ bookId = "store-1", title = "发现的书", intro = "书城简介" }} })
    return { cancel = function() end }
end }
local auth = { hasSession = function() return true end,
    session = function() return { vid = "account" } end }
local view = View.new{auth = auth, client = client}
view.synced = true
local presenter = Presenter.new{ui_manager = { show = function(_, widget) shown[#shown + 1] = widget end }}
presenter:show(view)
local store
for _, action in ipairs(shown[#shown].actions) do if action.text == "书城发现" then store = action end end
eq("function", type(store and store.callback), "WeRead shelf opens store discovery")
store.callback()
eq("微信书城", shown[#shown].title, "store discovery has a separate page")
local category
for _, item in ipairs(shown[#shown].items) do if item.text == "科幻" then category = item end end
eq("function", type(category and category.callback), "store offers a category")
category.callback()
eq("科幻", searched, "category reaches WeRead search")
eq("发现的书", shown[#shown].items[1].title, "store results appear as book cards")
shown[#shown].items[1].callback()
local add_action
for _, action in ipairs(shown[#shown].actions or {}) do
    if action.text == "加入微信书架" then add_action = action end
end
eq("function", type(add_action and add_action.callback), "store book can be added to the WeRead shelf")
add_action.callback()
eq("store-1", added, "the selected book is sent to the remote shelf")
eq(1, synced, "successful addition refreshes the WeRead shelf")
eq("已在微信书架", shown[#shown].actions[2].text, "added book cannot be added twice")
local failed_view = View.new{auth = auth, client = client, path = "weread-shelf.json",
    fs = {readBounded = function() return nil end, atomicWrite = function() return nil end}}
failed_view.synced = true
presenter:show(failed_view)
local failed_store
for _, action in ipairs(shown[#shown].actions) do
    if action.text == "书城发现" then failed_store = action end
end
failed_store.callback()
for _, item in ipairs(shown[#shown].items) do
    if item.text == "科幻" then item.callback(); break end
end
shown[#shown].items[1].callback()
local failed_add
for _, action in ipairs(shown[#shown].actions) do
    if action.text == "加入微信书架" then failed_add = action end
end
failed_add.callback()
eq("微信书架已更新，但本地保存失败；重启后可能恢复上次书架", shown[#shown].text,
    "the book detail shows a warning when a successful remote addition cannot be saved locally")
return count
