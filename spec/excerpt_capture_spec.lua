local A=require('assertions')
local Context=require('legado.lib.excerpt_context')
local Markdown=require('legado.lib.excerpt_markdown')
local Storage=require('legado.lib.storage')
local n=0
local function eq(a,b,msg) n=n+1;A.equal(a,b,msg) end
local state={book={id='book-1',source_id='weread',name='油炸绿番茄',author='范妮'},index=2,
 chapters={{title='封面'},{title='作者简介',uid='ch2'}}}
local doc={reading_state=state,backend='immersive'}
local quote=Context.build('  优秀的句子\n第二行  ',doc,{first={paragraph=2,char=3},last={paragraph=3,char=9}})
eq('优秀的句子\n第二行',quote.quote,'capture retains selected multiline text')
eq('微信读书',quote.source,'WeRead source is recorded')
eq('作者简介',quote.chapter,'current chapter is recorded')
eq(true,quote.location:find('2:3',1,true)~=nil,'exact immersive selection is recorded')
state.book.source_id='source-2'
eq('书源',Context.build('原句',doc).source,'regular source supported')
local native={reader={doc_props={title='本地 MOBI',authors='作者'},document={file='/mnt/us/a.mobi'},
 getCurrentPage=function() return 8 end,toc={getTocTitleOfCurrentPage=function() return '第八章' end}}}
local local_quote=Context.build('本地原句',native,{pos0='/body/p[3]',pos1='/body/p[4]'})
eq('本地书籍',local_quote.source,'native MOBI and other formats use metadata')
eq('本地 MOBI',local_quote.title,'native title extracted')
eq('作者',local_quote.author,'native author extracted')
eq('第八章',local_quote.chapter,'native TOC title extracted')
eq(true,local_quote.location:find('/body/p[3]',1,true)~=nil,'native xpointer retained')
eq(nil,Context.build(' ',doc),'empty quotes refused')
eq(nil,Context.build(string.rep('x',65537),doc),'oversized selection refused without truncation')
doc.closed=true;eq(nil,Context.build('旧内容',doc),'closed reader cannot save stale selection')
local files,fail={},false
local fs={read=function(_,path) return files[path] end,atomicWrite=function(_,path,data)
 if fail then return nil,{code='STORAGE_ERROR'} end;files[path]=data;return true end}
local store=Storage.new{path='test',fs=fs,sqlite_loader=function() return nil end}
quote.id='excerpt-a';quote.captured_at='2026-10-08T11:00:00+0800';quote.status='pending'
eq('excerpt-a',store:putExcerpt(quote).id,'quote durably saved')
eq(1,#store:listExcerpts(),'list persisted quotes')
local restarted=Storage.new{path='test',fs=fs,sqlite_loader=function() return nil end}
eq(quote.quote,restarted:getExcerpt('excerpt-a').quote,'restart retains quote')
fail=true;local changed=restarted:getExcerpt('excerpt-a');changed.status='synced'
eq(nil,restarted:putExcerpt(changed),'failed state save reported')
eq('pending',restarted:getExcerpt('excerpt-a').status,'failed state save retains original queue')
quote.title='../../书名 <测试>';quote.quote='原文\n<script>alert(1)</script>'
local path=Markdown.path(quote,'阅读摘录/不亦阅乎')
eq(false,path:find('..',1,true)~=nil,'book filenames cannot escape folders')
eq(nil,Markdown.path(quote,'../outside'),'unsafe configured folder rejected')
local md=Markdown.render(quote)
eq(true,md:find('> 原文',1,true)~=nil,'quote is a Markdown blockquote')
eq(true,md:find('&lt;script&gt;',1,true)~=nil,'HTML in quotations stays text')
eq(true,md:find('legado-excerpt:excerpt-a',1,true)~=nil,'stable marker for retry deduplication')
eq(true,md:find('## 我的想法',1,true)~=nil,'note provides annotation area')
return n
