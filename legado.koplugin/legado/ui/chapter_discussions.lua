local Body=require('legado.ui.discussion_body')
local Detail=require('legado.lib.weread_discussion_detail')
local Text=require('legado.lib.leko_text')
local Screen={}

function Screen.show(presenter,discussions,document,options)
    if not discussions:current() then return false end
    options=options or {}
    local passage,range=options.passage,options.range
    local chapter=document.reading_state.chapters[document.reading_state.index]
    local mode,list_page,detail_page,tab,parents='list',1,1,'replies',{}
    local detail,full,render
    local function close_widget()
        local widget=discussions.panel_widget
        discussions.panel_widget=nil
        if widget then presenter:_closeWidget(widget) end
    end
    local function close_panel()
        discussions.panel_changed,discussions.panel_close=nil,nil
        discussions:cancelLoad();close_widget()
        if discussions:current() and document.resumeReading then return document:resumeReading() end
        return true
    end
    local function current() return discussions:current() end
    local function back()
        if mode=='full' then mode=full.previous;full=nil;return render() end
        if mode=='detail' then
            if #parents>0 then table.remove(parents);detail_page=1;return render() end
            detail:close();discussions.detail,detail=nil,nil;mode='list';return render()
        end
        return close_panel()
    end
    local function show_full(row)
        full={previous=mode,row=row};mode='full';return render()
    end
    local function open_detail(row)
        if row.detail_available==false or row.id=='' or not discussions.client.discussionDetail then return show_full(row) end
        if detail then detail:close() end
        mode,detail_page,tab,parents='detail',1,'replies',{}
        detail=Detail.new{client=discussions.client,book_id=discussions.book_id,chapter_uid=discussions.chapter_uid,
            review=row,is_current=current,on_change=function() if discussions.panel_changed then discussions.panel_changed() end end}
        discussions.detail=detail
        render()
        detail:load()
        return true
    end
    render=function()
        if not current() then return false end
        close_widget()
        local widget,opts=nil,{compact=true,ui_manager=presenter.ui_manager,cover_loader=presenter.avatar_loader,
            title=(passage and '随文评论 · ' or '章节讨论 · ')..tostring(chapter.title or ''),mode='list',items={},actions={}}
        local function owned() return current() and discussions.panel_widget==widget end
        local function live() return owned() and widget.alive~=false and widget.closed~=true end
        local function guarded(fn) return function(...) if live() then return fn(...) end;return false end end
        if mode=='full' then
            local row=full.row
            opts.title=Body.heading(row)
            local quote=row.abstract and row.abstract~='' and ('原文：'..row.abstract..'\n\n') or ''
            opts.text=quote..(row.reply_to and row.reply_to~='' and ('回复 '..row.reply_to..'：\n') or '')..row.content
            opts.custom_body=Body.new{full_text=opts.text}
        else
            local rows,state,size,page
            if mode=='list' then
                rows,size,page=passage and discussions:list(range) or discussions.rows,passage and 4 or 6,list_page
                opts.subtitle=discussions.loading and (passage and '正在加载公开随文评论…' or '正在加载本章热门想法…')
                    or discussions.error or (#rows==0 and (passage and '暂无已加载的随文评论' or '暂无本章热门想法'))
                    or (passage and (range and '这段的公开想法' or '本章公开随文评论') or '本章热门想法')
                if not discussions.loading and (discussions.error or passage and discussions.next_cursor) then
                    opts.actions[1]={text=discussions.error and '重试' or '加载更多评论',
                        callback=guarded(function() return discussions:load() end)}
                end
                if passage and range then opts.actions[#opts.actions+1]={text='全部随文评论',
                    callback=guarded(function() range,list_page=nil,1;return render() end)} end
            else
                local parent=parents[#parents]
                state=tab=='likes' and detail.likes or detail:thread(parent)
                rows,size,page=state.rows,4,detail_page
                opts.review=parent or detail.review
                opts.subtitle=detail.loading and '正在加载想法详情…' or detail.error or state.error
                    or state.loading and '正在加载…' or tab=='likes' and '点赞者' or parent and '回复讨论' or '回复'
                opts.actions[1]={text='阅读全文',callback=guarded(function() return show_full(opts.review) end)}
                if not detail.loading and detail.error then
                    opts.actions[#opts.actions+1]={text='重试',callback=guarded(function() return detail:load() end)}
                elseif not state.loading and (state.error or state.has_more) and detail.loaded then
                    opts.actions[#opts.actions+1]={text=state.error and '重试' or tab=='likes' and '更多点赞者' or '更多回复',
                        callback=guarded(function()
                            if tab=='likes' then return detail:loadLikes() end
                            return detail:loadReplies(parent)
                        end)}
                end
                if not parent then
                    local review=detail.review
                    opts.categories={
                        {text='回复'..(review.comments_count~=nil and (' '..review.comments_count) or ''),active=tab=='replies',
                            callback=guarded(function() tab,detail_page='replies',1;return render() end)},
                        {text='点赞者'..(review.likes_count~=nil and (' '..review.likes_count) or ''),active=tab=='likes',
                            callback=guarded(function() tab,detail_page='likes',1;return render() end)},
                    }
                end
            end
            local pages=math.max(1,math.ceil(#rows/size));page=math.max(1,math.min(page,pages))
            if mode=='list' then list_page=page else detail_page=page end
            for index=(page-1)*size+1,math.min(page*size,#rows) do
                local row=rows[index]
                local preview,_,more=Text.utf8Window(row.content or '',1,180)
                local quote=passage and mode=='list' and row.abstract and row.abstract~='' and ('原文：'..row.abstract..'\n') or ''
                opts.items[#opts.items+1]={row=row,text=Body.heading(row)..'\n'..quote..preview..(more and '…' or ''),
                    callback=guarded(function()
                        if mode=='list' then return open_detail(row) end
                        if tab=='likes' then return true end
                        if row.replies_count and row.replies_count>0 or row.sub_comments and #row.sub_comments>0
                            or row.sub_has_more==true or row.sub_has_more==1 then
                            parents[#parents+1]=row;detail_page=1;render();return detail:loadReplies(row)
                        end
                        return show_full(row)
                    end)}
            end
            local empty=opts.subtitle
            if mode=='detail' and detail.loaded and not state.loading and not state.error and #rows==0 then
                empty=tab=='likes' and '暂无已加载的点赞者' or '暂无已加载的回复'
            end
            opts.empty_text=empty
            opts.custom_body=Body.new{items=opts.items,review=opts.review,empty_text=empty,
                show_quote=passage and mode=='list',
                on_full_text=guarded(function() return show_full(opts.review) end)}
            opts.page,opts.page_count,opts.already_paginated=page,pages,true
            opts.on_prev=page>1 and guarded(function()
                if mode=='list' then list_page=page-1 else detail_page=page-1 end;return render()
            end) or nil
            opts.on_next=page<pages and guarded(function()
                if mode=='list' then list_page=page+1 else detail_page=page+1 end;return render()
            end) or nil
        end
        opts.on_request_close=function()
            if owned() then
                if mode=='list' then discussions:cancelLoad()
                elseif detail and mode~='full' then detail:cancelRequests() end
                discussions.panel_changed=nil
            end
            return false
        end
        opts.on_back=function() if owned() then return back() end;return false end
        local made,err=pcall(function() widget=presenter.library_screen_factory(opts) end)
        if not made then close_panel();return nil,{code='UI_ERROR',message=tostring(err)} end
        discussions.panel_widget,discussions.panel_close=widget,close_panel
        if mode=='full' and widget.reading_body then widget.reading_body.dialog=widget end
        discussions.panel_changed=function()
            if live() and mode~='full' then return render() end
        end
        local shown,failure=presenter:_show(widget)
        if not shown then presenter.closed_widgets[widget]=nil;close_panel();return nil,failure end
        return shown
    end
    return render()
end
return Screen
