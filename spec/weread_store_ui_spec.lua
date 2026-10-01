require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, searched, added, synced, review_requests = {}, nil, nil, 0, 0
local client = { search = function(_, keyword, _, callback)
    searched = keyword
    callback({ books = {{ bookId = "store-1", title = "发现的书", intro = "书城简介" }} })
    return { cancel = function() end }
end, addToShelf = function(_, book_id, callback)
    added = book_id
    callback({ errCode = 0 })
    return { cancel = function() end }
end, bookReviews = function(_, _, callback)
    review_requests = review_requests + 1
    callback({reviews = {}})
    return {cancel = function() end}
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
local store_home = shown[#shown]
local category
for _, item in ipairs(shown[#shown].items) do if item.text == "科幻" then category = item end end
eq("function", type(category and category.callback), "store offers a category")
category.callback()
eq("科幻", searched, "category reaches WeRead search")
eq("发现的书", shown[#shown].items[1].title, "store results appear as book cards")
local results = shown[#shown]
local before_stale_home = #shown
for _, old_item in ipairs(store_home.items) do
    if old_item.text == "文学" then old_item.callback(); break end
end
eq("科幻", searched, "old store-home category cannot replace the active results")
eq(before_stale_home, #shown, "old store-home button does not reopen another results page")
presenter:_wereadStore(view)
local refreshed_results = shown[#shown]
results.items[1].callback()
eq(refreshed_results, shown[#shown], "older rendering of the same result page cannot open a book")
results = refreshed_results
shown[#shown].items[1].callback()
local detail_count = #shown
results.items[1].callback()
eq(detail_count, #shown, "old search-result cover cannot reopen a closed result page")
shown[#shown].header_action.callback()
local add_action
for _, action in ipairs(shown[#shown].items or {}) do
    if action.text == "加入微信书架" then add_action = action end
end
eq("function", type(add_action and add_action.callback), "store book can be added to the WeRead shelf")
add_action.callback()
eq("store-1", added, "the selected book is sent to the remote shelf")
eq(1, synced, "successful addition refreshes the WeRead shelf")
shown[#shown].header_action.callback()
eq("已在微信书架", shown[#shown].items[1].text, "added book cannot be added twice")
shown[#shown].on_back()
local finished_detail = shown[#shown]
finished_detail.on_back()
local returned_results = shown[#shown]
eq("微信书城 · 科幻", returned_results.title, "book detail returns to the store results")
for _, old_action in ipairs(finished_detail.actions) do
    if old_action.text == "开始阅读" then old_action.callback() end
end
finished_detail.header_action.callback()
eq(returned_results, shown[#shown], "old book-detail actions cannot replace the store results")
eq(0, review_requests, "old book-detail comments do not start a network request")
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
shown[#shown].header_action.callback()
for _, action in ipairs(shown[#shown].items) do
    if action.text == "加入微信书架" then failed_add = action end
end
failed_add.callback()
eq("微信书架已更新，但本地保存失败；重启后可能恢复上次书架", shown[#shown].text,
    "the book detail shows a warning when a successful remote addition cannot be saved locally")
return count
