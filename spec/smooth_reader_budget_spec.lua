package.path='spec/phase3/?.lua;'..package.path
local h=require('leko_reader_harness').install()
local A=require('assertions');local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local Adapter=require('legado.lib.koreader_reader_ui')
local chapters={{uid='c1',title='一'},{uid='c2',title='二'},{uid='c3',title='三'},{uid='c4',title='四'}}
local state={source={id='s'},book={id='budget'},chapters=chapters,index=1}
local owner=Adapter.new{ui_manager=h.ui}
local document=assert(owner:openChapter({state=state,body='<p>当前</p>',progress={immersive_style={page_transition='off'}}},{}))
local body='<p>'..string.rep('甲',1024*1024)..'</p>'
for index=2,4 do owner:prepareChapter(state,chapters[index],body) end
eq(2,#owner.prepared_chapters,'raw prepared text never retains a third 3 MiB chapter beyond its 8 MiB budget')
eq('c2',owner.prepared_chapters[1].chapter_uid,'budget keeps the nearest chapter first')
eq('c3',owner.prepared_chapters[2].chapter_uid,'budget releases the farthest chapter first')
document:close();body=nil;collectgarbage('collect')

-- Seed completed page-index metadata at the cache-policy boundary. Actual
-- pagination and positions are covered by the paginator and smooth-reader specs;
-- constructing 10000 shaped pages here would test the same fitter repeatedly.
document=assert(owner:openChapter({state=state,body='<p>当前</p>',progress={immersive_style={page_transition='off'}}},{}))
for index=2,3 do
    assert(owner:prepareChapter(state,chapters[index],'<p>已排版正文</p>'))
    local prepared=owner.prepared_chapters[#owner.prepared_chapters].prepared
    for page=2,5001 do prepared.page_starts[page]={chapter=1,paragraph=page,char=1} end
end
owner:prepareChapter(state,chapters[4],'<p>下一章</p>')
local starts=0
for _,record in ipairs(owner.prepared_chapters) do starts=starts+#record.prepared.page_starts end
eq(true,starts<=10000,'background canonical page starts remain inside the shared 10000-entry budget')
eq('c2',owner.prepared_chapters[1].chapter_uid,'page-index pressure preserves nearest complete chapter')
document:close()
eq(0,#h.tasks,'budget eviction and close leave no prepared pagination jobs')
return n
