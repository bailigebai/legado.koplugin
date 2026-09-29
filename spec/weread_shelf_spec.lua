local A = require("assertions")
local View = require("legado.ui.weread")
local Mapper = require("legado.lib.weread_mapper")
local Json = require("legado.lib.json_codec")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end
local saved, callback = nil, nil
local auth = { hasSession = function() return true end, session = function() return { vid = "account-1" } end }
local client = { shelfSync = function(_, done) callback = done; return { cancel = function() end } end }
local fs = { readBounded = function() return saved end,
    atomicWrite = function(_, _, value) saved = value; return true end }
local function make_view()
    return View.new{ auth = auth, client = client, fs = fs, path = "weread-shelf.json" }
end
local view = make_view()
eq(0, #view.books, "first login begins with an empty local shelf")
view:sync()
local rows, progress = {}, {}
for index = 1, 19 do
    rows[index] = { bookId = "b" .. index, title = "书" .. index,
        intro = "简介" .. index, cover = "https://cover.test/" .. index }
end
progress[1] = { bookId = "b19", progress = 50, updateTime = 500 }
callback({ books = rows, bookProgress = progress })
eq(19, #view.books, "all remote books are held in the WeRead shelf")
eq("b19", view.books[1].remote_id, "most recently read remote book leads")
eq(5, #view:page(1).items, "WeRead first page has a hero and four covers")
eq(12, #view:page(2).items, "WeRead second page has a three-by-four grid")
eq(2, #view:page(3).items, "remaining covers stay reachable")
eq(true, type(saved) == "string" and #saved > 0, "remote shelf is saved locally")
local restarted = make_view()
eq(19, #restarted.books, "offline restart restores the last synced shelf")
eq(500, restarted.books[1].read_at, "a new shelf snapshot keeps its verified reading time")
restarted:sync()
callback(nil, "network offline")
eq(19, #restarted.books, "network failure keeps the cached WeRead shelf")
local current_saved = saved
saved = Json.encode({account_id = "account-1", books = {
    {id = "legacy-first", remote_id = "legacy-first", source_id = "weread", name = "先读", read_at = 100},
    {id = "legacy-updated", remote_id = "legacy-updated", source_id = "weread", name = "只更新", read_at = 900},
}})
local legacy = make_view()
eq("legacy-first", legacy:page(1).items[1].remote_id,
    "a legacy shelf snapshot must not mistake book updates for newer reading")
saved = current_saved

do
    local pending, cancelled = {}, 0
    local repeated = View.new{ auth = auth, client = { shelfSync = function(_, done)
        pending[#pending + 1] = done
        return { cancel = function()
            cancelled = cancelled + 1
            done({ books = {{ bookId = "cancelled", title = "取消时回包" }} })
        end }
    end } }
    repeated:sync()
    repeated:sync()
    eq(1, cancelled, "starting a new shelf sync cancels the previous network request")
    pending[1]({ books = {{ bookId = "stale", title = "旧回包" }} })
    eq(0, #repeated.books, "late cancelled sync cannot replace the current shelf")
    pending[2]({ books = {{ bookId = "fresh", title = "新回包" }} })
    eq("fresh", repeated.books[1].remote_id, "the latest shelf sync still publishes its result")
    repeated:sync()
    repeated:cancel()
    eq(2, cancelled, "leaving the WeRead view cancels its active shelf sync")
    eq("fresh", repeated.books[1].remote_id, "a cancelled sync cannot replace the visible shelf")
end

local account, add_response, new_sync, add_error = "account-1", nil, nil, nil
local switched = View.new{auth={session=function() return {vid=account} end,hasSession=function() return true end},
    client={addToShelf=function(_, _, done) add_response=done;return {cancel=function() end} end,
        shelfSync=function(_, done) new_sync=done;return {cancel=function() end} end}}
switched:addToShelf({remote_id="old-book",name="旧账号书籍"},function(_,err) add_error=err end)
account="account-2"
add_response({errCode=0})
eq(nil,new_sync,"an account switch does not refresh the new account with an old addition")
eq(0,#switched.books,"an old account's book is not inserted into the new account shelf")
eq("微信读书账号已切换",add_error,"account switch is reported to the caller")
local pending_sync, sync_error
local switching = View.new{auth={session=function() return {vid=account} end,hasSession=function() return true end},
    client={shelfSync=function(_,done) pending_sync=done;return {cancel=function() end} end}}
switching:sync(function(_,err) sync_error=err end)
account="account-3"
pending_sync({books={{bookId="old-book",title="旧账号书籍"}}})
eq(0,#switching.books,"a late response cannot show books from a previous account")
eq("微信读书账号已切换",sync_error,"late shelf response reports the account change")
local Json = require("legado.lib.json_codec")
local active_account = "account-1"
local old_snapshot = Json.encode({account_id="account-1",books={{
    id="weread-old",remote_id="old-book",source_id="weread",name="旧账号书籍"}}})
local account_auth = {session=function() return {vid=active_account} end,
    hasSession=function() return true end}
local old_sync, sync_calls, switched_error
local private_view = View.new{auth=account_auth,path="private-shelf.json",
    fs={readBounded=function() return old_snapshot end,atomicWrite=function() return true end},
    client={shelfSync=function(_,done) old_sync=done;sync_calls=(sync_calls or 0)+1
        return {cancel=function() end} end}}
eq("old-book",private_view:page(1).items[1].remote_id,"the signed-in account sees its own cached shelf")
private_view:sync(function(_,err) switched_error=err end)
active_account="account-2"
eq(0,#private_view:page(1).items,"opening the shelf after an account switch hides old cached covers")
old_sync({books={{bookId="old-book",title="旧账号书籍"}}})
eq(0,#private_view:page(1).items,"a late response cannot restore old-account covers")
eq("微信读书账号已切换",switched_error,"the in-flight sync reports the account change")
private_view:sync()
eq(2,sync_calls,"the new account can start its own shelf sync")
old_sync({books={{bookId="new-book",title="新账号书籍"}}})
eq("new-book",private_view:page(1).items[1].remote_id,"the new account sees only its own synced shelf")
active_account=nil
account_auth.session=function() return nil end
account_auth.hasSession=function() return false end
eq(0,#private_view:page(1).items,"signing out clears the former account's covers")

active_account="account-1"
account_auth.session=function() return {vid=active_account} end
account_auth.hasSession=function() return true end
local old_add, add_sync_calls, switched_add_error
local private_add = View.new{auth=account_auth,path="private-shelf.json",
    fs={readBounded=function() return old_snapshot end},
    client={addToShelf=function(_,_,done) old_add=done;return {cancel=function() end} end,
        shelfSync=function() add_sync_calls=(add_sync_calls or 0)+1 end}}
private_add:addToShelf({remote_id="another-book",name="另一本书"},function(_,err) switched_add_error=err end)
active_account="account-2"
old_add({errCode=0})
eq("微信读书账号已切换",switched_add_error,"late add-to-shelf result reports the account switch")
eq(0,#private_add:page(1).items,"a late add-to-shelf result cannot leave old-account covers visible")
eq(nil,add_sync_calls,"a late add-to-shelf result does not sync the new account implicitly")
local recent_view = make_view()
recent_view:sync()
callback({books={{bookId="older",title="旧书"},{bookId="latest",title="最近读"}},
    recentBooks={{book={bookId="latest",title="最近读"},progress=48}}})
eq("latest",recent_view:page(1).items[1].remote_id,"the WeRead hero follows recent reading without a separate progress list")
eq(48,recent_view:page(1).items[1].progress_percent,"the hero retains embedded reading progress")
local failed_fs = { readBounded = function() return saved end,
    atomicWrite = function() return nil, {code = "STORAGE_ERROR"} end }
local failed_view = View.new{auth = auth, client = client, fs = failed_fs, path = "weread-shelf.json"}
local sync_result, sync_error
failed_view:sync(function(result, err) sync_result, sync_error = result, err end)
callback({books = {{bookId = "unsaved", title = "本次同步"}}})
eq("unsaved", failed_view.books[1].remote_id, "a storage failure keeps the freshly fetched shelf visible")
eq(nil, sync_result, "a shelf that could not be saved is not reported as fully synchronized")
eq("微信书架已更新，但本地保存失败；重启后可能恢复上次书架", sync_error,
    "storage failure is explained to the caller")
eq(sync_error, failed_view.status, "storage failure is visible on the shelf page")
eq(2, #make_view().books, "a failed write does not replace the previous local shelf")
failed_fs.atomicWrite = function(_, _, value) saved = value; return true end
failed_view:sync()
callback({books = {{bookId = "unsaved", title = "本次同步"}}})
eq("已登录", failed_view.status, "a successful manual retry clears the storage warning")
eq("unsaved", make_view().books[1].remote_id, "a successful retry persists the new shelf")
local pending_add, pending_shelf, added_result, added_warning
local add_client = {addToShelf = function(_, _, done) pending_add = done; return {cancel = function() end} end,
    shelfSync = function(_, done) pending_shelf = done; return {cancel = function() end} end}
local unsaved_add = View.new{auth = auth, client = add_client, fs = failed_fs, path = "weread-shelf.json"}
failed_fs.atomicWrite = function() return nil, {code = "STORAGE_ERROR"} end
unsaved_add:addToShelf({remote_id = "new-book", name = "新书"}, function(result, warning)
    added_result, added_warning = result, warning
end)
pending_add({errCode = 0})
pending_shelf(nil, "network offline")
eq(true, added_result, "remote addition remains successful when the local fallback cannot be saved")
eq("微信书架已更新，但本地保存失败；重启后可能恢复上次书架", added_warning,
    "an unsaved addition reports the restart risk")
eq(added_warning, unsaved_add.status, "an unsaved addition sets the shelf warning")
local synced_add = View.new{auth = auth, client = add_client, fs = failed_fs, path = "weread-shelf.json"}
synced_add:addToShelf({remote_id = "another-book", name = "另一本新书"}, function(result, warning)
    added_result, added_warning = result, warning
end)
pending_add({errCode = 0})
pending_shelf({books = {{bookId = "another-book", title = "另一本新书"}}})
eq(true, added_result, "remote addition succeeds even when sync persistence fails")
eq("微信书架已更新，但本地保存失败；重启后可能恢复上次书架", added_warning,
    "sync persistence failure is passed through the addition action")
local fallback_fs = {readBounded = function() return saved end,
    atomicWrite = function(_, _, value) saved = value; return true end}
local fallback_add = View.new{auth = auth, client = add_client, fs = fallback_fs, path = "weread-shelf.json"}
fallback_add:addToShelf(Mapper.book({bookId = "local-book", title = "离线回退"}, "account-1"), function(result, warning)
    added_result, added_warning = result, warning
end)
pending_add({errCode = 0})
pending_shelf(nil, "network offline")
eq(true, added_result, "remote addition remains successful when shelf refresh is temporarily offline")
eq("已加入微信书架，但完整书架同步失败；显示本地记录", added_warning,
    "a locally saved fallback reports the incomplete remote shelf refresh")
local fallback_restarted = make_view()
eq("local-book", fallback_restarted.books[#fallback_restarted.books].remote_id,
    "the locally saved addition survives a restart")
return count
