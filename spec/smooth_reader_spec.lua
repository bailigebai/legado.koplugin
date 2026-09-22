package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Reader=require('legado.ui.leko_reader')
local Adapter=require('legado.lib.koreader_reader_ui')
local book={id='smooth',name='顺畅阅读',source_id='source'}
local chapters={{uid='c1',title='一'},{uid='c2',title='二'},{uid='c3',title='三'},{uid='c4',title='四'},{uid='c5',title='五'}}
local body='<p>'..string.rep('甲乙丙丁戊己庚辛壬癸',120)..'</p>'
local function options(index)
    return {source_id='source',book=book,chapter=chapters[index],index=index,count=5,body=body,style={page_transition='off'}}
end

-- Rebuilding the same first-page text widgets on entry wastes the prepared work.
local view=assert(Reader.new(options(1)));h.ui:show(view)
local widgets=view.widgets
assert(view:animateEntry('forward',true))
eq(widgets,view.widgets,'entry animation reuses the already validated text widgets')
view:close()

-- Every idle callback is one page; prepared indices are adopted at open.
local prepared=assert(Reader.prepare(options(2)))
eq(1,#(prepared.page_starts or {}),'first-page preparation also records its canonical start')
local before=#prepared.page_starts
assert(Reader.prepareNextPage(prepared))
eq(before+1,#prepared.page_starts,'one preparation step adds exactly one page')
local open_options=options(2);open_options.prepared=prepared
view=assert(Reader.new(open_options))
eq(prepared.page_starts,view.page_starts,'opening adopts prepared page starts without restarting at page one')
local count=#view.page_starts;h:step()
eq(count+1,#view.page_starts,'active pagination resumes at the next unprepared page')
view:close()

-- Candidate paint and persistence failures must leave the live page/callbacks intact.
view=assert(Reader.new(options(1)));h.ui:show(view);h:drain()
local old_page,old_widgets,old_callbacks,old_clock=view.page,view.widgets,view.callbacks,view.clock_job
local next_options=options(2);next_options.callbacks={chapter=function() return 'new callback' end}
local next_prepared=assert(Reader.prepare(next_options))
local rejected,err=view:replaceChapter(next_options,next_prepared,function() return nil,{code='STORAGE_ERROR'} end)
eq(nil,rejected,'a failed commit rejects the candidate')
eq('STORAGE_ERROR',err.code,'commit error reaches the caller')
eq(old_page,view.page,'failed persistence retains the visible page')
eq(old_widgets,view.widgets,'failed persistence retains existing text resources')
eq(old_callbacks,view.callbacks,'failed persistence retains chapter callbacks')
local text_paint=require('ui/widget/textwidget').paintTo
require('ui/widget/textwidget').paintTo=function() error('candidate paint failed') end
local committed=false
rejected=view:replaceChapter(next_options,next_prepared,function() committed=true;return true end)
require('ui/widget/textwidget').paintTo=text_paint
eq(nil,rejected,'candidate drawing failure rejects the transition')
eq(false,committed,'drawing is validated before persistence/commit')
eq(old_page,view.page,'drawing failure keeps the old page')
assert(view:replaceChapter(next_options,next_prepared,function(candidate)
    eq('c2',candidate.chapter.uid,'commit sees the candidate chapter')
    eq('c1',view.chapter.uid,'live chapter remains unchanged until commit accepts')
    return true
end))
eq('c2',view.chapter.uid,'successful commit atomically replaces chapter content')
eq(next_options.callbacks,view.callbacks,'successful commit swaps chapter callbacks')
eq(old_clock,view.clock_job,'same-window replacement preserves the clock job')
eq(next_prepared.page_starts,view.page_starts,'replacement adopts all previously prepared page starts')
view:close()

-- Exercise both production adapters: a stale document must never operate the new chapter.
local owner=Adapter.new{settings={get=function() end},ui_manager=h.ui}
local function state(index) return {source={id='source'},book=book,chapters=chapters,index=index,catalog_complete=true} end
local function open(index,callbacks)
    local style=owner.current_document and owner.current_document:getReaderSettings() or {page_transition='off'}
    return owner:openChapter({state=state(index),body=body,progress={immersive_style=style}},callbacks or {})
end
local first=assert(open(1,{save_style=function() return true end}));h:drain();first:setProgressFraction(.3)
local old_position=first:getPosition();local active_widget=first.widget;local clock=active_widget.clock_job
local first_state=first.reading_state
for index=2,4 do assert(owner:prepareChapter(first_state,chapters[index],body)) end
eq(3,#owner.prepared_chapters,'all next three chapters retain independent preparation records')
eq(3,owner:getPreparedChapterStatus(first_state).first_pages,'prepared first-page count is separate from content cache count')
eq(0,owner:getPreparedChapterStatus(first_state).paginated,'first pages do not claim their full chapter indices are complete')
local next_record=owner.prepared_chapters[1].prepared
h:drain()
eq(true,next_record.complete,'idle work completes the canonical chapter index')
eq(3,owner:getPreparedChapterStatus(first_state).paginated,'idle preparation reports all complete chapter indices')
local prior_model=next_record.model
assert(first.widget:applyStyle{body_font_size=32})
eq(0,owner:getPreparedChapterStatus(first_state).first_pages,'changed typography invalidates previously prepared first pages immediately')
h:drain()
eq(3,owner:getPreparedChapterStatus(first_state).paginated,'idle work rebuilds future layouts after a font-size change')
next_record=owner.prepared_chapters[1].prepared
eq(prior_model,next_record.model,'layout invalidation retains parsed text')
local second=assert(open(2))
eq(active_widget,second.widget,'same-book cross-chapter navigation keeps the active full-screen widget')
eq(clock,second.widget.clock_job,'adapter does not restart the reader clock')
eq(next_record.page_starts,second.widget.page_starts,'adapter hands off the prepared index')
eq(true,first.closed,'the old document proxy is detached')
eq(old_position.char,first:getPosition().char,'detached proxy retains its own final position')
eq(false,first:setProgressFraction(.8),'detached proxy cannot change the new chapter')
first:close()
eq(false,second.widget.closed,'closing the detached proxy cannot dispose the shared widget')
eq('c2',second.widget.chapter.uid,'detached methods cannot mutate the new chapter')
local failed=open(3,{ready=function() return nil,{code='STORAGE_ERROR'} end})
eq(nil,failed,'adapter commit rejection is propagated')
eq(second,owner.current_document,'failed adapter commit retains the current document')
eq('c2',second.widget.chapter.uid,'failed adapter commit retains current chapter content')
local cancel_result
local cancelled=open(3,{ready=function(candidate) cancel_result=candidate:close();return true end})
eq(nil,cancelled,'closing a candidate during ready cancels the pending handoff')
eq(true,cancel_result,'candidate close succeeds without touching borrowed active resources')
eq(false,second.closed,'candidate cancellation does not detach the active document')
eq('c2',second.widget.chapter.uid,'candidate cancellation preserves the active chapter')
second:close()
eq(0,#h.tasks,'closing releases all pagination, preparation and clock jobs')
local previous_owner=Adapter.new{settings={get=function() end},ui_manager=h.ui}
local old=assert(previous_owner:openChapter({state=state(1),body=body,progress={immersive_style={page_transition='off'}}},{}))
h:drain();old:setProgressFraction(1)
local final_char=old:getPosition().char
assert(previous_owner:openChapter({state=state(2),body=body,progress={immersive_style={page_transition='off'}}},{}))
local backward=state(1);backward.restore_fraction=1
local previous=assert(previous_owner:openChapter({state=backward,body=body,progress={immersive_style={page_transition='off'}}},{}))
eq(final_char,previous:getPosition().char,'immediate backward transition restores the known complete last page before idle pagination')
eq(true,previous.widget.page_total~=nil,'backward transition reuses the previous canonical index')
previous:close()
local rapid=Adapter.new{settings={get=function() end},ui_manager=h.ui}
local rapidly_read=assert(rapid:openChapter({state=state(1),body=body,progress={immersive_style={page_transition='off'}}},{}))
while not rapidly_read.widget.page.at_end do assert(rapidly_read.widget:nextPage()) end
local rapid_last=rapidly_read:getPosition().char
assert(rapid:openChapter({state=state(2),body=body,progress={immersive_style={page_transition='off'}}},{}))
local rapid_back=state(1);rapid_back.restore_fraction=1
local back=assert(rapid:openChapter({state=rapid_back,body=body,progress={immersive_style={page_transition='off'}}},{}))
eq(rapid_last,back:getPosition().char,'rapid backward navigation preserves the actual last page even before the background index completes')
back:close()
-- A page exceeding the soft budget yields between bounded shaping windows.
local yielded=assert(Reader.prepare(options(2)))
local tick=0
local function slow_clock() tick=tick+.009;return tick end
local initial=#yielded.page_starts
assert(Reader.prepareNextPage(yielded,slow_clock))
eq(initial,#yielded.page_starts,'an over-budget page yields before publishing a partial page start')
for _=1,1000 do
    assert(Reader.prepareNextPage(yielded,slow_clock))
    if #yielded.page_starts>initial then break end
end
eq(initial+1,#yielded.page_starts,'resuming a yielded page publishes exactly one complete index entry')
local metrics={};local timing_options=options(1)
timing_options.callbacks={now=function() return os.clock() end,
    timing=function(stage,started,details) metrics[stage]={started=started,details=details} end}
view=assert(Reader.new(timing_options));h.ui:show(view);h:drain()
metrics={};assert(view:nextPage());view:paintTo(h.screen.bb,0,0)
eq(true,metrics.page_prepare~=nil,'ordinary page preparation emits a measurable baseline')
eq(true,metrics.paint_drawn~=nil,'actual buffer painting is timed separately from readiness')
view:close()
local Identity=require('legado.lib.identity');local original_hash=Identity.hash;local hashes=0
Identity.hash=function(...) hashes=hashes+1;return original_hash(...) end
local memo=assert(Reader.prepare(options(2)));local parsed_hashes=hashes
assert(Reader.prepare(options(2),memo))
Identity.hash=original_hash
eq(1,parsed_hashes,'first preparation computes one checksum through text parsing')
eq(parsed_hashes,hashes,'known immutable prepared content is not hashed again at open')
local paused_calls=0;local suspended=false;local pause_options=options(1)
pause_options.callbacks={pause=function(_,suspend) paused_calls=paused_calls+1;suspended=suspend==true;return true end}
view=assert(Reader.new(pause_options));h.ui:show(view)
assert(view:pauseReading());view:onSuspend()
eq(2,paused_calls,'suspending an already paused menu still informs Session to cancel background work')
eq(true,suspended,'physical suspend is distinguished from an ordinary overlay pause')
local paused_starts=#view.page_starts
h:step()
eq(paused_starts,#view.page_starts,'suspend cancels the active chapter pagination job as well as future chapters')
assert(view:resumeReading());h:drain()
eq(true,view.page_total~=nil,'resume completes the same active pagination index')
view:close()
local old_w,old_h=h.dimensions.w,h.dimensions.h
h.dimensions.w,h.dimensions.h=120,120
local narrow_options=options(1);narrow_options.body='<p>甲乙丙</p>'
narrow_options.style={body_font_size=72,show_header=false,show_footer=false,page_transition='off'}
local narrow=assert(Reader.prepare(narrow_options))
eq(true,narrow.page.next_position.char>1 or narrow.page.at_end,'a one-glyph-wide page reduces indentation to preserve real character progress')
h.dimensions.w,h.dimensions.h=old_w,old_h
local Text=require('legado.lib.leko_text')
local long_options=options(1);long_options.body='<p>'..string.rep('甲',30000)..'</p>'
local long=assert(Reader.prepare(long_options));long.pagination_position={chapter=1,paragraph=1,char=20001}
assert(Reader.prepareNextPage(long));while long.pagination_task do assert(Reader.prepareNextPage(long)) end
local original_window=Text.utf8Window;local scanned=0
Text.utf8Window=function(value,first,limit,hint_char,hint_byte)
    scanned=math.max(scanned,first-(hint_char or 1))
    return original_window(value,first,limit,hint_char,hint_byte)
end
assert(Reader.prepareNextPage(long));Text.utf8Window=original_window
eq(true,scanned<=768,'sequential late-page pagination scans only the bounded window after its preceding page')
eq(false,Reader.DEFAULT_STYLE.chapter_clean_wave_enabled,'ordinary fast page transition is the default across chapters')
return n
