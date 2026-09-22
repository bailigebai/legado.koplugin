-- Reading views share LibraryScreen's navigation and cover-request lifetime.
local ReadingScreen = {}
local Safe = require("legado.lib.safe_functions")

local function clean(value, fallback)
    value = Safe.functions.htmldecode(tostring(value or ""))
    return value:match("%S") and value or fallback or ""
end

local function duration(seconds, clock)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours, minutes = math.floor(seconds/3600), math.floor(seconds/60)%60
    if clock then return string.format("%d:%02d:%02d",hours,minutes,seconds%60) end
    if hours>0 then return hours.."小时"..minutes.."分" end
    if minutes>0 then return minutes.."分"..(seconds%60>0 and seconds%60 .."秒" or "") end
    return seconds.."秒"
end

function ReadingScreen.new(options)
    options = options or {}
    local model = options.reading_model or {kind="overview"}
    local display = {}; for key,value in pairs(options) do display[key]=value end
    display.compact = true
    display.custom_body = function(ctx)
        local d,s = ctx.deps,ctx.scale
        local w,h = ctx.width,ctx.height
        local black,white,gray = d.colors.COLOR_BLACK,d.colors.COLOR_WHITE,d.colors.COLOR_DARK_GRAY
        local rows = {}
        local Canvas = d.input:extend{}
        function Canvas:paintTo(bb,x,y)
            self.dimen.x,self.dimen.y=x,y
            for _,draw in ipairs(self.ink) do draw(bb,x,y) end
            for i,widget in ipairs(self) do widget:paintTo(bb,x+self.spots[i][1],y+self.spots[i][2]) end
            if self.focused then bb:paintBorder(x,y,self.dimen.w,self.dimen.h,s(2),black) end
        end
        function Canvas:onFocus() self.focused=true;d.ui:setDirty(nil,"ui");return true end
        function Canvas:onUnfocus() self.focused=false;d.ui:setDirty(nil,"ui");return true end
        function Canvas:onTapSelect() return self.callback and self.callback() end
        local function canvas(width,height)
            return Canvas:new{dimen=d.geom:new{w=math.floor(width),h=math.floor(height)},ink={},spots={}}
        end
        local root=canvas(w,h)
        local function put(parent,child,x,y)
            parent[#parent+1]=child;parent.spots[#parent.spots+1]={math.floor(x),math.floor(y)};return child
        end
        local function rect(parent,x,y,width,height,color,border,radius)
            parent.ink[#parent.ink+1]=function(bb,ox,oy)
                if border then bb:paintBorder(ox+x,oy+y,width,height,border,color or black,radius)
                elseif radius then bb:paintRoundedRect(ox+x,oy+y,width,height,color or black,radius)
                else bb:paintRect(ox+x,oy+y,width,height,color or black) end
            end
        end
        local function circle(parent,x,y,r,color,border)
            parent.ink[#parent.ink+1]=function(bb,ox,oy) bb:paintCircle(ox+x,oy+y,r,color,border) end
        end
        local function text(parent,value,x,y,width,size,bold,center,height)
            local widget
            if height then
                widget=d.textbox:new{text=clean(value),face=d.font:getFace("cfont",size),width=width,height=height,
                    height_adjust=false,line_height=0,lines_per_page=2,height_overflow_show_ellipsis=true,
                    alignment=center and "center" or "left",bold=bold}
            else
                widget=d.text:new{text=clean(value),face=d.font:getFace("cfont",size),max_width=width,bold=bold}
            end
            if center then x=x+math.max(0,math.floor((width-widget:getSize().w)/2)) end
            return put(parent,widget,x,y)
        end
        local function callback(fn,value)
            return function()
                if fn then
                    local ok,result=pcall(fn,value)
                    if not ok then if options.on_error then options.on_error(result) end;return false end
                end
                return true
            end
        end
        local function button(parent,title,x,y,width,height,fn,value,active,size)
            local control=d.button:new{text=title,width=width,height=height,text_font_size=size or 15,
                padding=s(2),bordersize=s(1),radius=s(7),avoid_text_truncation=false,
                background=active==true and d.colors.COLOR_LIGHT_GRAY or nil,callback=callback(fn,value)}
            return put(parent,control,x,y)
        end
        local function tappable(parent,x,y,width,height,fn,value)
            local box=canvas(width,height)
            box.callback=callback(fn,value)
            box.ges_events.TapSelect={d.gesture:new{ges="tap",range=function() return box.dimen end}}
            return put(parent,box,x,y)
        end
        local function panel(x,y,width,height)
            local box=put(root,canvas(width,height),x,y)
            rect(box,0,0,width,height,gray,s(1),model.kind~='receipt' and s(8) or 0)
            return box
        end
        local function period(parent,title,y)
            local bw,bh=s(62),s(30)
            local left=button(parent,"‹",s(12),y,bw,bh,model.on_period_change,-1)
            text(parent,title,bw+s(20),y+s(4),parent.dimen.w-2*bw-s(40),17,true,true)
            local right=button(parent,"›",parent.dimen.w-bw-s(12),y,bw,bh,model.on_period_change,1)
            rows[#rows+1]={left,right}
        end
        local function book_name(book) return clean(book and (book.name or book.title),"未命名书籍") end
        local function cover(parent,book,x,y,width,height)
            local slot=put(parent,ctx.cover_widget(nil,width,height),x,y)
            local index=#parent
            local cell={book=book,cover=slot,visual=parent,button=parent}
            ctx.cells[#ctx.cells+1]=cell
            if book then ctx.request_cover(book,function(path)
                local old=cell.cover
                local replacement=ctx.cover_widget(path,width,height)
                parent[index],cell.cover=replacement,replacement
                if old and old.free then old:free() end
                d.ui:setDirty(nil,"ui")
            end) end
            return cell
        end
        local function bars(parent,records,x,y,width,height)
            local max_seconds=1
            for _,record in ipairs(records) do max_seconds=math.max(max_seconds,tonumber(record.seconds) or 0) end
            local step=width/math.max(1,#records)
            local baseline=y+height-s(24)
            rect(parent,x,baseline,width,s(1),black)
            for i,record in ipairs(records) do
                local seconds=math.max(0,tonumber(record.seconds) or 0)
                local bar_h=seconds>0 and math.max(s(2),math.floor((height-s(45))*seconds/max_seconds)) or 0
                local bw=math.max(s(3),math.floor(step*.48))
                local bx=math.floor(x+(i-1)*step+(step-bw)/2)
                if bar_h>0 then
                    rect(parent,bx,baseline-bar_h,bw,bar_h,i==#records and black or gray)
                    text(parent,seconds>=60 and tostring(math.floor(seconds/60)).."分" or seconds.."秒",
                        x+(i-1)*step,baseline-bar_h-s(17),step,10,false,true)
                end
                text(parent,record.label or tostring(i),x+(i-1)*step,baseline+s(5),step,11,false,true)
            end
        end

        if model.kind=="overview" then
            local summary_h=math.floor(h*.27)
            local summary=panel(0,0,w,summary_h)
            text(summary,"总阅读时长",s(14),s(10),w-s(28),15)
            text(summary,duration(model.total_seconds),s(14),s(37),w-s(28),32,true)
            local divider=math.floor(summary_h*.62)
            rect(summary,s(14),divider,w-s(28),s(1),gray)
            text(summary,tostring(model.reading_days or 0).."天",0,divider+s(8),w/2,18,true,true)
            text(summary,duration(model.average_seconds),w/2,divider+s(8),w/2,18,true,true)
            text(summary,"阅读天数",0,divider+s(33),w/2,12,false,true)
            text(summary,"日均",w/2,divider+s(33),w/2,12,false,true)
            local chart_y=summary_h+s(10)
            local note_h=(tonumber(model.unattributed_seconds) or 0)>0 and s(25) or 0
            local charts=panel(0,chart_y,w,h-chart_y-note_h)
            text(charts,"每月阅读时长",s(14),s(11),w/2,15,true)
            local bw=s(52)
            rows[#rows+1]={button(charts,"‹",w*.48,s(6),bw,s(29),model.on_period_change,-1),
                button(charts,"›",w-bw-s(14),s(6),bw,s(29),model.on_period_change,1)}
            text(charts,tostring(model.year or os.date("%Y")).."年",w*.48+bw,s(11),w*.52-2*bw-s(14),16,true,true)
            local mid=math.floor(charts.dimen.h*.52)
            local months=model.months or {}; if #months==0 then for i=1,12 do months[i]={label=i.."月",seconds=0} end end
            bars(charts,months,s(14),s(45),w-s(28),mid-s(48))
            rect(charts,s(14),mid,w-s(28),s(1),gray)
            text(charts,"本周阅读时长",s(14),mid+s(10),w/2-s(14),15,true)
            text(charts,"日均 "..duration(model.week_average_seconds).."（7天）",w/2,mid+s(10),w/2-s(14),12,false,true)
            local week=model.week or {};if #week==0 then for _,day in ipairs{"一","二","三","四","五","六","日"} do week[#week+1]={label="周"..day,seconds=0} end end
            bars(charts,week,s(14),mid+s(38),w-s(28),charts.dimen.h-mid-s(42))
            if note_h>0 then text(root,"其中 "..duration(model.unattributed_seconds).." 为旧记录，未按日记录",s(8),h-note_h+s(5),w-s(16),11) end
        elseif model.kind=="daily" then
            local cal_h=math.floor(h*.67)
            local calendar=panel(0,0,w,cal_h)
            period(calendar,tostring(model.year or os.date("%Y")).."年"..tostring(model.month or os.date("%m")).."月",s(10))
            local cw=(w-s(24))/7
            for i,day in ipairs{"一","二","三","四","五","六","日"} do text(calendar,day,s(12)+(i-1)*cw,s(48),cw,14,true,true) end
            local row_h=math.floor((cal_h-s(104))/6)
            for row=0,5 do
                local focus_row={}
                for column=0,6 do
                    local record=(model.calendar or {})[row*7+column+1] or {}
                    if record.day and record.date then
                        local selected=record.date==model.selected_day
                        local box=tappable(calendar,s(12)+column*cw,s(76)+row*row_h,cw-s(3),row_h-s(2),model.on_day,record.date)
                        box.text=tostring(record.day)
                        if selected then rect(box,0,0,box.dimen.w,box.dimen.h,black,nil,s(6)) end
                        local day=text(box,tostring(record.day),0,s(1),box.dimen.w,17,true,true)
                        if selected then day.fgcolor=white end
                        if (tonumber(record.seconds) or 0)>0 then
                            local time=text(box,duration(record.seconds),0,s(24),box.dimen.w,10,false,true)
                            if selected then time.fgcolor=white end
                        elseif record.is_today then rect(box,box.dimen.w/2-s(9),box.dimen.h-s(3),s(18),s(2),selected and white or gray) end
                        focus_row[#focus_row+1]=box
                    end
                end
                if #focus_row>0 then rows[#rows+1]=focus_row end
            end
            rect(calendar,s(14),cal_h-s(27),w-s(28),s(1),gray)
            text(calendar,"本月阅读 "..tostring(model.month_days or 0).." 天",s(14),cal_h-s(21),w-s(28),12,true)
            local y=cal_h+s(10)
            local day=panel(0,y,w,h-y)
            text(day,clean(model.selected_day,"今日").." 阅读详情",s(14),s(9),w-s(28),15,true)
            text(day,"共 "..duration(model.day_total),s(14),s(34),w-s(28),21,true)
            local records=model.day_books or {}
            if #records==0 then text(day,"当天暂无阅读记录",s(14),s(76),w-s(28),14) end
            local row_height=math.min(s(36),math.floor((day.dimen.h-s(72))/math.max(1,#records)))
            for i,record in ipairs(records) do
                local box=tappable(day,s(14),s(72)+(i-1)*row_height,w-s(28),row_height,model.on_book,record.book)
                rect(box,0,0,box.dimen.w,s(1),gray)
                text(box,book_name(record.book),0,s(6),box.dimen.w*.73,13)
                text(box,duration(record.seconds),box.dimen.w*.75,s(6),box.dimen.w*.25,12,true,true)
                ctx.cells[#ctx.cells+1]={book=record.book,visual=box,button=box}
                rows[#rows+1]={box}
            end
        elseif model.kind=="books" then
            local box=panel(0,0,w,h)
            text(box,"已阅读书籍",s(14),s(12),w-s(28),17,true)
            local records=model.records or {}
            if #records==0 then text(box,"还没有阅读记录",s(14),h*.42,w-s(28),18,false,true) end
            local gap=s(12)
            local cw=math.floor((w-s(28)-gap*2)/3)
            local ch=math.floor((h-s(58)-gap)/2)
            for i,record in ipairs(records) do
                local column,row=(i-1)%3,math.floor((i-1)/3)
                local card=tappable(box,s(14)+column*(cw+gap),s(43)+row*(ch+gap),cw,ch,model.on_book,record.book)
                local cover_h=ch-s(74)
                rect(card,0,0,cw,cover_h,gray,s(1),s(5))
                local cover_w=math.min(cw-s(6),math.floor(cover_h*.7))
                local cell=cover(card,record.book,(cw-cover_w)/2,s(1),cover_w,cover_h-s(2))
                cell.title_widget=text(card,book_name(record.book),0,cover_h+s(5),cw,13,true,false,s(34))
                text(card,duration(record.seconds).." · "..clean(record.progress_text,"进度未知"),0,ch-s(29),cw,10)
                rect(card,0,ch-s(8),cw,s(4),gray)
                if tonumber(record.fraction) then rect(card,0,ch-s(8),math.floor(cw*math.max(0,math.min(1,record.fraction))),s(4),black) end
                local focus_index=row+1
                rows[focus_index]=rows[focus_index] or {};rows[focus_index][#rows[focus_index]+1]=card
            end
        else
            -- Ticket ornament is drawn locally; the barcode is decorative, not an encoded identifier.
            local inset=s(18)
            local ticket=panel(inset,s(8),w-2*inset,h-s(16))
            local tw,th=ticket.dimen.w,ticket.dimen.h
            local radius=s(6)
            for x=radius,tw-radius,radius*2 do
                circle(ticket,x,0,radius,gray,s(1));circle(ticket,x,0,radius-s(1),white)
                circle(ticket,x,th,radius,gray,s(1));circle(ticket,x,th,radius-s(1),white)
            end
            rect(ticket,0,-radius,tw,radius+s(1),white)
            rect(ticket,0,th,tw,radius+s(1),white)
            local cover_h=math.floor(th*.36)
            local cover_w=math.floor(cover_h*.68)
            -- Simple native leaf sprigs echo the paper receipt reference.
            for _,side in ipairs{-1,1} do
                local sx=tw/2+side*(cover_w/2+s(26))
                for i=0,math.floor(cover_h/s(3)) do
                    local t=i*s(3)/cover_h
                    rect(ticket,sx+side*s(28)*(1-t)^2,s(21)+i*s(3),s(2),s(4),gray)
                end
                for i=1,5 do
                    local y=s(25)+i*cover_h/6
                    for j=0,s(32) do
                        local thickness=math.max(s(1),math.sin(j/s(32)*math.pi)*s(10))
                        rect(ticket,sx+side*j*.5-thickness/2,y-j,thickness,s(1),gray)
                        rect(ticket,sx-side*j*.5-thickness/2,y-j,thickness,s(1),gray)
                    end
                end
            end
            cover(ticket,model.book,(tw-cover_w)/2,s(21),cover_w,cover_h)
            local title_y=s(28)+cover_h
            text(ticket,book_name(model.book),s(18),title_y,tw-s(36),23,true,true,s(55))
            text(ticket,clean(model.book and model.book.author,"未知作者"),s(18),title_y+s(57),tw-s(36),15,false,true)
            local stats_y=math.floor(th*.57)
            local function dashed(y)
                for x=s(16),tw-s(20),s(8) do rect(ticket,x,y,s(4),s(1),gray) end
            end
            dashed(stats_y)
            local labels={"天数","时长",clean(model.position_label,"阅读位置")}
            local values={tostring(model.day_count or 0),duration(model.seconds,true),clean(model.position_text,"尚未开始")}
            for i=1,3 do
                text(ticket,labels[i],(i-1)*tw/3,stats_y+s(9),tw/3,14,false,true)
                text(ticket,values[i],(i-1)*tw/3,stats_y+s(37),tw/3,21,false,true)
            end
            text(ticket,clean(model.chapter_title,model.progress_text),s(18),stats_y+s(70),tw-s(36),11,false,true)
            local status_y=stats_y+s(94)
            local status_width=math.floor(tw*.7/3)
            local status_row={}
            for i,entry in ipairs{{"在读","reading"},{"搁置","paused"},{"读完","finished"}} do
                status_row[i]=button(ticket,entry[1],(tw-status_width*3)/2+(i-1)*status_width,status_y,status_width,s(32),model.on_status,entry[2],model.status==entry[2])
            end
            rows[#rows+1]=status_row
            local tear_y=status_y+s(43)
            dashed(tear_y)
            circle(ticket,0,tear_y,s(10),gray,s(1));circle(ticket,0,tear_y,s(9),white)
            circle(ticket,tw,tear_y,s(10),gray,s(1));circle(ticket,tw,tear_y,s(9),white)
            rect(ticket,-s(11),tear_y-s(11),s(11),s(22),white)
            rect(ticket,tw,tear_y-s(11),s(11),s(22),white)
            local barcode_y=tear_y+s(15)
            local barcode_h=math.max(s(22),math.min(s(48),th-barcode_y-s(96)))
            local bx,bar_w=math.floor(tw*.2),math.floor(tw*.6)
            local barcode=clean(model.receipt_id,"READING")
            local cursor,index=0,1
            while cursor<bar_w-s(5) do
                local byte=barcode:byte((index-1)%#barcode+1)
                local line_width=s(1+byte%3)
                rect(ticket,bx+cursor,barcode_y,line_width,barcode_h,black)
                cursor=cursor+line_width+s(1+index%3);index=index+1
            end
            text(ticket,"READING RECEIPT",0,barcode_y+barcode_h+s(3),tw,9,false,true)
            local stars_y=barcode_y+barcode_h+s(21)
            local star_w=s(44)
            root.rating_buttons={}
            for i=1,5 do
                local star=tappable(ticket,(tw-star_w*5)/2+(i-1)*star_w,stars_y,star_w,s(37),model.on_rating,i)
                star.text=i<=(tonumber(model.rating) or 0) and "★" or "☆"
                text(star,star.text,0,0,star_w,34,false,true)
                root.rating_buttons[i]=star
            end
            rows[#rows+1]=root.rating_buttons
            text(ticket,"日期："..clean(model.date_text,os.date("%Y-%m-%d")),s(16),th-s(29),tw-s(32),13,false,true)
        end
        return root,rows
    end
    return require("legado.ui.library_screen").new(display)
end

return ReadingScreen
