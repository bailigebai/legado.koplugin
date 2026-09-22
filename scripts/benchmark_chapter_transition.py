"""Compare cached chapter CPU work using production Session/UI and mocked screen/fonts.
This is a reproducible host comparison, NOT Kindle/display/network latency.
"""
import argparse, json, os, tempfile, zipfile
from pathlib import Path
from lupa.luajit21 import LuaRuntime
ROOT=Path(__file__).resolve().parent.parent
LUA=r'''
local h=require('leko_reader_harness').install()
local Settings=require('legado.lib.settings')
local style={body_font_size=30,page_transition='off',chapter_clean_wave_enabled=false}
local settings={get=function(_,key) if key=='prefetch' then return 3 elseif key=='immersive_reader' then return true end;return Settings.DEFAULTS[key] end}
local progress={immersive_style=style}
local store={getProgress=function()return progress end,putProgress=function(_,value)progress=value;return true end}
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',180)..'</p>'
local chapters={};for i=1,45 do chapters[i]={uid='c'..i,title='第'..i..'章',index=i}end
local owner=require('legado.lib.koreader_reader_ui').new{settings=settings,ui_manager=h.ui}
local session=require('legado.lib.reader_session').new{cache={readBody=function()return body end},storage=store,
 ui=owner,service={getContent=function()error('cached benchmark must not access network')end},settings=settings,scheduler=h.ui}
assert(session:open({id='site'},{id='book',source_id='site',name='测试'},chapters,1,{backend='immersive'}));h:drain()
local function draw() session.active.document.widget:paintTo(h.screen.bb,0,0) end
draw()
local normal,cross,reused={},{},0
for i=1,40 do
 local widget=session.active.document.widget
 local start=os.clock();widget:nextPage();draw();normal[#normal+1]=(os.clock()-start)*1000
 start=os.clock();assert(session:navigate(i+1));draw();cross[#cross+1]=(os.clock()-start)*1000
 if widget==session.active.document.widget then reused=reused+1 end
 h:drain()
 h.ui._dirty={};h.refreshes={}
 local live={};for _,buffer in ipairs(h.buffers)do if buffer.freed==0 then live[#live+1]=buffer end end;h.buffers=live
 collectgarbage('collect')
end
session:close();h:drain()
local function stats(t)table.sort(t);return {p50_ms=t[20],p95_ms=t[38],max_ms=t[40]}end
return {ordinary=stats(normal),chapter=stats(cross),same_window=reused,samples=40,tasks_after_close=#h.tasks}
'''
def run(plugin):
    lua=LuaRuntime(unpack_returned_tuples=True)
    paths=[plugin/'?.lua',plugin/'?/init.lua',ROOT/'spec/?.lua',ROOT/'spec/phase3/?.lua']
    lua.execute('package.path='+json.dumps(';'.join(p.as_posix() for p in paths))+'..";"..package.path')
    def plain(v):
        return {k:plain(value) for k,value in v.items()} if hasattr(v,'items') else v
    return plain(lua.execute(LUA))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--baseline',type=Path);parser.add_argument('--output',type=Path)
    args=parser.parse_args();os.chdir(ROOT)
    report={'scope':'Host LuaJIT CPU, production controllers + mock font/framebuffer and memory storage; animations off; not Kindle latency','current':run(ROOT/'legado.koplugin')}
    if args.baseline:
        with tempfile.TemporaryDirectory(prefix='chapter-benchmark-',dir=ROOT/'.tools') as tmp:
            destination=Path(tmp).resolve()
            with zipfile.ZipFile(args.baseline) as archive:
                for info in archive.infolist():
                    if not info.filename.endswith('.lua') or not info.filename.startswith('legado.koplugin/'):continue
                    target=(destination/info.filename).resolve()
                    if not target.is_relative_to(destination):raise ValueError('unsafe archive path')
                    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.read(info))
            report['baseline']=run(destination/'legado.koplugin')
    result=json.dumps(report,ensure_ascii=False,indent=2)
    if args.output:args.output.write_text(result+'\n',encoding='utf-8')
    print(result)
if __name__=='__main__':main()
