local A=require('assertions')
local Fs=require('legado.lib.fs')
local CacheStore=require('legado.lib.cache_store')
local Images=require('legado.lib.weread_images')
local Service=require('legado.lib.weread_service')
local ReaderSession=require('legado.lib.reader_session')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local function yes(value,message) count=count+1;A.truthy(value,message) end
local files={}
local lfs={attributes=function(path) return files[path] and {mode='file',size=#files[path]} or nil end,
    mkdir=function() return true end}
local fs=Fs.new{lfs=lfs,open=function(path,mode)
    if mode=='rb' then
        if not files[path] then return nil,'missing' end
        local value=files[path]
        return {read=function() return value end,close=function() end,seek=function() return #value end}
    end
    local buffer=''
    return {write=function(_,value) buffer=buffer..value;files[path]=buffer;return true end,
        flush=function() end,close=function() end}
end,rename=function(from,to) files[to]=files[from];files[from]=nil;return true end,
    remove=function(path) files[path]=nil;return true end}
local cache=CacheStore.new{fs=fs,root='image-cache'}
local chapter={uid='chapter-one'}
local fixtures=require('fixtures.chapter_images')
local png,jpg=fixtures.png,fixtures.gif
local decoded,freed=0,0
package.loaded['ui/renderimage']={renderImageData=function(_,value)
    decoded=decoded+1
    if value~=png and value~=jpg then return nil end
    return {getWidth=function() return 1 end,getHeight=function() return 1 end,
        free=function() freed=freed+1 end}
end}
local fetched={}
local client={fetchResource=function(_,url,callback)
    fetched[#fetched+1]=url
    callback(url:find('/second',1,true) and jpg or png)
    return {cancel=function() end}
end}
local images=Images.new{cache=cache,client=client}
local html='<p><img src="https://res.weread.qq.com/wrepub/first"><img src="/wrepub/second"></p>'
local result,failure
images:prepare('book-one',chapter.uid,html,function(value,err) result,failure=value,err end,chapter)
eq(nil,failure,'trusted WeRead images prepare without error')
yes(result and result:find('src="../images/chapter%-one_1_[%w_-]+.png"')~=nil,
    'absolute image URL becomes a local chapter image reference')
yes(result and result:find('src="../images/chapter%-one_2_[%w_-]+.gif"')~=nil,
    'relative image URL becomes a local chapter image reference')
eq('https://res.weread.qq.com/wrepub/second',fetched[2],
    'relative WeRead image resolves against the trusted resource host')
eq(png,cache:readImage('weread','book-one',chapter,1),
    'image cache stores the real binary bytes')
eq(true,cache:verifyChapterImages('weread','book-one',chapter,result),
    'localized chapter validates every referenced image')
local upper_body=result:gsub('<img','<IMG'):gsub('src=','SRC=')
eq(true,cache:verifyChapterImages('weread','book-one',chapter,upper_body),
    'uppercase image markup receives the same cache validation')
local fetched_before=#fetched
result,failure=nil,nil
images:prepare('book-one',chapter.uid,html,function(value,err) result,failure=value,err end,chapter)
eq(nil,failure,'offline revisit uses verified local images')
eq(fetched_before,#fetched,'offline revisit does not issue image requests')
local old_body=result
local broken_refresh=Images.new{cache=cache,client={fetchResource=function(_,url,callback)
    if url:find('replacement',1,true) then callback(jpg) else callback(nil,'download failed') end
end}}
local refresh_error
broken_refresh:prepare('book-one',chapter.uid,
    '<img src="https://res.weread.qq.com/replacement"><img src="https://res.weread.qq.com/failure">',
    function(_,err) refresh_error=err end,chapter)
eq('NETWORK_ERROR',refresh_error and refresh_error.code,'partial image refresh reports failure')
eq(true,cache:verifyChapterImages('weread','book-one',chapter,old_body),
    'partial image refresh preserves every asset referenced by the old readable chapter')
local store=cache._store
cache._store=function(self,path,...)
    if path:match('%.json$') then return nil,{code='STORAGE_ERROR',message='metadata save failed'} end
    return store(self,path,...)
end
local failed_write,failed_error=cache:writeImage('weread','book-one',chapter,1,png,'https://res.weread.qq.com/new')
cache._store=store
eq(nil,failed_write,'metadata save failure does not pretend the new image committed')
eq('STORAGE_ERROR',failed_error.code,'metadata failure stays visible')
eq(true,cache:verifyChapterImages('weread','book-one',chapter,old_body),
    'metadata failure leaves the previous immutable image references readable')
local fake_image=Images.new{cache=cache,client={fetchResource=function(_,_,callback) callback('\137PNG\r\n\26\n') end}}
local invalid_body,invalid_error
fake_image:prepare('book-one','fake','<img src="https://res.weread.qq.com/fake">',
    function(value,err) invalid_body,invalid_error=value,err end)
eq(nil,invalid_body,'an image signature alone cannot complete a readable chapter')
eq('INVALID_INPUT',invalid_error and invalid_error.code,'decoder failure produces an actionable error')
eq(true,decoded>0 and decoded==freed,'successful decode buffers are freed and failed decode has no buffer')
local truncated=png:sub(1,32)
eq(nil,cache:writeImage('weread','book-one',{uid='truncated'},1,truncated,'https://res.weread.qq.com/truncated'),
    'a plausible PNG header with a truncated body is rejected by the host decoder')
local bad_dimensions=png:sub(1,16)..'\0\0\255\255'..png:sub(21)
local before_decode=decoded
eq(nil,cache:writeImage('weread','book-one',{uid='huge-pixels'},1,bad_dimensions,'https://res.weread.qq.com/huge'),
    'oversized pixel dimensions cannot enter the decoder')
eq(before_decode,decoded,'pixel limit is enforced before native allocation')

local changed_html='<img src="https://res.weread.qq.com/wrepub/replaced">'
local changed_result
images:prepare('book-one',chapter.uid,changed_html,function(value) changed_result=value end,chapter)
eq(fetched_before+1,#fetched,'changed chapter image URL triggers a fresh resource request')
yes(changed_result and changed_result:find('../images/chapter%-one_1_[%w_-]+.png')~=nil,
    'changed chapter image still receives a local reference')
local trusted_fetches=#fetched

local bad,denied=nil,nil
images:prepare('book-one',chapter.uid,'<img src="https://evil.test/x.png">',function(value,err)
    bad,denied=value,err
end,chapter)
eq(nil,bad,'untrusted image host never becomes readable chapter content')
eq('INVALID_INPUT',denied and denied.code,'untrusted host gives an actionable error')
eq(trusted_fetches,#fetched,'untrusted host is not requested')
local traversal_error
images:prepare('book-one',chapter.uid,'<img src="../private.png">',function(_,err)
    traversal_error=err
end,chapter)
eq('INVALID_INPUT',traversal_error and traversal_error.code,
    'relative parent path cannot escape the trusted resource path')
eq(trusted_fetches,#fetched,'relative traversal is not requested')

local huge=Images.new{cache=cache,client={fetchResource=function(_,_,callback)
    callback(string.rep('x',4*1024*1024+1));return {cancel=function() end}
end}}
local too_large,limit_error
huge:prepare('book-one','large','<img src="https://res.weread.qq.com/wrepub/large">',function(value,err)
    too_large,limit_error=value,err
end,{uid='large'})
eq(nil,too_large,'oversized image does not complete a chapter')
eq('RESPONSE_TOO_LARGE',limit_error and limit_error.code,'image size limit is visible')

local _,asset_path=cache:readImage('weread','book-one',chapter,1)
files[asset_path]='damaged'
local verified,corrupt_error=cache:verifyChapterImages('weread','book-one',chapter,result)
eq(nil,verified,'damaged local asset is not treated as a valid offline chapter')
eq('STORAGE_ERROR',corrupt_error and corrupt_error.code,'damaged local asset reports cache failure')

local pending,delivered,cancelled=nil,0,0
local delayed=Images.new{cache=cache,client={fetchResource=function(_,_,callback)
    pending=callback;return {cancel=function() cancelled=cancelled+1 end}
end}}
local handle=delayed:prepare('book-one','cancelled','<img src="https://res.weread.qq.com/wrepub/pending">',
    function() delivered=delivered+1 end,{uid='cancelled'})
eq(true,handle:cancel(),'pending image request can be cancelled')
pending(png)
eq(1,cancelled,'cancel propagates to the network request')
eq(0,delivered,'late image response cannot complete a cancelled chapter')
eq(nil,files[cache:imagePath('weread','book-one',{uid='cancelled'},1,'png')],
    'late cancelled image response is never cached')

local tar_name='42/epub_42_7'
local tar_header=tar_name..string.rep('\0',100-#tar_name)..string.rep('\0',24)
    ..string.format('%011o',#png)..'\0'..string.rep('\0',20)..'0'
tar_header=tar_header..string.rep('\0',512-#tar_header)
local tar_data=tar_header..png..string.rep('\0',(512-#png%512)%512)..string.rep('\0',1024)
local tar_calls={}
local tar_images=Images.new{cache=cache,client={fetchResource=function(_,url,callback)
    tar_calls[#tar_calls+1]=url
    callback(url:find('/wrco/',1,true) and tar_data or nil,'unexpected direct image request')
    return {cancel=function() end}
end}}
local tar_result,tar_error
tar_images:prepare('book-one','tar-chapter','<img src="https://res.weread.qq.com/wrepub/epub_42_7">',
    function(value,err) tar_result,tar_error=value,err end,
    {uid='tar-chapter',resource_tar='https://res.weread.qq.com/wrco/tar_42_7'})
eq(nil,tar_error,'chapter resource package supplies its referenced image')
eq(1,#tar_calls,'resource package avoids a second direct image request')
yes(tar_result and tar_result:find('../images/tar%-chapter_1_[%w_-]+.png')~=nil,
    'image extracted from resource package is referenced locally')

local service=Service.new({chapterContent=function(_,_,_,callback)
    callback(html);return {cancel=function() end}
end},images)
local chapter_content
service:getContent({id='weread'},{id='book-one',remote_id='remote-one'},
    {uid=chapter.uid,remote_uid='remote-chapter'},function(value) chapter_content=value end)
yes(chapter_content and chapter_content.content:find('../images/chapter%-one_1_[%w_-]+.png')~=nil,
    'WeRead content service returns local image references to the reader session')
local uppercase_content
local uppercase_service=Service.new({chapterContent=function(_,_,_,callback)
    callback('<IMG SRC="https://res.weread.qq.com/wrepub/first">')
end},images)
uppercase_service:getContent(nil,{id='book-one',remote_id='remote-one'},
    {uid=chapter.uid,remote_uid='remote-chapter'},function(value) uppercase_content=value end)
yes(uppercase_content and uppercase_content.content:find('../images/chapter%-one_1_[%w_-]+.png')~=nil,
    'uppercase image markup is localized before rendering')

local native_calls=0
local guard_session=ReaderSession.new{cache={readBody=function() return html end,
    verifyChapterImages=function(_,source,book,selected,body)
        return cache:verifyChapterImages(source,book,selected,body)
    end},storage={getProgress=function() return nil end},
    ui={openDocument=function() native_calls=native_calls+1 end},
    settings={get=function() return false end}}
local unreadable=guard_session:open({id='weread'},{id='book-one',source_id='weread'},
    {{uid='chapter-one',title='图片章'}},1,{backend='native'})
eq(nil,unreadable,'remote image reference is not opened as a blank native chapter')
eq(0,native_calls,'reader does not show unlocalized remote images as success')

local reading_progress,rendered_html
local reading_book={id='book-one',remote_id='remote-one',source_id='weread',name='图文书'}
local reading_chapter={uid='chapter-one',remote_uid='remote-chapter',source_id='weread',
    book_id='book-one',index=1,title='图片章',url='weread://book/remote-one/chapter/remote-chapter'}
local reading_storage={getProgress=function() return reading_progress end,
    putProgress=function(_,value) reading_progress=value;return value end}
local reading_session=ReaderSession.new{cache=cache,storage=reading_storage,service=service,
    settings={get=function(_,key) return key=='immersive_reader' and true or 0 end},
    ui={openDocument=function(_,path,callbacks)
        rendered_html=assert(cache:readHtml('weread','book-one',reading_chapter))
        local document={backend='native',getProgressFraction=function() return 0 end,
            setProgressFraction=function() return true end,close=function() return true end}
        callbacks.ready(document);return document
    end}}
assert(reading_session:open({id='weread'},reading_book,{reading_chapter},1,{}))
yes(rendered_html and rendered_html:find('../images/chapter%-one_1_[%w_-]+.png')~=nil,
    'native reader receives HTML that refers to cached local image files')
eq(nil,rendered_html:find('https://res.weread.qq.com',1,true),
    'native reader HTML has no authenticated remote image URL')
eq(true,reading_progress.contains_images,'only opened image chapter marks its book as containing images')

return count
