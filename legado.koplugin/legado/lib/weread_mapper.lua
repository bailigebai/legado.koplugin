local Identity = require("legado.lib.identity")

local Mapper = {}

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
        name = text(source.title or source.bookName or source.name),
        author = text(source.author or source.authors),
        cover_url = cover, intro = text(source.intro or source.description or source.summary),
        kind = text(source.category),
    }
end

function Mapper.shelf(wire, account_id)
    wire = type(wire) == "table" and wire or {}
    local progress = {}
    for _, row in ipairs(type(wire.bookProgress) == "table" and wire.bookProgress or {}) do
        if type(row) == "table" and row.bookId ~= nil then progress[tostring(row.bookId)] = row end
    end
    local rows, seen, order = {}, {}, 0
    local function append(list)
        for _, row in ipairs(type(list) == "table" and list or {}) do
            local book = Mapper.book(row, account_id)
            if book and not seen[book.remote_id] then
                order = order + 1
                seen[book.remote_id] = true
                local state = progress[book.remote_id]
                if state then
                    local percent = tonumber(state.progress or state.readProgress) or 0
                    book.progress_percent = math.max(0, math.min(100, percent))
                    book.read_at = tonumber(state.updateTime or state.updatedAt or state.readTime) or 0
                else
                    book.progress_percent, book.read_at = 0, 0
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
        if a.read_at == b.read_at then return a._order < b._order end
        return a.read_at > b.read_at
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
                title=tostring(chapter.title or ''),paid=chapter.paid==1,price=tonumber(chapter.price) or 0} end
        end
    end
    table.sort(rows,function(a,b) return a.source_index<b.source_index end)
    local chapters={}
    for index,row in ipairs(rows) do
        chapters[index]={uid=Identity.chapter(book.id,row.remote_uid,index),index=index,
            source_id='weread',book_id=book.id,title=row.title~='' and row.title or ('第'..index..'章'),
            url='weread://book/'..book.remote_id..'/chapter/'..row.remote_uid,
            remote_uid=row.remote_uid,source_index=row.source_index,paid=row.paid,price=row.price}
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
    return 1,0
end

return Mapper
