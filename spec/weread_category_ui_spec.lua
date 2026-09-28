require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

local shown, calls = {}, {}
local client = {category = function(_, category_id, cursor, callback)
    calls[#calls + 1] = {id = category_id, cursor = cursor, callback = callback}
    return {cancel = function() end}
end}
local auth = {hasSession = function() return true end,
    session = function() return {vid = "account"} end}
local view = View.new{auth = auth, client = client}
view.synced = true
local presenter = Presenter.new{ui_manager = {show = function(_, widget) shown[#shown + 1] = widget end}}
presenter:show(view)
for _, action in ipairs(shown[#shown].actions) do
    if action.text == "书城发现" then action.callback(); break end
end
local rising
for _, item in ipairs(shown[#shown].items) do
    if item.text == "飙升榜" then rising = item end
end
eq("function", type(rising and rising.callback), "discovery page offers a live WeRead ranking")
rising.callback()
eq("rising", calls[1].id, "rising ranking requests the matching official category")
eq(0, calls[1].cursor, "first ranking page starts at zero")
local function batch(first, last)
    local books = {}
    for i = first, last do books[#books + 1] = {searchIdx = i,
        bookInfo = {bookId = "ranked-" .. i, title = "榜单书 " .. i}} end
    return books
end
calls[1].callback({books = batch(1, 20), hasMore = 1})
eq("微信书城 · 飙升榜", shown[#shown].title, "ranking results have their own book grid")
eq(12, #shown[#shown].items, "first ranking page shows 12 books")
shown[#shown].on_next()
eq("rising", calls[2].id, "ranking uses the same on-demand pagination")
eq(20, calls[2].cursor, "ranking cursor follows the last search index")
calls[2].callback({books = batch(21, 35), hasMore = 0})
eq("榜单书 13", shown[#shown].items[1].title, "second ranking page continues the real list")
return count
