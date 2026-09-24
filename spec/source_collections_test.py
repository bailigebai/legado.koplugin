"""Opt-in tests for private source collections, using the real importer and SQLite.

Inputs stay outside the repository/package. Only hashes, counts and status are reported.
Files are staged in a temporary ASCII path because Windows Lua's io.open is not Unicode.
Usage: python spec/source_collections_test.py INPUT... --baseline older.json --report report.json
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time

from official_sqlite_test import native_runtime

SETUP = r'''
local Storage=require('legado.lib.storage')
local Importer=require('legado.lib.source_importer')
local Manager=require('legado.ui.source_manager')
local Fs=require('legado.lib.fs')
local Json=require('legado.lib.json_codec')
local fs=Fs.new()
local storage,manager,importer
local expected={}
local function checked(value,err)
    -- Do not print SQL or source headers from native error messages.
    assert(value, 'failed: '..tostring(type(err)=='table' and err.code or 'unknown'))
    return value
end
function reopen()
    if active_db then active_db:close();active_db=nil end
    storage=checked(Storage.new{path=db_path})
    assert(storage:backendName()=='sqlite','native SQLite required')
    active_db=storage.adapter.db
    importer=Importer:new{storage=storage,now=function() return 42 end}
    manager=Manager.new{storage=storage,importer=importer,fs=fs}
end
reopen()
checked(storage:createBook{id='saved-book',name='Existing book'})
checked(storage:putProgress('saved-book',{fraction=.42,reading_seconds=100}))
function verify()
    local saved=checked(storage:listSources())
    local count=0
    for _ in pairs(expected) do count=count+1 end
    assert(#saved==count,'source union count differs')
    for _,source in ipairs(saved) do
        assert(expected[source.id],'unexpected source')
        assert(Json.encode(source)==Json.encode(expected[source.id]),'persisted source fields differ')
    end
    assert(storage:getBook('saved-book').name=='Existing book','shelf changed')
    local progress=storage:getProgress('saved-book')
    assert(progress.fraction==.42 and progress.reading_seconds==100,'progress changed')
    assert(#manager:viewModel().sources==count,'UI omits saved sources')
    return count
end
function apply(path)
    local raw=checked(fs:read(path))
    local decoded=Json.decode(raw)
    local added,updated=0,0
    for _,member in ipairs(decoded) do
        local source=checked(importer:_normalize(member,path))
        local prior=expected[source.id]
        if prior then source.enabled=prior.enabled;updated=updated+1 else added=added+1 end
        expected[source.id]=source
    end
    local report=manager:importLocal(path)
    checked(not report.error,report.error)
    assert(report.rejected==0 and report.imported==added and report.updated==updated,'import counts differ')
    return {entries=#decoded,added=added,updated=updated,total=verify()}
end
function disable_first()
    local id=next(expected)
    checked(storage:updateSource(id,{enabled=false}))
    expected[id].enabled=false
end
function check_invalid()
    local report=manager:importLocal(db_path..'.missing')
    assert(report.error.code=='STORAGE_ERROR' and report.error.details.stage=='source_file_read')
    report=importer:importJson('[{"bookSourceName":"valid","bookSourceUrl":"https://invalid.test"},42]')
    assert(report.error.code=='INVALID_INPUT')
    verify()
end
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs',type=Path,nargs='+')
    parser.add_argument('--baseline',type=Path)
    parser.add_argument('--report',type=Path)
    args=parser.parse_args()
    files=[]
    for path in args.inputs:
        files.extend(sorted(path.rglob('*.json')) if path.is_dir() else [path])
    assert files,'no collections selected'
    results=[]
    with tempfile.TemporaryDirectory(prefix='legado-source-matrix-') as temporary:
        work=Path(temporary)
        staged=[]
        for index,file in enumerate(files):
            raw=file.read_bytes()
            path=work/f'collection-{index}.json'
            path.write_bytes(raw)
            staged.append((file,path,len(raw),hashlib.sha256(raw).hexdigest()))
        baseline=None
        if args.baseline:
            baseline=work/'baseline.json'
            baseline.write_bytes(args.baseline.read_bytes())
        for mode in ('individual','combined'):
            lua=None
            try:
                for index,(file,path,size,sha) in enumerate(staged):
                    if mode=='individual' or lua is None:
                        if lua: lua.execute('active_db:close();active_db=nil')
                        lua,_=native_runtime()
                        lua.globals().db_path=(work/f'{mode}-{index}.sqlite').as_posix()
                        lua.execute(SETUP)
                        if baseline and mode=='combined':
                            lua.globals().apply(baseline.as_posix())
                            lua.globals().reopen()
                    start=time.monotonic()
                    report=dict(lua.globals().apply(path.as_posix()))
                    lua.globals().reopen()
                    lua.globals().verify()
                    lua.globals().disable_first()
                    repeat=dict(lua.globals().apply(path.as_posix()))
                    assert repeat['added']==0
                    lua.globals().reopen()
                    lua.globals().verify()
                    lua.globals().check_invalid()
                    report.update(mode=mode,file=file.name,bytes=size,sha256=sha,status='PASS',
                                  seconds=round(time.monotonic()-start,2))
                    results.append(report)
                    print(json.dumps(report,ensure_ascii=True),flush=True)
            finally:
                if lua: lua.execute('if active_db then active_db:close();active_db=nil end')
    if args.report:
        args.report.write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'PASS: {len(files)} collections, first/repeat/reopen/field comparison/data preservation in both modes')


if __name__=='__main__':
    main()
