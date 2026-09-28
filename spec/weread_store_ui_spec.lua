require("library_screen_stub")
local A = require("assertions")
local Presenter = require("legado.ui.presenter")
local View = require("legado.ui.weread")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local shown, searched = {}, nil
local client = { search = function(_, keyword, _, callback)
    searched = keyword
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
return count
