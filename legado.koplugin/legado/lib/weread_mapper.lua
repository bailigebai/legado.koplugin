local Identity = require("legado.lib.identity")

local Mapper = {}

function Mapper.readTime(value)
    value = tonumber(value) or 0
    if value >= 1e14 then value = value / 1000000
    elseif value >= 1e11 then value = value / 1000 end
    return math.max(0, value)
end

local function text(value)
    if type(value) ~= "string" and type(value) ~= "number" then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function unwrap(row)
    if type(row) ~= "table" then return nil end
    if type(row.book) == "table" then return row.book end
    if type(row.bookInfo) == "table" then return row.bookInfo end
    return row
end

local function clamp_percent(value)
    return math.max(0, math.min(100, tonumber(value) or 0))
end

local function finished(row)
    return type(row) == "table" and (row.finishReading == 1 or row.finishReading == true)
end

local function book_percent(source, row)
    if finished(source) or finished(row) then return 100 end
    return clamp_percent(source.progress or source.readProgress or source.progressPercent or source.percent or row.progress)
end

local function has_progress(source, row)
    return finished(source) or finished(row) or source.progress ~= nil or source.readProgress ~= nil
        or source.progressPercent ~= nil or source.percent ~= nil or row.progress ~= nil
end

function Mapper.book(row, account_id)
    local source = unwrap(row)
    if not source then return nil end
    local remote_id = text(source.bookId or source.id or source.book_id)
    if remote_id == "" then return nil end
    local cover = text(source.cover or source.coverUrl)
    if not cover:match("^https?://") then cover = "" end
    return {
        id = Identity.book("weread:" .. text(account_id), remote_id),
        source_id = "weread", source_name = "微信读书", remote_id = remote_id,
        weread_account_id = text(account_id),
        name = text(source.title or source.bookName or source.name),
        author = text(source.author or source.authors),
        cover_url = cover, intro = text(source.intro or source.description or source.summary),
        kind = text(source.category),
        progress_percent = book_percent(source, row),
        read_at = math.max(Mapper.readTime(source.readUpdateTime), Mapper.readTime(row.readUpdateTime),
            Mapper.readTime(source.readTime), Mapper.readTime(row.readTime)),
    }
end

function Mapper.shelf(wire, account_id)
    wire = type(wire) == "table" and wire or {}
    local progress = {}
    for _, row in ipairs(type(wire.bookProgress) == "table" and wire.bookProgress or {}) do
        if type(row) == "table" and row.bookId ~= nil then progress[tostring(row.bookId)] = row end
    end
    local recent = {}
    for index, row in ipairs(type(wire.recentBooks) == "table" and wire.recentBooks or {}) do
        local source = unwrap(row)
        local id = source and (source.bookId or source.id or source.book_id)
        if id ~= nil and recent[tostring(id)] == nil then recent[tostring(id)] = index end
    end
    local rows, seen, order = {}, {}, 0
    local function append(list)
        for _, row in ipairs(type(list) == "table" and list or {}) do
            local book = Mapper.book(row, account_id)
            if book and seen[book.remote_id] then
                local existing = seen[book.remote_id]
                if not progress[book.remote_id] and has_progress(unwrap(row), row) then
                    existing.progress_percent = book.progress_percent end
                existing.read_at = math.max(existing.read_at, book.read_at)
            elseif book then
                order = order + 1
                seen[book.remote_id] = book
                local state = progress[book.remote_id]
                if state then
                    if state.progress ~= nil or state.readProgress ~= nil then
                        book.progress_percent = clamp_percent(state.progress or state.readProgress)
                    end
                    if finished(state) then book.progress_percent = 100 end
                    book.read_at = math.max(book.read_at, Mapper.readTime(state.readUpdateTime
                        or state.readTime or state.updateTime or state.updatedAt))
                end
                book._order = order
                rows[#rows + 1] = book
            end
        end
    end
    append(wire.books)
    append(wire.recentBooks)
    append(wire.finishReadBooks)
    append(type(wire.data) == "table" and wire.data.books or nil)
    table.sort(rows, function(a, b)
        if a.read_at ~= b.read_at then return a.read_at > b.read_at end
        local ar, br = recent[a.remote_id], recent[b.remote_id]
        if ar ~= br then
            if ar == nil then return false end
            if br == nil then return true end
            return ar < br
        end
        return a._order < b._order
    end)
    for _, book in ipairs(rows) do book._order = nil end
    return rows
end

function Mapper.chapters(wire, book)
    local records=type(wire)=='table' and (wire.data or wire) or nil
    if type(records)~='table' then return nil,'微信读书目录无效' end
    if records.bookId or records.updated then records={records} end
    local entry
    for _,candidate in ipairs(records) do
        if type(candidate)=='table' and tostring(candidate.bookId or '')==book.remote_id then entry=candidate;break end
    end
    if not entry then return nil,'微信读书目录缺少当前书籍' end
    local raw=entry.updated or entry.chapterInfos or entry.chapters
    if type(raw)~='table' then return nil,'微信读书目录为空' end
    local rows={}
    for _,chapter in ipairs(raw) do
        if type(chapter)=='table' and tonumber(chapter.wordCount or 1)>0 and chapter.title~='封面' then
            local uid=tostring(chapter.chapterUid or chapter.uid or '')
            if uid~='' then rows[#rows+1]={remote_uid=uid,source_index=tonumber(chapter.chapterIdx or chapter.idx) or #rows+1,
                title=tostring(chapter.title or ''),paid=chapter.paid==1,price=tonumber(chapter.price) or 0,
                resource_tar=type(chapter.tar)=='string' and chapter.tar or nil} end
        end
    end
    table.sort(rows,function(a,b) return a.source_index<b.source_index end)
    local chapters={}
    for index,row in ipairs(rows) do
        chapters[index]={uid=Identity.chapter(book.id,row.remote_uid,index),index=index,
            source_id='weread',book_id=book.id,title=row.title~='' and row.title or ('第'..index..'章'),
            url='weread://book/'..book.remote_id..'/chapter/'..row.remote_uid,
            remote_uid=row.remote_uid,source_index=row.source_index,paid=row.paid,price=row.price,
            resource_tar=row.resource_tar}
    end
    if #chapters==0 then return nil,'微信读书目录为空' end
    return chapters
end

function Mapper.progress(wire,chapters)
    local root=type(wire)=='table' and (wire.data or wire) or {}
    local node=type(root.book)=='table' and root.book or root
    local uid=tostring(node.chapterUid or node.chapter_uid or '')
    local fraction=tonumber(node.chapterOffset or node.chapter_fraction) or 0
    if fraction>1 then fraction=fraction/10000 end
    fraction=math.max(0,math.min(1,fraction))
    for index,chapter in ipairs(chapters or {}) do
        if chapter.remote_uid==uid then return index,fraction end
    end
    return nil
end

local function review_count(value)
    if type(value)=='number' and value==value and value>=0 and value<=9007199254740991 and value%1==0 then
        return value
    end
end
Mapper.discussionCount=review_count
local function review_avatar(value)
    if type(value)~='string' or #value>2048 or value:find('[%c%s\\]') then return nil end
    local host,path=value:match('^https://([^/]+)(/.*)$')
    if path and (host=='res.weread.qq.com' or host=='thirdwx.qlogo.cn' or host=='wx.qlogo.cn') then
        return value
    end
end
Mapper.avatarUrl=review_avatar
local function discussion_plain(value,limit)
    if type(value)~='string' or #value>(limit or 65536) then return '' end
    return require('legado.lib.leko_text').plainText(value)
end
local function discussion_author(row)
    local author=type(row.author)=='table' and row.author or row
    return discussion_plain(author.name or author.nickname or author.nick,1024),
        review_avatar(author.avatar),text(author.userVid or author.vid or row.userVid)
end
function Mapper.inlineComments(wire,book_id,chapter_uid,model)
    local Text=require('legado.lib.leko_text')
    local rows={}
    for _,row in ipairs(type(wire)=='table' and type(wire.reviews)=='table' and wire.reviews or {}) do
        if type(row)=='table' and (not row.book_id or tostring(row.book_id)==tostring(book_id))
            and (not row.chapter_uid or tostring(row.chapter_uid)==tostring(chapter_uid)) then
            local content=discussion_plain(row.htmlContent)
            if content=='' then content=discussion_plain(row.content) end
            local abstract=discussion_plain(row.abstract)
            local author,avatar,author_id=discussion_author(row)
            rows[#rows+1]={id=text(row.id),range=row.range,abstract=abstract,
                content=content~='' and content or '无文字评论',author=author,avatar_url=avatar,author_id=author_id,
                likes_count=review_count(row.likesCount),comments_count=review_count(row.commentsCount),
                detail_available=row.detail_available,
                position=model and Text.locateQuote(model,abstract,row.range) or nil}
        end
    end
    return rows
end
function Mapper.chapterDiscussions(wire,book_id,chapter_uid)
    local Text=require('legado.lib.leko_text')
    local rows,seen={},{}
    local function plain(value)
        if type(value)~='string' or #value>65536 then return '' end
        return Text.plainText(value)
    end
    local function belongs(value)
        return type(value)=='table' and (value.bookId==nil or tostring(value.bookId)==tostring(book_id))
            and (value.chapterUid==nil or tostring(value.chapterUid)==tostring(chapter_uid))
    end
    for _,outer in ipairs(type(wire)=='table' and type(wire.reviews)=='table' and wire.reviews or {}) do
        local row=type(outer)=='table' and outer.review
        if belongs(outer) and belongs(row) then
            local content=plain(row.htmlContent)
            if content=='' then content=plain(row.content) end
            local id=text(row.reviewId or row.id or outer.reviewId)
            if content~='' and (id=='' or not seen[id]) then
                seen[id]=true
                local author,avatar,author_id=discussion_author(row)
                rows[#rows+1]={id=id,content=content,abstract=plain(row.abstract),
                    author=author,avatar_url=avatar,author_id=author_id,
                    likes_count=review_count(outer.likesCount),comments_count=review_count(outer.commentsCount)}
                if #rows>=100 then break end
            end
        end
    end
    return rows
end

function Mapper.discussionDetail(wire,book_id,chapter_uid,review_id)
    local row=Mapper.chapterDiscussions({reviews={wire}},book_id,chapter_uid)[1]
    if row and row.id==review_id then return row end
end

function Mapper.discussionReplies(wire,review_id)
    local rows,seen={},{}
    local function append(collection)
        for _,row in ipairs(type(collection)=='table' and collection or {}) do
            if type(row)=='table' and (row.reviewId==nil or tostring(row.reviewId)==review_id) then
                local id=text(row.commentId)
                local content=discussion_plain(row.content)
                if id~='' and #id<=512 and content~='' and not seen[id] then
                    seen[id]=true
                    local author,avatar,author_id=discussion_author(row)
                    rows[#rows+1]={id=id,content=content,author=author,avatar_url=avatar,author_id=author_id,
                        likes_count=review_count(row.likesCount),replies_count=review_count(row.subCommentsCount),
                        reply_to=type(row.replyUser)=='table' and discussion_plain(row.replyUser.name,1024) or '',
                        sub_comments=type(row.subComments)=='table' and row.subComments or nil,
                        sub_has_more=row.subCommentsHasMore,create_time=review_count(row.createTime)}
                    if #rows>=100 then return end
                end
            end
        end
    end
    wire=type(wire)=='table' and wire or {}
    append(wire.hotComments);if #rows<100 then append(wire.comments) end
    return rows
end

function Mapper.discussionLikes(wire)
    local rows,seen={},{}
    for _,row in ipairs(type(wire)=='table' and type(wire.likes)=='table' and wire.likes or {}) do
        if type(row)=='table' then
            local author,avatar,id=discussion_author(row)
            if id~='' and #id<=512 and author~='' and not seen[id] then
                seen[id]=true;rows[#rows+1]={id=id,author=author,avatar_url=avatar,author_id=id,content=''}
                if #rows>=100 then break end
            end
        end
    end
    return rows
end

return Mapper
