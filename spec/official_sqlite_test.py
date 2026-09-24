"""Production importer/storage with KOReader's unchanged LJSQLite3 and native SQLite.

Run after check-koreader-compat.ps1; --collection adds the user's real JSON batch.
Only the platform library loader is replaced on Windows, never database methods.
"""
import argparse
import hashlib
from pathlib import Path
import sqlite3
import sys
import tempfile
from zipfile import ZipFile

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = ROOT / ".tools/koreader-kindlehf-v2026.07.1.zip"
ARCHIVE_SHA = "3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb"

CHECK = r'''
local Storage = require("legado.lib.storage")
local Importer = require("legado.lib.source_importer")
local Json = require("legado.lib.json_codec")
local function check(ok, err)
    -- Native exception messages can include full SQL/source credentials.
    local cause = type(err) == "table" and err.details and tostring(err.details.cause) or ""
    assert(ok, tostring(err) .. " [sqlite=" .. (cause:match("ljsqlite3%[([%w_]+)%]") or "unknown") .. "]")
    return ok
end
local function open()
    local storage, err = Storage.new({path=db_path})
    check(storage, err)
    assert(storage:backendName() == "sqlite", "must exercise native SQLite")
    active_db = storage.adapter.db
    return storage
end
local function import(storage, input)
    local report = Importer:new({storage=storage}):importJson(input, "https://sources.test/list.json")
    check(not report.error, report.error)
    return report
end
local storage = open()
-- Semicolons occur in JS, HTML entities, cookies, URLs and book text alike.
local source = {bookSourceUrl="https://sources.test/a;b?q='x'", bookSourceName="标点书源",
    ruleContent={content="@js: var text = '正文'; text;"}, header="Cookie: a=1; b=2"}
local report = import(storage, Json.encode({source}))
assert(report.imported == 1)
local saved = check(storage:getSource(source.bookSourceUrl))
assert(saved.ruleContent.content == source.ruleContent.content and saved.header == source.header)
local book = {id="book;'1", source_id=source.bookSourceUrl, name="书名; '引号'", intro="one\0two"}
check(storage:createBook(book))
assert(storage:getBook(book.id).intro == book.intro)
-- Category removal must commit all book assignments together.
check(storage:createBook({id="category-second",name="Second",custom_categories={"old"}}))
local first=storage:getBook(book.id)
first.custom_categories={"new"}
local put=storage.adapter.putBook
storage.adapter.putBook=function(self,value)
    if value.id=="category-second" then return nil,{code="STORAGE_ERROR"} end
    return put(self,value)
end
assert(not storage:updateBooks({first,{id="category-second",name="Second",custom_categories={}}}))
assert(storage:getBook(book.id).custom_categories==nil,"batch failure rolls back first book")
assert(storage:getBook("category-second").custom_categories[1]=="old")
storage.adapter.putBook=put
check(storage:updateBooks({first,{id="category-second",name="Second",custom_categories={}}}))
assert(storage:getBook(book.id).custom_categories[1]=="new")
check(storage:deleteBook("category-second"))
check(storage:putProgress(book.id, {updated_at=42, fraction=0.5,reading_seconds=90,
    reading_daily={["2026-09-11"]=30,["2026-09-12"]=60}}))
check(storage:replaceChapters(book.id, {{uid="ch;'1", title="第一章;", index=1}}))
assert(#storage:listChapters(book.id) == 1)
active_db:close()
storage = open()
assert(storage:getSource(source.bookSourceUrl).ruleContent.content == source.ruleContent.content)
assert(storage:getBook(book.id).name == book.name and storage:getProgress(book.id).fraction == 0.5)
local home = require("legado.ui.home").new({storage=storage})
assert(home.kind == "home" and home:page().recent[1].id == book.id, "home reads persisted reading progress")
home:close()
local History=require("legado.lib.reading_history")
local review=check(History.collect(storage))
assert(#storage:listProgress()==1 and review.total_seconds==90 and review.reading_days==2,
    "native SQLite lists and aggregates nested daily progress after reopen")
assert(review.records[1].book.name==book.name,"old progress inherits shelf metadata")
check(History.setReview(storage,book,"rating",4))
check(History.setReview(storage,book,"status","paused"))
active_db:close()
storage=open()
local receipt=History.book(book,storage:getProgress(book.id))
assert(receipt.rating==4 and receipt.status=="paused" and receipt.day_count==2,
    "native SQLite persists receipt fields without losing daily history")
assert(storage:getProgress(book.id).fraction==0.5,"receipt edits preserve reading position")

-- A database-enforced failure halfway through replacement must retain the old batch.
active_db:rowexec("CREATE TRIGGER reject_source BEFORE INSERT ON legado_v1_sources WHEN NEW.id='reject' BEGIN SELECT RAISE(ABORT,'test failure'); END")
local ok, err = storage:replaceSources({{id="first"}, {id="reject"}})
assert(not ok and err.code == "STORAGE_ERROR")
assert(#storage:listSources() == 1 and storage:getSource(source.bookSourceUrl))
active_db:rowexec("DROP TRIGGER reject_source")
assert(import(storage, Json.encode({source})).updated == 1, "rollback releases transaction")
local invalid = Importer:new({storage=storage}):importJson("invalid")
assert(invalid.error.code == "PARSE_ERROR" and #storage:listSources() == 1)
check(storage:deleteSource(source.bookSourceUrl))
assert(#storage:listSources() == 0)

if collection then
    local decoded = Json.decode(collection)
    local Manager = require("legado.ui.source_manager")
    local function manager()
        return Manager.new({storage=storage,importer=Importer:new({storage=storage}),fs=require("legado.lib.fs").new()})
    end
    report = manager():importLocal(' \n"'..collection_path..'"\r\n ')
    check(not report.error, report.error)
    assert(report.imported == #decoded)
    active_db:close()
    storage = open()
    assert(#storage:listSources() == #decoded, "all sources survive reopen")
    -- Compare every imported field, including nested rules, against the original.
    local function same(expected, actual)
        if type(expected) ~= "table" then assert(expected == actual); return end
        assert(type(actual) == "table")
        for key, value in pairs(expected) do same(value, actual[key]) end
    end
    local importer = Importer:new({storage=storage})
    for _, raw in ipairs(decoded) do
        local normalized = importer:_normalize(raw)
        local loaded = check(storage:getSource(normalized.id))
        normalized.imported_at = loaded.imported_at
        same(normalized, loaded)
    end
    local first_id = importer:_normalize(decoded[1]).id
    check(storage:updateSource(first_id,{enabled=false}))
    report = manager():importLocal(collection_path)
    check(not report.error, report.error)
    assert(report.imported == 0 and report.updated == #decoded)
    assert(#storage:listSources() == #decoded)
    assert(storage:getSource(first_id).enabled==false,"reimport preserves disabled source")
    report = manager():importLocal(collection_path..'.missing')
    assert(report.error.details.stage=='source_file_read' and #storage:listSources()==#decoded,
        "missing file never removes previous batch")
    assert(#manager():viewModel().sources == #decoded, "imported sources reach the production source-list model")
    checked_sources = #decoded
end
assert(storage:getBook(book.id).name == book.name, "source import preserves bookshelf")
active_db:close()
active_db = nil
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection", type=Path)
    parser.add_argument("--url", help="Fetch a live source collection (desktop HTTPS transport)")
    args = parser.parse_args()
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == ARCHIVE_SHA
    # Python initializes the bundled Windows SQLite DLL before LuaJIT loads it.
    with sqlite3.connect(":memory:") as db:
        version = db.execute("select sqlite_version()").fetchone()[0]
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.globals().plugin_path = (ROOT / "legado.koplugin/?.lua").as_posix()
    runtime.globals().sqlite_library = (
        str(Path(sys.executable).parent / "DLLs/sqlite3.dll") if sys.platform == "win32" else "sqlite3"
    )
    with ZipFile(ARCHIVE) as archive:
        runtime.globals().driver_source = archive.read("koreader/common/lua-ljsqlite3/init.lua").decode()
    runtime.execute('''
        package.path = plugin_path .. ';' .. package.path
        local ffi = require('ffi')
        ffi.cdef('void free(void *);')
        package.loaded['ffi/posix_h'] = true
        ffi.loadlib = function(name) assert(name == 'sqlite3'); return ffi.load(sqlite_library) end
        package.loaded['lua-ljsqlite3/init'] = assert(loadstring(driver_source, '@official-ljsqlite3'))()
    ''')
    if args.url or args.collection:
        if args.url:
            from urllib.request import urlopen
            with urlopen(args.url, timeout=20) as response:
                assert response.status == 200
                raw = response.read(5 * 1024 * 1024 + 1)
                assert len(raw) <= 5 * 1024 * 1024
                print(f"Live GET: HTTP {response.status}", flush=True)
        else:
            raw = args.collection.read_bytes()
        runtime.globals().collection = raw.decode("utf-8-sig")
        print(f"Collection: {len(raw)} bytes, SHA256 {hashlib.sha256(raw).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(prefix="legado-native-sqlite-") as directory:
        runtime.globals().db_path = Path(directory).as_posix() + "/legado.sqlite"
        if args.url or args.collection:
            collection_path = Path(directory) / "source collection.json"
            collection_path.write_bytes(raw)
            runtime.globals().collection_path = collection_path.as_posix()
        try:
            runtime.execute(CHECK)
        finally:
            runtime.execute("if active_db then active_db:close(); active_db=nil end")
    print(f"PASS: official LJSQLite3 / SQLite {version}: punctuation, NUL, reopen, rollback, retry, data preservation")
    if args.url or args.collection:
        print(f"PASS: {runtime.globals().checked_sources} sources saved, reopened, compared, reimported without duplicates")


if __name__ == "__main__":
    main()
