require('library_screen_stub')
local A=require('assertions')
local Presenter=require('legado.ui.presenter')
local Comments=require('legado.lib.weread_comments')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local shown,pending={},{ }
local client={discussionDetail=function(_,book,chapter,id,cb)
    local call={id=id,cb=cb};pending[#pending+1]=call;return {cancel=function() call.cancelled=true end} end,
    chapterComments=function(_,book,chapter,cb,cursor)
        local call={page=cursor,cb=cb};pending[#pending+1]=call;return {cancel=function() call.cancelled=true end} end}
local c=Comments.new{client=client,book_id='b',chapter_uid='7'}
c.loaded=true;c.rows={
    {id='r1',range='0-4',author='作者',avatar_url='https://wx.qlogo.cn/a/0',abstract='原句',content='想法',likes_count=2},
    {id='r2',range='8-12',author='其他作者',abstract='其他原句',content='其他想法'},
}
c.next_cursor={ranges={{range='0-4',maxIdx=20,synckey=1}}}
local resumes=0
local doc={reading_state={chapters={{title='章节'}},index=1},resumeReading=function() resumes=resumes+1 end}
local p=Presenter.new{ui_manager={show=function(_,w) shown[#shown+1]=w end,close=function() end}}
p:showChapterComments(c,doc,'0-4')
local list=shown[#shown]
eq(1,#list.items,'body click filters thoughts to the exact requested passage')
eq('function',type(list.custom_body),'passage comments use the avatar card body')
eq('https://wx.qlogo.cn/a/0',list.items[1].row.avatar_url,'passage avatar reaches actual card input')
eq(true,list.items[1].text:find('原句',1,true)~=nil,'passage list retains the source quote')
eq(false,list.items[1].text:find('未提供',1,true)~=nil,'no unknown-count placeholder is emitted')
list.items[1].callback()
eq('r1',pending[1].id,'passage thought opens its own detail instead of a plain popup')
pending[1].cb{reviewId='r1',review={reviewId='r1',bookId='b',chapterUid=7,content='完整想法',author={name='作者'}},
    likesCount=2,commentsCount=1,comments={{reviewId='r1',commentId='c1',content='对应回复',author={name='回复者'}}},likes={}}
eq('回复者',shown[#shown].items[1].row.author,'passage detail includes other readers replies')
shown[#shown].actions[1].callback()
eq(true,shown[#shown].text:find('原文：原句',1,true)~=nil,'detail lacking another quote keeps its verified list source quote')
shown[#shown].on_back()
shown[#shown].on_back()
eq(1,#shown[#shown].items,'returning from detail preserves the passage filter')
local old=shown[#shown]
old.items[1].callback()
shown[#shown].on_back()
eq(true,pending[2].cancelled,'return cancels passage detail IO')
local count_shown=#shown
pending[2].cb{reviewId='r1',review={reviewId='r1',content='late'}}
eq(count_shown,#shown,'late response cannot reopen the passage panel')
for _,action in ipairs(shown[#shown].actions) do if action.text=='全部原文片段' then action.callback();break end end
eq(2,#shown[#shown].items,'all-passages action opens the source groups')
local root=shown[#shown]
for _,action in ipairs(root.actions) do if action.text=='加载更多评论' then action.callback();break end end
eq(c.next_cursor,pending[3].page,'more comments use the actual per-range continuation cursor')
shown[#shown].on_back()
eq(true,pending[3].cancelled,'root close cancels passage pagination')
eq(1,resumes,'closing passage panel resumes its original reader once')
local visible=#shown
root.items[1].callback()
eq(visible,#shown,'stale passage cards cannot reopen a closed screen')
return n
