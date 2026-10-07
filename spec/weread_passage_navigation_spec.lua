require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Comments=require('legado.lib.weread_comments')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local shown,pending={},{}
local client={discussionDetail=function(_,book,chapter,id,cb)
    pending[#pending+1]={id=id,cb=cb};return {cancel=function() end}
end}
local c=Comments.new{client=client,book_id='b',chapter_uid='7'}
c.loaded=true;c.rows={
    {id='r1',range='0-4',author='甲',abstract='相同原句',content='第一位读者',avatar_url='https://wx.qlogo.cn/a/0'},
    {id='r2',range='0-4',author='乙',abstract='相同原句',content='第二位读者'},
    {id='r3',range='8-12',author='丙',abstract='相同原句',content='另一处的读者'},
}
for i=1,7 do c.rows[#c.rows+1]={id='x'..i,range=(i*20)..'-'..(i*20+4),abstract='原文'..i,content='评论'..i,author='读者'..i} end
local resumes=0
local doc={reading_state={chapters={{title='第一章'}},index=1},resumeReading=function() resumes=resumes+1 end}
local p=Presenter.new{ui_manager={show=function(_,w) shown[#shown+1]=w end,close=function() end}}
p:showChapterComments(c,doc)
local root=shown[#shown]
eq(6,#root.items,'menu starts at a paginated passage list rather than mixing all readers')
eq('0-4',root.items[1].row.range,'the same original range is grouped once')
eq('8-12',root.items[2].row.range,'identical text at another range remains a distinct passage')
eq(false,root.items[1].text:find('第一位读者',1,true)~=nil,'passage list does not substitute a random reader for the source')
root.items[1].callback()
local readers=shown[#shown]
eq(2,#readers.items,'opening source displays all its own readers')
eq('甲',readers.items[1].row.author,'first reader remains associated with source')
eq('乙',readers.items[2].row.author,'second reader remains associated with source')
eq('https://wx.qlogo.cn/a/0',readers.items[1].row.avatar_url,'reader avatar reaches the card')
readers.items[1].callback()
eq('r1',pending[1].id,'opening a reader requests that exact thought')
pending[1].cb{reviewId='r1',review={reviewId='r1',content='第一位读者',author={name='甲'}},comments={{commentId='reply',content='回复正文',author={name='丁'}}},likes={}}
eq('丁',shown[#shown].items[1].row.author,'thought detail includes its own replies')
shown[#shown].on_back()
eq(2,#shown[#shown].items,'detail Back restores corresponding readers')
shown[#shown].on_back()
eq(6,#shown[#shown].items,'reader Back restores passage list')
shown[#shown].on_next()
eq(3,#shown[#shown].items,'second passage page contains remaining ranges')
shown[#shown].items[1].callback()
shown[#shown].on_back()
eq(2,shown[#shown].page,'returning from readers preserves source page')
shown[#shown].on_back()
eq(1,resumes,'closing source list resumes original reader once')
c.rows={{id='unknown',author='无定位读者',abstract='未知原句',content='其他评论'},
    {id='known',range='0-4',author='正常读者',abstract='正常原文',content='正常评论'}}
p:showChapterComments(c,doc)
shown[#shown].items[1].callback()
eq(1,#shown[#shown].items,'unlocated source group does not accidentally expose every passage')
eq('无定位读者',shown[#shown].items[1].row.author,'unlocated comment remains readable without a guessed body position')
shown[#shown].on_back();shown[#shown].on_back()
return n
