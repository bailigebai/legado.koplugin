package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Adapter=require('legado.lib.leko_reader_ui')
local Reader=require('legado.ui.leko_reader')
local Text=require('legado.lib.leko_text')
local Paginator=require('legado.lib.leko_paginator')
local state={source={id='s1'},book={id='b',name='书'},chapters={{uid='c1',title='第一章'},{uid='c2',title='第二章'}},index=1}
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',120)..'</p>'
local settings={};local owner={ui_manager=h.ui,settings={get=function(_,key) return settings[key] end}}
local current=assert(Adapter.open(owner,{state=state,body=body,progress={immersive_style={page_transition='off'}}},{}))
owner.current_document=current;h.ui:show(current.widget)
local tasks=#h.tasks;local cursor=current:getPosition().char
local parse,make_page=Text.parse,Paginator.makePage
local parses,pages=0,0
Text.parse=function(...) parses=parses+1;return parse(...) end
Paginator.makePage=function(...) pages=pages+1;return make_page(...) end
assert(Adapter.prepare(owner,state,state.chapters[2],body))
eq(tasks+1,#h.tasks,'preparation adds one bounded index job and no clock or window')
eq(current.widget,h.shown,'preparation leaves the visible reader intact')
eq(cursor,current:getPosition().char,'preparation cannot change the current position')
eq(1,parses,'next chapter text is parsed once before switching')
eq(1,pages,'synchronous preparation computes only the first page')
assert(Adapter.prepare(owner,state,state.chapters[2],body))
eq(1,parses,'same body reuses its parsed text')
eq(1,pages,'same layout reuses its first page')
local prepared=owner.prepared_chapters[1].prepared
local options={source_id='s1',book=state.book,chapter=state.chapters[2],body=body,settings=owner.settings,style={page_transition='off'}}
options.style.body_font_size=36
local before=pages;local changed=assert(Reader.prepare(options,prepared))
eq(1,parses,'font changes reuse text without reparsing or fetching')
eq(before+1,pages,'font changes invalidate the first-page layout')
eq(36,changed.page.style.body_font_size,'candidate uses the new font size')
options.style.body_font='same-weight-other.ttf';before=pages
assert(Reader.prepare(options,changed))
eq(before+1,pages,'different fonts of the same weight invalidate layout')
options.style={page_transition='off'}
h.dimensions.w,h.dimensions.h=800,600;before=pages
changed=assert(Reader.prepare(options,prepared))
eq(before+1,pages,'screen rotation invalidates the prepared layout')
eq(800,changed.page.geometry.screen_width,'prepared page respects the current orientation')
h.dimensions.w,h.dimensions.h=600,800
settings.reader_header_font_size=20;before=pages
assert(Reader.prepare(options,prepared))
eq(before+1,pages,'header height changes invalidate prepared layout')
settings.reader_header_font_size=nil
options.body='<p>已更新的完整正文</p>';before=parses
changed=assert(Reader.prepare(options,prepared))
eq(before+1,parses,'body changes invalidate the parsed text')
eq('已更新的完整正文',changed.model.paragraphs[1],'changed body is rendered')
options.body=body;options.source_id='s2';before=parses
assert(Reader.prepare(options,prepared))
eq(before+1,parses,'a different source cannot reuse another source preparation')

local next_state={source=state.source,book=state.book,chapters=state.chapters,index=2}
local payload={state=next_state,body=body,progress={immersive_style=current:getReaderSettings()}}
local before_tasks=#h.tasks;local old_widgets=current.widget.widgets
local rejected=Adapter.open(owner,payload,{ready=function() return nil,{code='STORAGE_ERROR'} end})
eq(nil,rejected,'rejected state commit returns no candidate')
eq(before_tasks,#h.tasks,'rejected candidate releases all jobs')
eq(old_widgets,current.widget.widgets,'rejected state commit preserves the old page resources')
local painter=current.widget.background_painter
current.widget.background_painter=function() error('candidate paint failure') end
local broken,err=Adapter.open(owner,payload,{ready=function() error('unpaintable candidate must not be ready') end})
current.widget.background_painter=painter
eq(nil,broken,'candidate paint failure prevents the visible replacement')
eq('READER_ERROR',err.code,'candidate paint failure remains a reader error')
eq(old_widgets,current.widget.widgets,'unpaintable candidate preserves the old page')
eq(before_tasks,#h.tasks,'unpaintable candidate leaves no scheduled work')
before=pages;local before_parses=parses
local candidate=assert(Adapter.open(owner,payload,{}));owner.current_document=candidate
eq(before_parses,parses,'chapter open consumes prepared text')
eq(before,pages,'chapter open consumes the already prepared first page')
eq('c2',candidate:getPosition().chapter_uid,'candidate cursor belongs to the prepared chapter')
eq(true,current.closed,'accepted replacement detaches the old proxy')
eq(current.widget,candidate.widget,'accepted replacement keeps the active widget')
Text.parse,Paginator.makePage=parse,make_page
assert(candidate:close());eq(0,#h.tasks,'closing the current document cancels every owned task')
eq(0,#owner.prepared_chapters,'closing releases retained preparations')
local owner_ui=require('legado.lib.koreader_reader_ui').new{ui_manager=h.ui}
local first=assert(owner_ui:openChapter({state=state,body=body},{}))
local ready_count=0;local show=h.ui.show
h.ui.show=function() error('display refused') end
local other_state={source=state.source,book={id='other'},chapters=state.chapters,index=2}
local refused=owner_ui:openChapter({state=other_state,body=body},{ready=function() ready_count=ready_count+1;return true end})
eq(nil,refused,'new-window display failure rejects the candidate before session commit')
eq(0,ready_count,'failed display cannot commit a new reading state')
eq(first,owner_ui.current_document,'display failure preserves the active owner')
eq(false,first.closed,'display failure preserves the old readable document')
h.ui.show=show
local opened,new_document=pcall(owner_ui.openChapter,owner_ui,payload,{ready=function(document)
    document.animateEntry=function() error('entry animation failed') end
    return true
end})
eq(true,opened,'optional animation failures cannot unwind an accepted chapter commit')
eq(new_document,owner_ui.current_document,'accepted chapter remains current after animation failure')
eq('c2',new_document:getPosition().chapter_uid,'animation failure still displays the requested chapter')
new_document:close();eq(0,#h.tasks,'display failure and retry leave no candidate jobs')
do
    local owner_ui=require('legado.lib.koreader_reader_ui').new{ui_manager=h.ui}
    local current=assert(owner_ui:openChapter({state=state,body=body,progress={immersive_style={page_transition='off'}}},
        {save_style=function() return true end}))
    assert(owner_ui:prepareChapter(state,state.chapters[2],body));h:drain()
    local prepared=owner_ui.prepared_chapters[1].prepared
    local make=Paginator.makePage
    Paginator.makePage=function(self,book,...)
        if book.chapters[1].id=='c2' then error('temporary future layout failure') end
        return make(self,book,...)
    end
    assert(current.widget:applyStyle{body_font_size=38});h:drain()
    Paginator.makePage=make
    eq(0,owner_ui:getPreparedChapterStatus(state).first_pages,'failed reflow does not claim that stale first pages are ready')
    eq(false,prepared.layout_key==current.widget:getLayoutKey(),'failed reflow never relabels stale text layout as the new font')
    local retried=assert(owner_ui:openChapter({state=next_state,body=body,progress={immersive_style=current.widget.style}},{}))
    eq(38,retried.widget.page.style.body_font_size,'opening retries a failed background layout using the current font')
    local same=retried.widget
    local rejected=owner_ui:openChapter({state=state,body=body,background=function() error('changed background fails') end},{})
    eq(nil,rejected,'explicit changed backgrounds are validated before replacing the current page')
    eq(retried,owner_ui.current_document,'a rejected changed background preserves the current owner')
    eq(false,same.closed,'a rejected changed background keeps the old widget usable')
    retried:close()
end
for i=2,#h.buffers do eq(1,h.buffers[i].freed,'each native candidate buffer has one owner and one release') end
return n
