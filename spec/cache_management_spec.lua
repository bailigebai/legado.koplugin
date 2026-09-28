local A=require('assertions')
local Management=require('legado.lib.cache_management')
local count=0
local function eq(expected,actual,message) count=count+1;A.equal(expected,actual,message) end
local files={['covers/cover-ab12.jpg']=2048,['covers/cover-d3.png']=1024,
    ['covers/manual.epub']=5000}
local removed={}
local lfs={
    dir=function()
        local names={'.','..','cover-ab12.jpg','cover-d3.png','manual.epub'}
        local index=0
        return function() index=index+1;return names[index] end
    end,
    symlinkattributes=function(path)
        if path=='covers' then return {mode='directory'} end
        if files[path] then return {mode='file',size=files[path]} end
    end,
}
local fs={lfs=lfs,removeFile=function(_,path) removed[#removed+1]=path;files[path]=nil;return true end}
local reading={usage=function() return {bytes=4096,files=2} end,
    clear=function(_,keep) eq('current',keep.book_id,'active book is protected');return 2 end}
local offline={usage=function() return {bytes=8192,files=3} end,
    clear=function(_,keep,include_catalog)
        eq('current',keep.book_id,'offline active book is protected')
        eq(true,include_catalog,'offline catalog is also cleared so download badge resets')
        return 3
    end}
local manager=Management.new{fs=fs,covers_root='covers',reading=reading,offline=offline}
local usage=manager:usage()
eq(15360,usage.bytes,'all cache categories are counted')
eq(7,usage.files,'all cache files are counted')
eq(3072,usage.covers.bytes,'only cached cover files are counted')
local result=manager:clear{book_id='current'}
eq(7,result.removed,'all selected cache files are cleared')
eq(2,#removed,'only known cover files are removed')
eq(5000,files['covers/manual.epub'],'exported files stay untouched')
files['covers/cover-ab12.jpg']=2048
lfs.symlinkattributes=function(path)
    if path=='covers' then return {mode='directory'} end
    if path=='covers/cover-ab12.jpg' then return {mode='link'} end
end
eq(nil,manager:clear{book_id='current'},'linked cover files block clearing')
return count
