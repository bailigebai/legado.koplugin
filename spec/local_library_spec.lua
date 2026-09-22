local A=require('assertions')
local Local=require('legado.lib.local_library')
local Settings=require('legado.lib.settings')
local Fs=require('legado.lib.fs')
local count=0
local function eq(a,b,m) count=count+1; A.equal(a,b,m) end
local settings=Settings.new()
local paths={['/books']={mode='directory'},['/books/sub']={mode='directory'},['/books/skip.sdr']={mode='directory'},
    ['/books/skip.sdr/cache.txt']={mode='file'},['/books/link']={mode='link'},
    ['/books/A.epub']={mode='file'},['/books/B.txt']={mode='file'},['/books/sub/C.HTML']={mode='file'},
    ['/books/no.exe']={mode='file'}}
local lfs={attributes=function(p) return paths[p] end,symlinkattributes=function(p) return paths[p] end}
function lfs.dir(path)
    local names={'.','..'}
    for p in pairs(paths) do
        local suffix=p:sub(#path+2)
        if p:sub(1,#path+1)==path..'/' and suffix~='' and not suffix:find('/',1,true) then names[#names+1]=suffix end
    end
    local i=0
    local state={}
    return function(s) assert(s==state,'directory iterator needs its state'); i=i+1;return names[i] end,state
end
local fs=Fs.new({lfs=lfs})
local images={}
function fs:readBounded(path) return images[path] end
local stored={}
local storage={getBook=function(_,id) return stored[id] end,createBook=function(_,book) stored[book.id]=book; return book end}
local localbooks=Local.new({fs=fs,settings=settings,storage=storage})
assert(localbooks:addDirectory('/books'))
assert(localbooks:addDirectory('/books/sub'))
eq(2,#localbooks:directories(),'multiple roots persist')
assert(localbooks:addDirectory('/books'))
eq(2,#localbooks:directories(),'duplicate root is ignored')
eq(nil,localbooks:addDirectory('/books/link'),'symlink is not an added directory')
eq(nil,localbooks:addDirectory('/missing'),'missing root is rejected')
local books,warning=localbooks:scan()
eq(3,#books,'overlapping roots deduplicate files and skip symlinks and metadata')
eq(nil,warning,'normal scan succeeds')
eq('A',books[1].name,'filename supplies local title')
local first_id=books[1].id
paths['/books/0.txt']={mode='file'}
books=localbooks:scan()
eq(first_id,books[2].id,'local IDs survive sorting changes')
assert(localbooks:removeDirectory('/books/sub'))
eq('file',paths['/books/sub/C.HTML'].mode,'removing a root does not delete files')

local searches,fetches=0,0
localbooks.native_cover=function(_,book) if book.name=='A' then return '/covers/embedded.png' end end
localbooks.cover_loader={load=function(_,book,cb) fetches=fetches+1;cb('/covers/matched.jpg');return {cancel=function() end} end}
localbooks.service={search=function(_,_,_,_,done,progress)
    searches=searches+1
    progress({groups={{book={name='Another',cover_url='https://s/wrong.jpg'}},{book={name='B',cover_url='https://s/right.jpg',source_id='s'}}}})
    done({groups={}})
    return {cancel=function() end}
end}
local cover,called
localbooks:loadCover(books[2],function(path) cover=path end)
eq('/covers/embedded.png',cover,'embedded cover wins')
eq(0,searches,'embedded cover avoids online search')
localbooks:loadCover(books[3],function(path) cover=path;called=(called or 0)+1 end)
eq('/covers/matched.jpg',cover,'missing cover searches sources')
eq(1,called,'progress and completion deliver one cover')
eq(1,fetches,'only exact title is downloaded')
eq('https://s/right.jpg',stored[books[3].id].cover_url,'matched cover persists without changing local file')
localbooks:loadCover(books[3],function() end)
eq(1,searches,'known cover does not search again')
local queue={}
localbooks.scheduler={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}
local h=localbooks:loadCover(books[4],function() error('cancelled page must stay closed') end)
h:cancel();queue[1]()
eq(1,searches,'cancel before rendering prevents requests')

localbooks.root='/covers'
local document_closed,buffer_freed,metadata_only=0,0,nil
function fs:ensureDirectory() return true end
package.loaded['document/documentregistry']={hasProvider=function() return true end,openDocument=function()
    return {loadDocument=function(_,full) metadata_only=full end,close=function() document_closed=document_closed+1 end,
        getCoverPageImage=function() return {writeToFile=function(_,path) images[path]='PNG';return true end,
            free=function() buffer_freed=buffer_freed+1 end} end}
end}
local path=localbooks:_embeddedCover(books[2])
eq('PNG',images[path],'native embedded cover is cached as a readable file')
eq(false,metadata_only,'cover extraction loads only ebook metadata')
eq(1,document_closed,'temporary document is closed after extraction')
eq(1,buffer_freed,'native image buffer is freed after extraction')
localbooks:_embeddedCover(books[2])
eq(1,document_closed,'cached embedded image avoids reopening ebook')

local detail_callback,detail_cancel= nil,0
localbooks.scheduler=nil
local detail_source={id='source-detail'}
local detail_source_id=require('legado.lib.models').sourceId(detail_source)
storage.listSources=function() return {detail_source} end
localbooks.service={search=function(_,_,_,_,cb)
    cb({groups={{book={id='candidate',name='C',source_id=detail_source_id,cover_url=''}}}})
    return {cancel=function() end}
end,getBookInfo=function(_,_,_,cb)
    detail_callback=cb
    return {cancel=function() detail_cancel=detail_cancel+1 end}
end}
local detail_handle=localbooks:loadCover(books[4],function(path) cover=path end)
eq('function',type(detail_callback),'sources with no search cover fall back to book details')
detail_handle:cancel()
eq(1,detail_cancel,'cancel stops detail lookup even when search completed synchronously')
localbooks:loadCover(books[4],function(path) cover=path end)
detail_callback({id='candidate',name='C',source_id=detail_source_id,cover_url='https://s/detail-cover.jpg'})
eq('/covers/matched.jpg',cover,'detail-only cover is downloaded')

local Shelf=require('legado.ui.bookshelf')
storage.listShelf=function() return {{id='remote',name='Web'},{id=first_id,is_local=true,name='A'}} end
local shelf=Shelf.new({storage=storage,local_library=localbooks,source_mode='mixed'})
eq(5,shelf:page(1).total,'mixed shelf does not duplicate indexed local metadata')
shelf.source_mode='sources';eq(1,shelf:page(1).total,'source shelf excludes local metadata')
shelf.source_mode='local';eq(4,shelf:page(1).total,'local switch shows scanned files')

-- Exercise cleanup with a stateful directory iterator and a live-book exclusion.
local Cache=require('legado.lib.cache_store')
paths={['/cache']={mode='directory'},['/cache/s']={mode='directory'},['/cache/s/b']={mode='directory'},
    ['/cache/s/b/chapters']={mode='directory'},['/cache/s/b/chapters/c.body']={mode='file'},
    ['/cache/s/b/catalog.json']={mode='file'},['/cache/keep.txt']={mode='file'}}
function fs:ensureDirectory() return true end
local removed={}
function fs:removeFile(path) removed[#removed+1]=path;paths[path]=nil;return true end
local cache=Cache.new({root='/cache',fs=fs})
eq(0,cache:clear({source_id='s',book_id='b'}),'current book cache is protected')
paths['/cache/trap']={mode='link'}
eq(nil,cache:clear(),'cleanup refuses symlink traversal')
eq(0,#removed,'unsafe scan removes nothing')
paths['/cache/trap']=nil
eq(1,cache:clear(),'cleanup removes generated chapter files')
eq('file',paths['/cache/s/b/catalog.json'].mode,'cleanup preserves catalog metadata')
eq('file',paths['/cache/keep.txt'].mode,'cleanup preserves unknown files')
return count
