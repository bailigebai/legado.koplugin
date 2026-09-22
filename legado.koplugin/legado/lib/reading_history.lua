local Errors = require("legado.lib.errors")

local ReadingHistory = {}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

local function seconds(value)
    value = finite(value)
    return value and value >= 0 and value or nil
end

local function leap_year(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function valid_date(value)
    if type(value) ~= "string" then return false end
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or year < 1 or not month or month < 1 or month > 12 or not day or day < 1 then return false end
    local month_days = ({ 31, leap_year(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[month]
    return day <= month_days
end

local function clean_daily(value)
    local result = {}
    if type(value) ~= "table" then return result end
    for date, daily_seconds in pairs(value) do
        daily_seconds = seconds(daily_seconds)
        if valid_date(date) and daily_seconds and daily_seconds > 0 then result[date] = daily_seconds end
    end
    return result
end

local function add_seconds(left, right)
    local result = left + right
    return seconds(result) or left
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    seen[value] = nil
    return result
end

local SNAPSHOT_FIELDS = { "id", "name", "author", "source_id", "cover_url", "is_local", "local_path" }

local function snapshot(progress, book)
    local result = copy(progress.book_snapshot or {})
    for _, field in ipairs(SNAPSHOT_FIELDS) do
        if book and book[field] ~= nil then result[field] = copy(book[field]) end
    end
    result.id = result.id or progress.book_id
    return result
end

local function date_key(value)
    return os.date("%Y-%m-%d", value)
end

local function add_daily(daily, started_at, finished_at)
    local cursor = tonumber(started_at)
    local finish = tonumber(finished_at)
    if not cursor or not finish or finish <= cursor then return end
    while cursor < finish do
        local key = date_key(cursor)
        if key == date_key(finish) then
            daily[key] = add_seconds(daily[key] or 0, finish - cursor)
            break
        end
        local parts = os.date("*t", cursor)
        local boundary = os.time({ year = parts.year, month = parts.month, day = parts.day + 1,
            hour = 0, min = 0, sec = 0 })
        if type(boundary) ~= "number" or boundary <= cursor or boundary >= finish then
            daily[key] = add_seconds(daily[key] or 0, finish - cursor)
            break
        end
        daily[key] = add_seconds(daily[key] or 0, boundary - cursor)
        cursor = boundary
    end
end

function ReadingHistory.record(previous, book, started_at, finished_at)
    local progress = copy(previous or {})
    progress.book_id = progress.book_id or (book and book.id)
    progress.reading_seconds = seconds(progress.reading_seconds) or 0
    progress.reading_daily = clean_daily(progress.reading_daily)
    progress.book_snapshot = snapshot(progress, book)
    local start = finite(started_at)
    local finish = finite(finished_at)
    if start and finish and finish > start then
        progress.reading_seconds = add_seconds(progress.reading_seconds, finish - start)
        add_daily(progress.reading_daily, start, finish)
    end
    return progress
end

local function clamp(value)
    value = tonumber(value)
    if not value then return nil end
    return math.max(0, math.min(1, value))
end

local function receipt_book(book, progress)
    local result = snapshot(progress, book)
    result.id = result.id or progress.book_id
    return result
end

function ReadingHistory.book(book, progress)
    progress = progress or {}
    local value = receipt_book(book, progress)
    local chapter_index = math.max(0, tonumber(progress.chapter_index) or 0)
    local chapter_count = math.max(0, tonumber(progress.chapter_count) or 0)
    local chapter_fraction = clamp(progress.fraction)
    local fraction
    local position_label
    local position_text
    local progress_text
    if value.is_local then
        fraction = chapter_fraction
        position_label = "页码位置"
        local page_index, page_count = tonumber(progress.page_index), tonumber(progress.page_count)
        position_text = page_index and page_count and string.format("%d / %d", page_index, page_count) or "暂无记录"
        progress_text = fraction and string.format("%.1f%%", fraction * 100) or "暂无进度"
    else
        position_label = "章节位置"
        position_text = chapter_index > 0 and string.format("%d / %s", chapter_index,
            chapter_count > 0 and tostring(chapter_count) or "未知") or "暂无记录"
        if progress.catalog_complete == true and chapter_count > 0 and chapter_index > 0 then
            fraction = clamp((chapter_index - 1 + (chapter_fraction or 0)) / chapter_count)
        end
        progress_text = fraction and string.format("约 %.1f%%", fraction * 100)
            or (chapter_index > 0 and "目录待确认" or "暂无进度")
    end

    local daily = clean_daily(progress.reading_daily)
    local day_count, start_date = 0
    for date, seconds in pairs(daily) do
        if (tonumber(seconds) or 0) > 0 then
            day_count = day_count + 1
            if not start_date or date < start_date then start_date = date end
        end
    end
    local seconds = seconds(progress.reading_seconds) or 0
    local status = progress.reading_status_override
    if not status then
        if fraction and fraction >= 1 then status = "finished"
        elseif seconds > 0 or chapter_index > 0 or (chapter_fraction and chapter_fraction > 0) then status = "reading"
        else status = "unread" end
    end
    local updated_at = tonumber(progress.updated_at)
    local date_text = "暂无记录"
    if updated_at then
        local ok, formatted = pcall(os.date, "%Y-%m-%d", updated_at)
        if ok then date_text = formatted end
    end

    return {
        book = value,
        progress = copy(progress),
        seconds = seconds,
        total_seconds = seconds,
        day_count = day_count,
        fraction = fraction,
        progress_text = progress_text,
        position_label = position_label,
        position_text = position_text,
        chapter_title = progress.chapter_title or (chapter_index > 0 and ("第 " .. chapter_index .. " 章") or "未开始"),
        status = status,
        rating = tonumber(progress.reading_rating) or 0,
        comment = type(progress.reading_comment) == 'string' and progress.reading_comment or '',
        start_date = start_date,
        today_seconds = daily[os.date('%Y-%m-%d')] or 0,
        chapter_fraction = not value.is_local and chapter_fraction or nil,
        date_text = date_text,
        receipt_id = tostring(value.id or progress.book_id or "READING"),
        updated_at = updated_at,
    }
end

function ReadingHistory.collect(storage, book_id)
    if not storage or type(storage.listProgress) ~= "function" then
        return nil, Errors.new(Errors.STORAGE_ERROR, "reading progress storage is unavailable")
    end
    local values, error_value = storage:listProgress()
    if not values then return nil, error_value end
    local report = { total_seconds = 0, reading_days = 0, average_seconds = 0,
        unattributed_seconds = 0, daily = {}, records = {} }
    for _, progress in ipairs(values) do
        if book_id == nil or progress.book_id == book_id then
            local book_seconds = seconds(progress.reading_seconds) or 0
            report.total_seconds = add_seconds(report.total_seconds, book_seconds)
            for date, value in pairs(clean_daily(progress.reading_daily)) do
                report.daily[date] = add_seconds(report.daily[date] or 0, value)
            end
            local book = progress.book_snapshot
            if (not book or not book.name or book.name == "") and type(storage.getBook) == "function" then
                local stored_book, book_error = storage:getBook(progress.book_id)
                if book_error then return nil, book_error end
                book = stored_book or book
            end
            report.records[#report.records + 1] = ReadingHistory.book(book, progress)
        end
    end
    local attributed = 0
    for _, seconds in pairs(report.daily) do
        if seconds > 0 then report.reading_days = report.reading_days + 1 end
        attributed = attributed + seconds
    end
    report.average_seconds = report.reading_days > 0 and report.total_seconds / report.reading_days or 0
    report.unattributed_seconds = math.max(0, report.total_seconds - attributed)
    table.sort(report.records, function(left, right)
        if (left.updated_at or 0) ~= (right.updated_at or 0) then return (left.updated_at or 0) > (right.updated_at or 0) end
        return tostring(left.book.name or left.book.id or "") < tostring(right.book.name or right.book.id or "")
    end)
    return report
end

function ReadingHistory.overview(report, year, now)
    report = report or {}
    year = tonumber(year) or tonumber(os.date("%Y", now))
    now = now or os.time()
    local months = {}
    for month = 1, 12 do months[month] = { label = month .. "月", seconds = 0 } end
    local daily = clean_daily(report.daily)
    for date, daily_seconds in pairs(daily) do
        local y, month = date:match("^(%d%d%d%d)%-(%d%d)%-%d%d$")
        if tonumber(y) == year then
            local entry = months[tonumber(month)]
            entry.seconds = add_seconds(entry.seconds, daily_seconds)
        end
    end
    local today = os.date("*t", now)
    local monday_offset = (today.wday + 5) % 7
    local labels = { "周一", "周二", "周三", "周四", "周五", "周六", "周日" }
    local week, week_seconds = {}, 0
    for index = 1, 7 do
        local stamp = os.time({ year = today.year, month = today.month,
            day = today.day - monday_offset + index - 1, hour = 12, min = 0, sec = 0 })
        local date = date_key(stamp)
        week[index] = { label = labels[index], date = date, seconds = daily[date] or 0 }
        week_seconds = add_seconds(week_seconds, daily[date] or 0)
    end
    return { year = year, total_seconds = report.total_seconds or 0, reading_days = report.reading_days or 0,
        average_seconds = report.average_seconds or 0, unattributed_seconds = report.unattributed_seconds or 0,
        months = months, week = week, week_average_seconds = week_seconds / 7 }
end

function ReadingHistory.calendar(report, year, month, selected_day, now)
    report = report or {}
    local daily = clean_daily(report.daily)
    now = now or os.time()
    local current = os.date("*t", now)
    year, month = tonumber(year) or current.year, tonumber(month) or current.month
    local first_stamp = os.time({ year = year, month = month, day = 1, hour = 12, min = 0, sec = 0 })
    local first = os.date("*t", first_stamp)
    year, month = first.year, first.month
    local days = os.date("*t", os.time({ year = year, month = month + 1, day = 0, hour = 12, min = 0, sec = 0 })).day
    local offset = (first.wday + 5) % 7
    local today = date_key(now)
    selected_day = selected_day or (current.year == year and current.month == month and today
        or string.format("%04d-%02d-01", year, month))
    local calendar = {}
    for index = 1, 42 do
        local day = index - offset
        if day >= 1 and day <= days then
            local date = string.format("%04d-%02d-%02d", year, month, day)
            calendar[index] = { day = day, date = date, seconds = daily[date] or 0,
                is_today = date == today }
        else
            calendar[index] = { day = nil, date = nil, seconds = 0, is_today = false }
        end
    end
    local day_books = {}
    for _, record in ipairs(report.records or {}) do
        local daily_seconds = clean_daily(record.progress and record.progress.reading_daily)[selected_day] or 0
        if daily_seconds > 0 then day_books[#day_books + 1] = { book = record.book, seconds = daily_seconds,
            fraction = record.fraction, progress_text = record.progress_text } end
    end
    table.sort(day_books, function(left, right)
        if left.seconds ~= right.seconds then return left.seconds > right.seconds end
        return tostring(left.book.name or left.book.id or "") < tostring(right.book.name or right.book.id or "")
    end)
    local month_days = 0
    local prefix = string.format("%04d-%02d-", year, month)
    for date, daily_seconds in pairs(daily) do
        if date:sub(1, #prefix) == prefix and daily_seconds > 0 then month_days = month_days + 1 end
    end
    return { year = year, month = month, selected_day = selected_day, calendar = calendar,
        day_total = daily[selected_day] or 0, day_books = day_books, month_days = month_days }
end

function ReadingHistory.setReview(storage, book, field, value)
    if not storage or type(storage.getProgress) ~= "function" or type(storage.putProgress) ~= "function" then
        return nil, Errors.new(Errors.STORAGE_ERROR, "reading progress storage is unavailable")
    end
    if field == "rating" then
        value = tonumber(value)
        if not value or value % 1 ~= 0 or value < 0 or value > 5 then
            return nil, Errors.new(Errors.INVALID_INPUT, "rating must be an integer from 0 to 5")
        end
    elseif field == "status" then
        if value ~= nil and value ~= "reading" and value ~= "paused" and value ~= "finished" then
            return nil, Errors.new(Errors.INVALID_INPUT, "invalid reading status")
        end
    elseif field == "comment" then
        if type(value) ~= 'string' or #value > 6000 or value:find('%z') then
            return nil, Errors.new(Errors.INVALID_INPUT, 'comment must be text up to 6000 bytes without null characters')
        end
    else
        return nil, Errors.new(Errors.INVALID_INPUT, "invalid review field")
    end
    local previous, error_value = storage:getProgress(book.id)
    if error_value then return nil, error_value end
    local progress = ReadingHistory.record(previous, book)
    if field == "rating" then progress.reading_rating = value
    elseif field == "comment" then progress.reading_comment = value
    else progress.reading_status_override = value end
    return storage:putProgress(progress)
end

return ReadingHistory
