-- Unmodified native ReaderUI lifecycle, Configurable, font and typeset handlers.
-- Rendering/widgets and chapter sidecars are desktop substitutes; the book-level
-- Storage uses its real atomic filesystem writer and is reopened from disk.
local h = require('native_library_harness').install()
local A = require('assertions')
local count = 0
local function eq(want, got, why) count=count+1; A.equal(want,got,why) end
local function noop() end
local function copy(value) return require('util').tableDeepCopy(value) end
local upstream = os.getenv('LEGADO_KOREADER_SOURCE') or '.tools/koreader'
local function native(file, first, last, env)
    local handle=assert(io.open(upstream..'/frontend/'..file,'rb'))
    local source=handle:read('*a');handle:close()
    local start=assert(source:find(first,1,true))
    local finish=last and assert(source:find(last,start+1,true)) or #source+1
    local chunk=assert(loadstring(source:sub(start,finish-1)))
    setfenv(chunk,env);chunk()
end
package.loaded['ffi/util']={template=function(text) return text end,orderedPairs=pairs}
package.loaded['libs/libkoreader-lfs']={attributes=function() return 'file' end}
package.loaded['dump']=function() return '' end
package.loaded['gettext']=setmetatable({pgettext=function(_,text) return text end},{__call=function(_,text) return text end})
package.loaded['ui/data/optionsutil']={}
package.loaded['legado.lib.reader_chrome']={new=function() end}
local LuaSettings=require('luasettings')
G_defaults=LuaSettings:wrap(dofile(upstream..'/defaults.lua'))
G_reader_settings=LuaSettings:wrap({})
G_reader_settings.flush=noop
h.screen.DEVICE_ROTATED_UPRIGHT=0
local CreOptions=require('ui/data/creoptions')
local Configurable=require('configurable')
local Event=require('ui/event')
local Widget=require('ui/widget/widget')
local Container=require('ui/widget/container/widgetcontainer')
local common=Widget:extend{}
local host=Container:extend{registerKeyEvents=noop}
local native_handle_event=host.handleEvent
local config=common:extend{init=function(self)
    self.options=CreOptions;self.configurable:loadDefaults(self.options)
end}
native('apps/reader/modules/readerconfig.lua','function ReaderConfig:onReadSettings(', 'return ReaderConfig',
    setmetatable({ReaderConfig=config},{__index=_G}))
local font=common:extend{updateFontFamilyFonts=noop,setupFaceMenuTable=noop}
local font_env=setmetatable({ReaderFont=font,Screen=h.screen,Event=Event},{__index=_G})
native('apps/reader/modules/readerfont.lua','function ReaderFont:onReadSettings(', 'function ReaderFont:onChangeSize(',font_env)
native('apps/reader/modules/readerfont.lua','function ReaderFont:onSaveSettings(', 'function ReaderFont:',font_env)
local typeset=common:extend{setBlockRenderingMode=noop,onSetPageMargins=function(self,margins)
    self.ui.document.margins=copy(margins)
end}
local typeset_env=setmetatable({ReaderTypeset=typeset},{__index=_G})
native('apps/reader/modules/readertypeset.lua','function ReaderTypeset:onReadSettings(', 'function ReaderTypeset:onReaderReady(',typeset_env)
native('apps/reader/modules/readertypeset.lua','function ReaderTypeset:onSaveSettings(', 'function ReaderTypeset:onToggleEmbeddedStyleSheet(',typeset_env)
local style=common:extend{updateCssText=noop,getCssText=function() return '' end}
local util=require('util');util.tableSize=function(t) local n=0;for _ in pairs(t) do n=n+1 end;return n end
native('apps/reader/modules/readerstyletweak.lua','function ReaderStyleTweak:onReadSettings(',
    'local function dispatcherRegisterStyleTweak(',setmetatable({ReaderStyleTweak=style,util=util,CssTweaks={DEFAULT_GLOBAL_STYLE_TWEAKS={}}},{__index=_G}))
local sidecars={}
local docsettings={open=function(_,file)
    local settings=LuaSettings:wrap(copy(sidecars[file] or {}))
    settings.data.doc_path=file
    settings.flush=function(self) sidecars[file]=copy(self.data) end
    return settings
end,saveSettingsArcFile=noop}
local env=setmetatable({ReaderUI=host,DocSettings=docsettings,Event=Event,
    Screen={getSize=function() return {} end,setWindowTitle=noop},
    Device={setIgnoreInput=noop,notifyBookState=noop},Input={inhibitInput=noop,inhibitInputUntil=noop},
    ReaderConfig=config,ReaderFont=font,ReaderTypeset=typeset,ReaderStyleTweak=style,
    ReaderActivityIndicator={isStub=function() return true end},
    ReaderRolling=common:extend{getLastPercent=function(self) return self.fraction or 0 end,
        onGotoPercent=function(self,n) self.fraction=n/100 end},
    FileManagerBookInfo=common:extend{extendProps=function(props) return props end},
    SettingsMigration={migrateSettings=noop},
    PluginLoader={loadPlugins=function() return {} end,finalize=noop},
    BookList={getBookStatusString=function() return 'reading' end,setBookInfoCache=noop,setBookInfoCacheProperty=noop},
    DocCache={serialize=noop},
    time={now=function() return 0 end,since=function() return 0 end,to_s=function(n) return n end},
    util={partialMD5=function() return 'checksum' end},
    logger={dbg=noop,info=noop,warn=noop,err=noop},UIManager=h.ui,
    InfoMessage={new=function(_,o) return o end},
},{__index=function(_,key) return _G[key] or common end})
package.loaded.readhistory={addItem=noop,updateLastBookTime=noop}
package.loaded.readcollection={updateLastBookTime=noop}
package.loaded['apps/filemanager/filemanager']={}
for _,range in ipairs{
    {'registerModule(','init('},{'init(','registerKeyEvents('},
    {'doShowReader(','unlockDocumentWithPassword('},
    {'saveSettings(','dealWithLoadDocumentFailure('},
} do native('apps/reader/readerui.lua','function ReaderUI:'..range[1],'function ReaderUI:'..range[2],env) end
local rendered={}
env.DocumentRegistry={openDocument=function(_,file)
    local doc={file=file,info={configurable=true},configurable=Configurable:new(),
        default_font='Default',default_css='default.css',header_font='Header',
        loadDocument=function() return true end,getPageCount=function() return 10 end,
        getProps=function() return {display_title=file} end,isEdited=function() return false end,
        setFontSize=function(self,n) self.font_size=n end,
        setGammaIndex=function(self,n) self.gamma=n end,
        render=function(self) rendered[file]={font_size=self.font_size,gamma=self.gamma,margins=copy(self.margins)} end,
        close=noop}
    return setmetatable(doc,{__index=function(_,key) if key:match('^set') then return noop end end})
end}
h.ui.close=function(_,reader)
    if reader.onFlushSettings then reader:onFlushSettings() end
    if reader.onCloseWidget then reader:onCloseWidget() end
end
h.ui.avoidFlashOnNextRepaint=noop
local queue={}
host.showReader=function(self,file,_,_,_,after)
    self.after_open_callback=after
    queue[#queue+1]=function() self:doShowReader(file,{},true) end
end
local function tick() local pending=queue;queue={};for _,fn in ipairs(pending) do fn() end end
local Adapter=require('legado.lib.koreader_reader_ui')
local Session=require('legado.lib.reader_session')
local Storage=require('legado.lib.storage')
local Fs=require('legado.lib.fs')
local disk_path=os.tmpname()
os.remove(disk_path)
local real_fs=Fs.new{lfs={}}
local fail_write=false
local disk_fs={read=function(_,path) return real_fs:read(path) end,atomicWrite=function(_,path,data)
    if fail_write then return nil,{code='STORAGE_ERROR',message='disk full'} end
    return real_fs:atomicWrite(path,data)
end}
local function storage(readback) return assert(Storage.new{path=disk_path,fs=readback and real_fs or disk_fs,sqlite_loader=function() end}) end
local cache={readBody=function() return '<p>chapter</p>' end,
    writeHtml=function(_,source,book,chapter) return book..'-'..chapter.uid..'.html' end,
    readCatalog=function() return {chapters={{uid='one',title='One'},{uid='two',title='Two'}},complete=true} end}
local diagnostics={}
local store=storage()
local function session()
    return Session.new{cache=cache,storage=store,ui=Adapter.new{ReaderUI=host},
        diagnostics=function(_,err) diagnostics[#diagnostics+1]=err end}
end
local s=session()
local chapters={{uid='one',title='One'},{uid='two',title='Two'}}
local book={id='book-a',source_id='site-a'}
local function open(current,index,options)
    assert(s:open({id=current.source_id},current,chapters,index,options));tick()
    assert(s.active and s.active.book.id==current.id,'reader activated')
    return s.active.document.reader
end
sidecars['book-a-one.html']={copt_font_size=26,copt_font_gamma=25,copt_h_page_margins={16,18},
    style_tweaks_enabled=false,book_style_tweak='p {color: black}',book_style_tweak_enabled=false,
    last_xpointer='chapter-one-position',bookmarks={{text='one'}},toc={title='one'},custom_metadata={title='one'}}
sidecars['book-a-two.html']={copt_font_size=14,copt_font_gamma=10,copt_h_page_margins={2,2},
    book_style_tweak='outdated',book_style_tweak_enabled=true,
    last_xpointer='chapter-two-position',bookmarks={{text='two'}},toc={title='two'}}
local reader=open(book,1)
eq(26,rendered['book-a-one.html'].font_size,'first open preserves existing chapter sidecar')
reader.document.configurable.font_size=34
reader.document.configurable.h_page_margins={22,24}
reader.document.configurable.font_gamma=0
reader.font.font_face='Book Font'
reader.styletweak.book_style_tweak=nil
reader.styletweak.book_style_tweak_enabled=false
reader.document.configurable.future_unknown='must not propagate'
reader.rolling.fraction=.75
reader:handleEvent(Event:new('EndOfBook'));tick()
eq(34,rendered['book-a-two.html'].font_size,'next chapter gets current font size before native render')
eq(0,rendered['book-a-two.html'].gamma,'zero contrast setting survives chapter switch')
eq(22,rendered['book-a-two.html'].margins[1],'left margin follows the book')
eq(24,rendered['book-a-two.html'].margins[3],'right margin follows the book')
reader=s.active.document.reader
eq('Book Font',reader.font.font_face,'font selection follows the book')
eq(false,reader.styletweak.enabled,'false style setting follows the book')
eq(nil,reader.styletweak.book_style_tweak,'removed style does not revive from old chapter sidecar')
eq(false,reader.styletweak.book_style_tweak_enabled,'false optional style value survives')
eq('chapter-two-position',reader.doc_settings:readSetting('last_xpointer'),'chapter location is not copied')
eq('two',reader.doc_settings:readSetting('bookmarks')[1].text,'chapter annotation is not copied')
eq('two',reader.doc_settings:readSetting('toc').title,'chapter TOC is not copied')
eq(0,reader.rolling:getLastPercent(),'new chapter does not inherit the previous chapter fraction')
eq(native_handle_event,host.handleEvent,'successful startup removes its temporary settings observer')
eq(nil,rawget(host,'handleEvent'),'successful startup restores native method inheritance')
local saved=assert(storage():getProgress(book.id)).reader_settings
eq(34,saved.copt_font_size,'new Storage instance reads font size from the actual disk path')
eq(nil,saved.last_xpointer,'shared snapshot excludes chapter positions')
eq(nil,saved.bookmarks,'shared snapshot excludes bookmarks')
eq(nil,saved.doc_path,'shared snapshot excludes document identity')
eq(nil,saved.copt_future_unknown,'snapshot allows native option names only')
eq(nil,saved.config_panel_index,'snapshot excludes config menu navigation state')
for _,panel in ipairs(CreOptions) do for _,option in ipairs(panel.options) do
    local key=option.name
    local value=reader.document.configurable[key]
    if value~=nil then
        local shared=saved['copt_'..key]
        eq(type(value),type(shared),'native bottom option is covered: '..key)
    end
end end
reader.document.configurable.font_size=38
reader=open(book,1) -- catalog jump closes/saves the previous native reader before loading settings
eq(38,reader.document.font_size,'catalog jump overrides a previously read chapter with the latest settings')
reader.document.configurable.font_size=40
reader:onFlushSettings()
eq(40,storage():getProgress(book.id).reader_settings.copt_font_size,'native flush persists current widget values')
reader:onClose()
store=storage();s=session()
assert(s:openOffline({id='site-a'},book,2));tick()
eq(40,s.active.document.reader.document.font_size,'offline reopen restores book-level settings from disk')
local other={id='book-b',source_id='site-a'}
reader=open(other,1)
eq(G_defaults:readSetting('DCREREADER_CONFIG_DEFAULT_FONT_SIZE'),reader.document.font_size,'another book keeps its own defaults')
reader.document.configurable.font_size=32
reader=open(book,2)
eq(40,reader.document.font_size,'returning to the first book restores its independent settings')
reader=open(other,2)
eq(32,reader.document.font_size,'returning to the second book restores its different settings')
eq(32,storage():getProgress(other.id).reader_settings.copt_font_size,'the second book also persists its own snapshot to disk')
reader=open(book,2)
eq(40,reader.document.font_size,'repeated book switches retain both sets of settings')
reader.document.configurable.font_size=42
local switched={id='book-new-site',source_id='site-b'}
reader=open(switched,1,{reader_settings_book_id=book.id})
eq(42,reader.document.font_size,'explicit source switch inherits the latest settings')
eq(nil,reader.doc_settings:readSetting('last_xpointer'),'source switch does not import a chapter xpointer')
reader.document.configurable.font_size=44
reader=open(switched,2)
eq(44,reader.document.font_size,'next chapter does not reload the older source snapshot')
reader:onClose();store=storage();s=session()
reader=open(switched,1)
eq(44,reader.document.font_size,'changed source settings survive closing and a fresh session')
local original_save=reader.config.onSaveSettings
reader.config.onSaveSettings=function() error('collection failed') end
local saved_ok,save_err=s:_save(s.active,s.active.document)
eq(nil,saved_ok,'failed native setting collection cannot report a successful save')
eq('reader_settings',save_err.details.stage,'native collection failure reports the settings stage')
eq(44,storage():getProgress(switched.id).reader_settings.copt_font_size,'collection failure retains the committed snapshot')
reader.config.onSaveSettings=original_save
local real_time=os.time
local now=real_time()
os.time=function(value) return value and real_time(value) or now end
local seconds_before=storage():getProgress(switched.id).reading_seconds or 0
s.active.started_at=now-12
reader.rolling.fraction=.67
fail_write=true
reader.document.configurable.font_size=46
reader.document:setFontSize(46)
local old_state=s.active
reader:handleEvent(Event:new('EndOfBook'));tick()
eq(old_state,s.active,'failed native progress save retains the old chapter state')
eq(reader,s.active.document.reader,'failed native progress save never opens a new reader')
eq(false,s.active.end_handled,'failed native progress save leaves chapter-end retry available')
eq(seconds_before+12,s.active.pending_progress.reading_seconds,'failed native save retains uncommitted reading time')
eq(46,s.active.document.reader.document.font_size,'a failed disk write retains current settings across the pending chapter')
eq(44,storage(true):getProgress(switched.id).reader_settings.copt_font_size,'failed persistence leaves the committed snapshot intact')
fail_write=false
now=now+7
reader:handleEvent(Event:new('EndOfBook'));tick()
eq(2,s.active.index,'restored storage allows the same native chapter-end action to retry')
eq(46,storage():getProgress(switched.id).reader_settings.copt_font_size,'a later flush retries the current snapshot')
eq(seconds_before+19,storage():getProgress(switched.id).reading_seconds,'native retry saves failed and subsequent reading time exactly once')
eq(.67,storage():getProgress(switched.id).fraction,'native retry preserves the original chapter progress')
os.time=real_time
reader=s.active.document.reader
reader.document.configurable.font_size=48
local catalog=require('legado.ui.app').new{reader_session=s}:openReadingCatalog(s.active,s.active.document)
fail_write=true
local result,selection_error=catalog:select(1)
tick()
eq(nil,result,'native catalog returns the progress-save failure')
eq('STORAGE_ERROR',selection_error and selection_error.code,'native catalog reports a structured storage error')
eq(2,s.active.index,'native catalog save failure retains its original chapter')
eq(reader,s.active.document.reader,'native catalog save failure retains its original reader')
fail_write=false
assert(catalog:select(1));tick()
eq(1,s.active.index,'native catalog can retry after storage recovers')
eq(48,s.active.document.reader.document.font_size,'catalog retry preserves the unsaved native layout')
s.active.document.reader:onClose()
-- Opening local files through the adapter has no book-settings callback.
sidecars['local.epub']={copt_font_size=30}
assert(Adapter.new{ReaderUI=host}:openDocument('local.epub'));tick()
eq(30,host.instance.document.font_size,'local files retain their own native sidecar')
host.instance:onClose()
local loads,failures=0,0
assert(Adapter.new{ReaderUI=host}:openDocument('failed.html',{
    read_settings=function() loads=loads+1;return nil,{code='STORAGE_ERROR'} end,
    failure=function() failures=failures+1 end,
}))
local unrelated=setmetatable({document={file='unrelated.html'},doc_settings=LuaSettings:wrap({copt_font_size=19})},{__index=host})
unrelated:handleEvent(Event:new('ReadSettings',unrelated.doc_settings))
eq(0,loads,'pending startup observer does not read settings for another document')
eq(19,unrelated.doc_settings:readSetting('copt_font_size'),'pending startup observer leaves another document untouched')
tick()
eq(1,loads,'matching native startup requests its book settings exactly once')
eq(1,failures,'settings read failure reaches the launch failure callback')
eq(native_handle_event,host.handleEvent,'failed startup removes its temporary settings observer')
eq(nil,rawget(host,'handleEvent'),'failed startup restores native method inheritance')
eq(nil,rendered['failed.html'],'unreadable book settings cannot silently render with defaults')
local native_statistics_ready=0
local StatisticsWidget=common:extend{name='statistics',onReaderReady=function() native_statistics_ready=native_statistics_ready+1 end}
env.PluginLoader.loadPlugins=function() return {StatisticsWidget} end
env.PluginLoader.createPluginInstance=function(_,module,options) return true,module:new(options) end
assert(Adapter.new{ReaderUI=host}:openDocument('novel-stats.html',{
    native_statistics=true,read_settings=function() return {} end,
}));tick()
eq(0,native_statistics_ready,'whole-novel bridge suppresses native per-chapter record during real ReaderReady')
host.instance:onClose()
assert(Adapter.new{ReaderUI=host}:openDocument('local-stats.epub'));tick()
eq(1,native_statistics_ready,'local books retain normal native statistics initialization')
host.instance:onClose()
os.remove(disk_path);os.remove(disk_path..'.old')
return count
