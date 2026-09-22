"""Exercise the statistics bridge with official LJSQLite3 and a native SQLite DB.

All databases are temporary. The user's KOReader statistics database is untouched.
Run: .tools/python/python.exe spec/native_koreader_statistics_test.py
"""
import hashlib
from contextlib import closing
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
from zipfile import ZipFile

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parent.parent
ARCHIVE = ROOT / '.tools/koreader-kindlehf-v2026.07.1.zip'
ARCHIVE_SHA = '3343a916d12f36c01b59df1f65bd83ff5616e6c2a4dfbe919e7fa1400b8b1bbb'


def create_database(path):
    source = (ROOT / '.tools/koreader/plugins/statistics.koplugin/main.lua').read_text(encoding='utf-8')
    book_schema = re.search(r'CREATE TABLE IF NOT EXISTS book\s*\(.*?\);', source, re.S).group()
    with closing(sqlite3.connect(path,isolation_level=None)) as db:
        db.executescript(book_schema)
        db.execute('CREATE UNIQUE INDEX book_title_authors_md5 ON book(title,authors,md5)')
        for name in ('STATISTICS_DB_PAGE_STAT_DATA_SCHEMA', 'STATISTICS_DB_PAGE_STAT_VIEW_SCHEMA'):
            db.executescript(re.search(r'local ' + name + r' = \[\[(.*?)\]\]', source, re.S).group(1))
        db.execute('PRAGMA user_version=20221111')


def main():
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == ARCHIVE_SHA
    with closing(sqlite3.connect(':memory:')) as db:
        version = db.execute('select sqlite_version()').fetchone()[0]
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().plugin_path = (ROOT / 'legado.koplugin/?.lua').as_posix()
    lua.globals().sqlite_library = str(Path(sys.executable).parent / 'DLLs/sqlite3.dll') if sys.platform == 'win32' else 'sqlite3'
    lua.globals().py_exists = lambda path: Path(path).is_file()
    with ZipFile(ARCHIVE) as archive:
        lua.globals().driver_source = archive.read('koreader/common/lua-ljsqlite3/init.lua').decode()
    lua.execute('''
        package.path=plugin_path..';'..package.path
        local ffi=require('ffi')
        ffi.cdef('void free(void *);')
        package.loaded['ffi/posix_h']=true
        ffi.loadlib=function(name) assert(name=='sqlite3');return ffi.load(sqlite_library) end
        package.loaded['lua-ljsqlite3/init']=assert(loadstring(driver_source,'@official-ljsqlite3'))()
        local loaded,module=pcall(require,'legado.lib.koreader_statistics')
        assert(loaded,'whole-book statistics bridge is available')
        Statistics=module
        now=1000
        function make(path)
            return Statistics.new{db_path=path,clock=function() return now end,
                file_exists=function(p) return py_exists(p) end,
                settings={is_enabled=true,min_sec=5,max_sec=120}}
        end
    ''')
    with tempfile.TemporaryDirectory(prefix='legado-native-statistics-') as directory:
        directory = Path(directory)
        path = directory / 'statistics.sqlite3'
        lua.globals().db_path = path.as_posix()
        lua.execute("local ok,err=make(db_path):start({id='missing'},1);assert(ok==nil and err.code=='STATISTICS_UNAVAILABLE')")
        assert not path.exists(), 'missing statistics DB must not be created'
        lua.execute("local b=make(db_path);b.store.file_exists=function() return true end;assert(b:start({id='removed-after-check'},1)==nil)")
        assert not path.exists(), 'rw open cannot create a DB removed after the existence check'
        create_database(path)
        for version_value in (20201010, 99999999):
            with closing(sqlite3.connect(path,isolation_level=None)) as db:
                db.execute(f'PRAGMA user_version={version_value}')
            before = path.read_bytes()
            lua.execute("local ok,err=make(db_path):start({id='schema'},1);assert(ok==nil and err.code=='STATISTICS_SCHEMA')")
            assert path.read_bytes() == before, 'unsupported schema must not be migrated or changed'
        with closing(sqlite3.connect(path,isolation_level=None)) as db:
            db.execute('PRAGMA user_version=20221111')
            db.execute('BEGIN IMMEDIATE')
            lua.execute("local ok,err=make(db_path):start({id='locked'},1);assert(ok==nil and err.code=='STATISTICS_ERROR')")
            assert db.execute('SELECT count(*) FROM book').fetchone()[0] == 0, 'lock failure creates no partial book'
            db.rollback()
        lua.execute('''
            b=make(db_path)
            book={id='source-book',name="Whole; 'book'\\0title",author="Author 'quoted'"}
            assert(b:start(book,2500,'stable-book'))
            native_id=b.statistics_id
            now=1010;assert(b:onPageChanged(3000))
            now=1030;assert(b:checkpoint())
        ''')
        with closing(sqlite3.connect(path,isolation_level=None)) as db:
            row = db.execute('SELECT title,authors,md5,total_read_time,total_read_pages FROM book').fetchone()
            assert row == ("Whole; 'book'\0title", "Author 'quoted'", hashlib.md5(b'legado-reader\0stable-book').hexdigest(), 30, 2)
            assert db.execute('SELECT count(*) FROM page_stat_data').fetchone()[0] == 2
            db.execute("CREATE TRIGGER reject_period BEFORE INSERT ON page_stat_data WHEN NEW.page=9000 BEGIN SELECT RAISE(ABORT,'write failure'); END")
        lua.execute('''
            now=1040;assert(b:onPageChanged(9000))
            now=1050;local ok,err=b:checkpoint()
            assert(ok==nil and err and b:status().pending==2,'transaction failure retains both periods')
        ''')
        with closing(sqlite3.connect(path,isolation_level=None)) as db:
            assert db.execute('SELECT count(*) FROM page_stat_data').fetchone()[0] == 2, 'failed transaction rolls back its first insert'
            assert db.execute('SELECT total_read_time FROM book').fetchone()[0] == 30
            db.execute('DROP TRIGGER reject_period')
        lua.execute('''
            assert(b:flush());assert(b:status().pending==0)
            assert(b.store:write(native_id,{{page=2500,start_time=1000,duration=10,total_pages=10000}},10000,1050,120))
            assert(b.store:write(native_id,{{page=2500,start_time=2000,duration=120,total_pages=10000}},10000,2000,120))
            now=1050;assert(b:pause())
            assert(b:start({id='different-source',name='Renamed book'},9000,'stable-book'))
            assert(b.statistics_id==native_id,'cross-chapter identity remains one native book')
            assert(b:close())
        ''')
        with closing(sqlite3.connect(path,isolation_level=None)) as db:
            assert db.execute('SELECT count(*) FROM book').fetchone()[0] == 1
            assert db.execute('SELECT count(*) FROM page_stat_data').fetchone()[0] == 5, 'retry cannot duplicate the period'
            assert db.execute('SELECT total_read_time,total_read_pages FROM book').fetchone() == (160, 3), 'totals match native per-page duration cap'
        malformed = directory / 'malformed.sqlite3'
        with closing(sqlite3.connect(malformed,isolation_level=None)) as db:
            db.executescript('CREATE TABLE book(id INTEGER); PRAGMA user_version=20221111;')
        lua.globals().bad_path = malformed.as_posix()
        before = malformed.read_bytes()
        lua.execute("local ok,err=make(bad_path):start({id='malformed'},1);assert(ok==nil and err.code=='STATISTICS_SCHEMA')")
        assert malformed.read_bytes() == before, 'missing fields must not trigger schema repair'
    print(f'Native SQLite {version}: statistics schema, bound values, identity, rollback, retry and native totals passed')


if __name__ == '__main__':
    main()
