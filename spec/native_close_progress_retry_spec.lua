local A=require('assertions');local n=0
local function eq(a,b,m)n=n+1;A.equal(a,b,m)end
local Session=require('legado.lib.reader_session')
local chapters={{uid='c1',index=1,title='One',url='u'}}
local function fixture()
    local f={fail=false,saved={},opened=0}
    local session=Session.new{cache={readBody=function()return '<p>one</p>'end,writeHtml=function()return 'one.html'end},
        storage={getProgress=function()return {reading_bookmarks={{title='Keep me'}}}end,
            putProgress=function(_,progress)
                if f.fail then return nil,{code='STORAGE_ERROR',message='disk full'}end
                f.saved[#f.saved+1]=progress;return true
            end},settings={get=function()return 0 end},
        ui={openDocument=function(_,_,callbacks)
            f.opened=f.opened+1
            local doc={backend='native',getProgressFraction=function(self)
                assert(not self.closed,'must not inspect a released native document');return .77
            end}
            callbacks.ready(doc);f.callbacks=callbacks;return doc
        end}}
    assert(session:open({id='s'},{id='b',source_id='s'},chapters,1))
    f.session=session;f.state=session.active
    f.hostClose=function()
        f.fail=true;f.callbacks.close(f.state.document);f.state.document.closed=true
    end
    return f
end
local f=fixture();f.hostClose()
local ok,err=f.session:close()
eq(nil,ok,'plugin close cannot discard a failed native-close progress snapshot')
eq('STORAGE_ERROR',err.code,'pending native progress reports its persistence failure')
eq(f.state,f.session.active,'failed flush retains pending state for retry')
f.fail=false;assert(f.session:close())
eq(.77,f.saved[#f.saved].fraction,'recovered storage receives the captured final position')
eq('Keep me',f.saved[#f.saved].reading_bookmarks[1].title,'retry preserves other saved book fields')
eq(nil,f.session.active,'successful final flush can release the session')
f=fixture();f.hostClose()
ok,err=f.session:open({id='s'},{id='other',source_id='s'},chapters,1)
eq(nil,ok,'opening another book cannot silently discard pending native progress')
eq(1,f.opened,'new reader is not opened before the old snapshot is saved')
f.fail=false;assert(f.session:open({id='s'},{id='other',source_id='s'},chapters,1))
eq('b',f.saved[#f.saved].book_id,'saved snapshot still belongs to the closed book')
eq(2,f.opened,'reading can continue once persistence recovers')
f.session:close()
return n
