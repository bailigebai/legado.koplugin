local A=require('assertions')
local Detail=require('legado.lib.weread_discussion_detail')
local n=0
local function eq(want,got,why) n=n+1;A.equal(want,got,why) end
local sent,live,changed={},true,0
local function send(kind,...)
    local args={...};local callback=table.remove(args)
    local r={kind=kind,args=args,cb=callback};sent[#sent+1]=r
    return {cancel=function() r.cancelled=true end}
end
local client={discussionDetail=function(_,b,c,id,cb) return send('detail',b,c,id,cb) end,
    discussionReplies=function(_,id,cb,cursor) return send('replies',id,cursor,cb) end,
    discussionLikes=function(_,id,idx,cb) return send('likes',id,idx,cb) end}
local detail=Detail.new{client=client,book_id='b',chapter_uid='7',review={id='r1',content='seed',author='原作者'},
    is_current=function() return live end,on_change=function() changed=changed+1 end}
eq(0,#sent,'creation starts no optional network requests')
detail:load();detail:load()
eq(1,#sent,'opening detail starts one bounded request')
sent[1].cb({reviewId='r1',review={reviewId='r1',content='full',author={name='作者'}},likesCount=2,commentsCount=3,
    likes={{userVid=1,name='读者1'}},comments={{reviewId='r1',commentId='c1',content='回复1',subCommentsCount=1}}})
eq('full',detail.review.content,'full thought replaces seed only on matching response')
eq(1,#detail.replies.rows,'embedded replies show immediately')
eq(true,detail.replies.has_more,'known count greater than seed leaves pagination available')
eq(true,detail.likes.has_more,'supporter count greater than returned people leaves pagination available')
detail:loadReplies()
eq(1,sent[2].args[2].max_idx,'reply offset uses raw server list size')
sent[2].cb({comments={{reviewId='r1',commentId='c1',content='dup'},{reviewId='r1',commentId='c2',content='回复2'}},has_more=true})
eq(2,#detail.replies.rows,'pagination deduplicates while preserving loaded replies')
eq(3,detail.replies.offset,'raw duplicates still advance the official cursor')
detail:loadReplies()
sent[3].cb(nil,'网络失败')
eq(2,#detail.replies.rows,'pagination failure preserves existing replies')
eq('网络失败',detail.replies.error,'pagination error offers explicit retry')
detail:loadReplies();sent[4].cb({comments={},has_more=false})
eq(false,detail.replies.has_more,'explicit exhaustion ends pagination')
detail:loadLikes();sent[5].cb({likes={{userVid=2,name='读者2'}},likesCount=2})
eq(2,#detail.likes.rows,'supporters append without replacing earlier users')
eq(false,detail.likes.has_more,'actual count ends supporter pages')
local root=detail.replies.rows[1]
local thread=detail:thread(root)
detail:loadReplies(root)
eq('c1',sent[6].args[2].comment_id,'nested request belongs to root comment')
eq(0,sent[6].args[2].max_idx,'nested reply cursor starts independently')
detail:close()
eq(true,sent[6].cancelled,'closing detail cancels active thread request')
local before=changed
sent[6].cb{comments={{commentId='late',content='late'}},has_more=false}
eq(0,#thread.rows,'late reply cannot populate closed detail')
eq(before,changed,'late response cannot redraw closed detail')
local other=Detail.new{client=client,book_id='b',chapter_uid='7',review={id='r2',content='seed'},is_current=function() return live end}
other:load();live=false
sent[7].cb{reviewId='r2',review={reviewId='r2',content='wrong-owner'}}
eq('seed',other.review.content,'changing chapter or account invalidates pending detail')
local sync=Detail.new{book_id='b',chapter_uid='7',review={id='r3',content='original'},client={
    discussionDetail=function(_,_,_,_,cb) cb(nil,'失败');return {cancel=function() error('retained sync handle') end} end}}
sync:load()
eq('original',sync.review.content,'initial failure still shows original full thought')
eq('失败',sync.error,'initial failure is retryable')
sync:close()
local stopped,starts
starts=0
stopped=Detail.new{book_id='b',chapter_uid='7',review={id='r4',content='seed'},
    client={discussionDetail=function() starts=starts+1 end},on_change=function() stopped:close() end}
stopped:load()
eq(0,starts,'closing during loading notification cannot start an unowned request')
local counts=Detail.new{client=client,book_id='b',chapter_uid='7',review={id='r5',content='seed'}}
counts:load()
sent[8].cb{reviewId='r5',review={reviewId='r5',content='原文'},comments={},likes={}}
counts:loadLikes()
sent[9].cb{reviewId='r5',likesCount=1,likes={{userVid=9,name='赞者'}}}
eq(1,counts.review.likes_count,'count first returned by supporter page becomes visible')
eq(false,counts.likes.has_more,'page total also governs exhaustion')
counts:loadReplies()
sent[10].cb{commentsCount=0,comments={},has_more=false}
eq(0,counts.review.comments_count,'real zero first returned by reply page becomes visible')
eq(0,counts.replies.total,'reply page updates its own total')
counts:close()
return n
