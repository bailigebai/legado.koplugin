-- A receipt over the reader, or over a white/image background in reading history.
local ReceiptScreen = {}
local Safe = require('legado.lib.safe_functions')
local logger = require('logger')

local function clean(value, fallback)
    value = Safe.functions.htmldecode(tostring(value or ''))
    return value:match('%S') and value or fallback or ''
end

local function duration(value)
    local minutes = math.floor(math.max(0, tonumber(value) or 0) / 60)
    return minutes >= 60 and string.format('%d小时%d分', math.floor(minutes/60), minutes%60) or minutes .. '分钟'
end

local function percent(value, default, minimum)
    value = tonumber(value)
    if not value or value ~= value then value = default end
    return math.max(minimum, math.min(95, value))
end

function ReceiptScreen.loadBackground(path)
    if path==nil or path=='' then return end
    if type(path)~='string' or #path>4096 or path:find('%c') or not (path:sub(1,1)=='/' or path:match('^%a:[/\\]')) then
        return nil,'请填写本机图片的完整路径。'
    end
    local ok,buffer=pcall(function()
        local attr=require('libs/libkoreader-lfs').attributes(path)
        if not attr or attr.mode~='file' then return end
        if not attr.size or attr.size<=0 or attr.size>8*1024*1024 then return end
        return require('ui/renderimage'):renderImageFile(path,false)
    end)
    if not ok or not buffer then return nil,'背景图片无法读取，请选择有效图片（不超过 8 MB）。' end
    return buffer
end

function ReceiptScreen.new(options)
    options = options or {}
    local model, injected = options.reading_model or {}, options.dependencies or {}
    local function dep(key, module) return injected[key] or require(module) end
    local d = {
        input=dep('input','ui/widget/container/inputcontainer'), focus=dep('focus','ui/widget/focusmanager'),
        geom=dep('geom','ui/geometry'), gesture=dep('gesture','ui/gesturerange'),
        text=dep('text','ui/widget/textwidget'), textbox=dep('textbox','ui/widget/textboxwidget'),
        button=dep('button','ui/widget/button'), image=dep('image','ui/widget/imagewidget'),
        center=dep('center','ui/widget/container/centercontainer'), font=dep('font','ui/font'),
        device=dep('device','device'), colors=dep('colors','ffi/blitbuffer'),
        ui=options.ui_manager or dep('ui','ui/uimanager'),
    }
    local screen = d.device.screen
    local width, height = screen:getWidth(), screen:getHeight()
    local tw = math.floor(width * percent(options.width_percent,75,50)/100)
    local th = math.floor(height * percent(options.height_percent,90,55)/100)
    local function device_scale(value) return screen.scaleBySize and screen:scaleBySize(value) or value end
    -- One uniform type scale; independent paper dimensions never stretch glyphs or covers.
    local fit = math.min(1, tw/device_scale(450), th/device_scale(720))
    local function s(value) return math.max(1,math.floor(device_scale(value)*fit+.5)) end
    local black, white, gray = d.colors.COLOR_BLACK, d.colors.COLOR_WHITE, d.colors.COLOR_DARK_GRAY
    local style = require('legado.lib.receipt_styles').normalize(options.style)
    local closed, handles, rows, cells = false, {}, {}, {}
    local widget
    local Canvas = d.input:extend{}
    function Canvas:paintTo(bb,x,y)
        self.dimen.x,self.dimen.y=x,y
        for _,draw in ipairs(self.ink) do draw(bb,x,y) end
        for i,child in ipairs(self) do child:paintTo(bb,x+self.spots[i][1],y+self.spots[i][2]) end
        if self.focused then bb:paintBorder(x,y,self.dimen.w,self.dimen.h,s(1),black) end
    end
    function Canvas:onTapSelect() return self.callback and self.callback() end
    function Canvas:onFocus() self.focused=true;d.ui:setDirty(widget,'ui');return true end
    function Canvas:onUnfocus() self.focused=false;d.ui:setDirty(widget,'ui');return true end
    local function canvas(w,h) return Canvas:new{dimen=d.geom:new{w=math.floor(w),h=math.floor(h)},ink={},spots={}} end
    local function put(parent,child,x,y)
        parent[#parent+1]=child;parent.spots[#parent.spots+1]={math.floor(x),math.floor(y)};return child
    end
    local function rect(parent,x,y,w,h,color,border,radius)
        x,y,w,h=math.floor(x),math.floor(y),math.max(1,math.floor(w)),math.max(1,math.floor(h))
        parent.ink[#parent.ink+1]=function(bb,ox,oy)
            if border then bb:paintBorder(ox+x,oy+y,w,h,border,color or black,radius)
            elseif radius then bb:paintRoundedRect(ox+x,oy+y,w,h,color or black,radius)
            else bb:paintRect(ox+x,oy+y,w,h,color or black) end
        end
    end
    local function text(parent,value,x,y,w,size,bold,center,h,color)
        local args={text=clean(value),face=d.font:getFace('cfont',size*fit),bold=bold,fgcolor=color or black}
        local label
        if h then
            args.face,args.bold=d.font:getAdjustedFace(args.face,args.bold)
            args._face_adjusted=true
            -- TextBox adds glyph overflow below its requested height. Reserve it
            -- inside our slot so the painted comment stays within its tap area.
            local face_height=args.face.ftsize:getHeightAndAscender()
            local extra=math.max(0,math.ceil(face_height-math.floor(args.face.size+.5)))
            args.width,args.height,args.height_adjust,args.line_height=math.floor(w),math.max(1,math.floor(h)-extra),false,0
            args.height_overflow_show_ellipsis,args.alignment=true,center and 'center' or 'left'
            label=d.textbox:new(args)
        else
            args.max_width=math.floor(w);label=d.text:new(args)
            if center then x=x+math.max(0,math.floor((w-label:getSize().w)/2)) end
        end
        return put(parent,label,x,y)
    end
    local function invoke(fn,value)
        if closed then return false end
        if fn then
            local ok,result=pcall(fn,value)
            if not ok then if options.on_error then pcall(options.on_error,result) end;return false end
        end
        return true
    end
    local function tappable(parent,x,y,w,h,fn,value)
        local box=canvas(w,h)
        box.callback=function() return invoke(fn,value) end
        box.ges_events.TapSelect={d.gesture:new{ges='tap',range=function() return box.dimen end}}
        return put(parent,box,x,y)
    end
    local function button(parent,title,x,y,w,h,fn,value,active)
        return put(parent,d.button:new{text=title,width=math.floor(w),height=math.max(1,math.floor(h)-2*(s(2)+s(1))),text_font_size=13*fit,
            padding=s(2),bordersize=s(1),radius=s(5),avoid_text_truncation=false,
            background=active and d.colors.COLOR_LIGHT_GRAY or white,callback=function() return invoke(fn,value) end},x,y)
    end
    local function dashed(parent,y,x,w)
        x,w=x or s(18),w or parent.dimen.w-s(36)
        for bx=x,x+w-s(3),s(8) do rect(parent,bx,y,s(3),s(1),gray) end
    end
    local function cover_widget(path,w,h)
        local image
        if path then
            local ok=pcall(function() image=d.image:new{file=path,width=w,height=h,scale_factor=0};image:getSize() end)
            if not ok then if image and image.free then pcall(image.free,image) end;image=nil end
        end
        image=image or d.text:new{text=path and '封面不可用' or '无封面',face=d.font:getFace('cfont',12*fit),max_width=w-s(4)}
        return d.center:new{dimen=d.geom:new{w=w,h=h},image}
    end
    local function cover(parent,x,y,w,h)
        w,h=math.floor(w),math.floor(h)
        local slot=put(parent,cover_widget(nil,w,h),x,y)
        local index=#parent
        local cell={book=model.book,cover=slot,visual=parent}
        cells[#cells+1]=cell
        if model.book and options.cover_loader then
            local ok,handle=pcall(options.cover_loader,model.book,function(path)
                if closed then return end
                local old=cell.cover
                parent[index]=cover_widget(path,w,h);cell.cover=parent[index]
                if old and old.free then old:free() end
                d.ui:setDirty(widget,'ui')
            end)
            if ok and handle then handles[#handles+1]=handle end
        end
    end
    local function progress(parent,x,y,w,value)
        rect(parent,x,y,w,s(5),d.colors.COLOR_LIGHT_GRAY)
        value=tonumber(value)
        if value and value==value and value>0 then rect(parent,x,y,math.max(1,w*math.min(1,value)),s(5),black) end
    end
    local Root=d.focus:extend{}
    widget=Root:new{dimen=d.geom:new{w=width,h=height},layout=rows,ink={},spots={},
        kind='receipt_screen',fullscreen=options.with_background==true,covers_fullscreen=options.with_background==true,alive=true,controls_visible=false,
        options=options,cells=cells,style=style,is_always_active=true}
    function widget:paintTo(bb,x,y)
        Canvas.paintTo(self,bb,x,y)
        if self._painted_controls~=self.controls_visible then
            logger.info('[LegadoReceipt] painted controls=',self.controls_visible)
            self._painted_controls=self.controls_visible
        end
    end
    function widget:onShow()
        logger.info('[LegadoReceipt] build=receipt-repaint-20260914 size=',width,height)
    end
    if options.with_background then
        rect(widget,0,0,width,height,white)
        local buffer=ReceiptScreen.loadBackground(options.background_path)
        if buffer then
            widget.background_widget=put(widget,d.image:new{image=buffer,image_disposable=true,
                width=width,height=height,scale_factor=0,alpha=true},0,0)
        end
    end
    local paper=put(widget,canvas(tw,th),(width-tw)/2,(height-th)/2)
    widget.paper,widget.reading_body=paper,paper
    -- Keep the root tap binding distinct from the child canvases' TapSelect.
    local function root_tap() return d.gesture:new{ges='tap', range=function() return widget.dimen end} end
    -- A root TapSelect would propagate to the paper's rating/comment handlers.
    widget.ges_events = { Tap = { root_tap() } }
    if style=='classic' then
        -- Paint between the edge cutouts so the reader remains visible through them.
        local radius=s(9)
        rect(paper,0,radius,tw,th-2*radius,white)
        rect(paper,0,radius,s(1),th-2*radius,gray)
        rect(paper,tw-s(1),radius,s(1),th-2*radius,gray)
        local step=tw/math.max(1,math.floor(tw/s(40)))
        for dy=0,radius-1 do
            local cut=math.sqrt(radius*radius-dy*dy)
            for center=0,tw-step/2,step do
                local x,finish=math.ceil(center+cut),math.floor(center+step-cut)
                for _,y in ipairs{dy,th-dy-1} do
                    rect(paper,x,y,finish-x,1,dy==0 and gray or white)
                    rect(paper,x,y,s(1),1,gray)
                    rect(paper,finish-s(1),y,s(1),1,gray)
                end
            end
        end
    else
        rect(paper,0,0,tw,th,white,nil,s(8))
        rect(paper,0,0,tw,th,gray,s(1),s(8))
    end
    local pad,iw=s(18),tw-s(36)
    local book=model.book or {}
    local title,author=clean(book.name or book.title,'未命名书籍'),clean(book.author,'未知作者')
    local date=clean(model.date_text,os.date('%Y-%m-%d'))
    local total_seconds=model.seconds or model.reading_seconds
    local chapter_fraction=tonumber(model.chapter_fraction)
    local chapter_page,chapter_pages=tonumber(model.chapter_page),tonumber(model.chapter_pages)
    local chapter_detail=chapter_fraction and string.format('本章已读 %.0f%%',chapter_fraction*100) or '暂无章节进度'
    if chapter_page and chapter_pages and chapter_pages>0 then
        chapter_fraction=math.max(0,math.min(1,chapter_page/chapter_pages))
        chapter_detail=string.format('第 %d 页 / 共 %d 页    %.0f%%',chapter_page,chapter_pages,chapter_fraction*100)
    end
    local comment_y=math.floor(th*.89)
    local function progress_section(y,label,name,fraction,detail,remaining)
        text(paper,label,pad,y,iw,18,true,true)
        text(paper,name,pad,y+th*.045,iw,13,false,false,th*.043)
        progress(paper,pad,y+th*.092,iw,fraction)
        text(paper,detail,pad,y+th*.11,iw,12,false,false)
        if tonumber(remaining) then text(paper,'预计还需 '..duration(remaining),pad,y+th*.143,iw,10,false,true) end
    end
    if style=='classic' then
        -- The barcode is decorative and carries no machine-readable data.
        local left=iw*.70
        text(paper,'阅读日票',pad,th*.032,left,11)
        text(paper,'READ RECEIPT',pad,th*.064,left,29,true)
        text(paper,'今日阅读轨迹 / READING TRAIL',pad,th*.112,left,9)
        rect(paper,pad+left,th*.032,s(1),th*.11,gray)
        text(paper,'状态',pad+left+s(5),th*.038,iw-left-s(5),10,false,true)
        local statuses={reading='在读',paused='搁置',finished='读完',unread='未读'}
        text(paper,statuses[model.status] or '在读',pad+left+s(5),th*.076,iw-left-s(5),26,true,true)
        dashed(paper,th*.16)
        local date_labels={'阅读起始日','阅读天数','最近阅读'}
        local date_values={clean(model.start_date,'暂无记录'),tostring(model.day_count or 0)..' 天',date}
        for i=1,3 do
            text(paper,date_labels[i],pad+(i-1)*iw/3,th*.172,iw/3,9,false,true)
            text(paper,date_values[i],pad+(i-1)*iw/3,th*.197,iw/3,12,false,true)
        end
        dashed(paper,th*.233)
        local cover_h=th*.32
        local cover_w=math.min(iw*.35,cover_h*.68)
        local info_w=iw-cover_w-s(15)
        cover(paper,tw-pad-cover_w,th*.264,cover_w,cover_h)
        text(paper,'当前阅读 READING',pad,th*.26,info_w,10)
        text(paper,title,pad,th*.29,info_w,18,true,false,th*.068)
        text(paper,'作者：'..author,pad,th*.363,info_w,11)
        widget.rating_buttons={}
        local star_w=math.floor(math.min(s(35),info_w/5))
        for i=1,5 do
            local star=tappable(paper,pad+(i-1)*star_w,th*.40,star_w,th*.055,model.on_rating,i)
            star.text=i<=(tonumber(model.rating) or 0) and '★' or '☆'
            text(star,star.text,0,0,star_w,24,false,true)
            widget.rating_buttons[i]=star
        end
        rows[#rows+1]=widget.rating_buttons
        text(paper,clean(model.chapter_title,'尚未开始'),pad,th*.47,info_w,11,false,false,th*.035)
        text(paper,'总阅读：'..duration(total_seconds),pad,th*.514,info_w,11)
        progress(paper,pad,th*.55,info_w,model.fraction)
        text(paper,clean(model.position_text,'暂无记录'),pad,th*.567,info_w*.65,10)
        text(paper,clean(model.progress_text,'暂无进度'),pad+info_w*.65,th*.567,info_w*.35,10)
        widget.status_buttons={}
        for i,entry in ipairs{{'在读','reading'},{'搁置','paused'},{'读完','finished'}} do
            widget.status_buttons[i]=button(paper,entry[1],pad+(i-1)*iw/3,th*.615,iw/3-s(3),th*.04,
                model.on_status,entry[2],model.status==entry[2])
        end
        rows[#rows+1]=widget.status_buttons
        dashed(paper,th*.677)
        text(paper,'今日摘要 SUMMARY',pad,th*.691,iw,13,true)
        text(paper,'今日阅读',pad,th*.732,iw/2,10,false,true)
        text(paper,'累计阅读',pad+iw/2,th*.732,iw/2,10,false,true)
        text(paper,duration(model.today_seconds),pad,th*.758,iw/2,17,false,true)
        text(paper,duration(total_seconds),pad+iw/2,th*.758,iw/2,17,false,true)
        dashed(paper,th*.803)
        local cursor,index=0,1
        local barcode=clean(model.receipt_id,'READING')
        while cursor<iw-s(4) do
            local bw=s(1+barcode:byte((index-1)%#barcode+1)%3)
            rect(paper,pad+cursor,th*.821,math.min(bw,iw-cursor),th*.032,black)
            cursor=cursor+bw+s(1+index%2);index=index+1
        end
        text(paper,'READING LOG · '..date,pad,th*.86,iw,8,false,true)
    elseif style=='simple' then
        local cover_h=th*.32
        local cover_w=math.min(iw*.52,cover_h*.68)
        cover(paper,(tw-cover_w)/2,th*.025,cover_w,cover_h)
        progress_section(th*.375,'章节',clean(model.chapter_title,'尚未开始'),chapter_fraction,chapter_detail,model.chapter_remaining)
        progress_section(th*.565,'书籍',title..' · '..author,model.fraction,
            clean(model.position_text,'暂无记录')..'    '..clean(model.progress_text,'暂无进度'),model.book_remaining)
        text(paper,'总阅读时长：'..duration(total_seconds),pad,th*.775,iw,15,false,true)
        text(paper,'今日阅读：'..duration(model.today_seconds),pad,th*.818,iw,13,false,true)
        text(paper,date,pad,th*.853,iw,10,false,true)
    elseif style=='calendar' then
        local cover_h=th*.23
        local cover_w=math.min(iw*.33,cover_h*.68)
        cover(paper,pad+iw*.1,th*.035,cover_w,cover_h)
        local dx,dw=tw*.52,tw*.40
        local year,month,day=date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        text(paper,year and year..'.'..month or date,dx,th*.046,dw,14,false,true)
        text(paper,day or '—',dx,th*.086,dw,54,false,true)
        text(paper,'阅读 '..tostring(model.day_count or 0)..' 天',dx,th*.212,dw,12,false,true)
        dashed(paper,th*.285)
        rect(paper,0,th*.309,tw,th*.09,black)
        for x=s(6),tw-s(6),s(8) do
            rect(paper,x,th*.315,s(3),s(3),white);rect(paper,x,th*.386,s(3),s(3),white)
        end
        text(paper,title,pad,th*.335,iw,20,true,true,nil,white)
        progress_section(th*.438,'章节',clean(model.chapter_title,'尚未开始'),chapter_fraction,chapter_detail,model.chapter_remaining)
        progress_section(th*.624,'总进度',clean(model.position_label,'阅读位置'),model.fraction,
            clean(model.position_text,'暂无记录')..'    '..clean(model.progress_text,'暂无进度'),model.book_remaining)
        text(paper,'已阅读 '..duration(total_seconds)..'  ·  今日 '..duration(model.today_seconds),pad,th*.832,iw,12,false,true)
    elseif style=='bookshop' then
        text(paper,'书与时光',pad,th*.035,iw,28,true,true)
        text(paper,'BOOKSHOP / READING RECEIPT',pad,th*.10,iw,10,false,true)
        text(paper,date,pad,th*.14,iw,11,false,true)
        dashed(paper,th*.183)
        local cw=math.min(iw*.23,th*.17*.68)
        cover(paper,tw-pad-cw,th*.211,cw,th*.17)
        text(paper,title,pad,th*.214,iw-cw-s(12),20,true,false,th*.086)
        text(paper,author,pad,th*.32,iw-cw-s(12),12)
        rect(paper,pad,th*.405,iw,s(1),black)
        text(paper,'阅读项目',pad,th*.418,iw*.48,10)
        text(paper,'本次记录',pad+iw*.48,th*.418,iw*.52,10,false,true)
        local details={{'今日阅读',duration(model.today_seconds)},{'累计阅读',duration(total_seconds)},
            {'阅读天数',tostring(model.day_count or 0)..' 天'},{'阅读位置',clean(model.position_text,'暂无记录')}}
        for i,entry in ipairs(details) do
            local y=th*(.465+(i-1)*.051)
            text(paper,entry[1],pad,y,iw*.48,12)
            text(paper,entry[2],pad+iw*.48,y,iw*.52,13,false,true)
        end
        rect(paper,pad,th*.684,iw,s(2),black)
        text(paper,'本书阅读进度',pad,th*.72,iw*.5,12,true)
        text(paper,clean(model.progress_text,'暂无进度'),pad+iw*.5,th*.708,iw*.5,25,true,true)
        progress(paper,pad,th*.784,iw,model.fraction)
        text(paper,'谢谢你，把时间留给阅读。',pad,th*.837,iw,11,false,true)
    elseif style=='boarding' then
        rect(paper,pad,th*.028,iw,th*.107,black,nil,s(3))
        text(paper,'阅读登机牌',pad+s(8),th*.04,iw-s(16),23,true,false,nil,white)
        text(paper,'BOARDING PASS / BOOK JOURNEY',pad+s(8),th*.097,iw-s(16),9,false,false,nil,white)
        text(paper,'书页  →  远方',pad,th*.163,iw,21,true,true)
        local cw=math.min(iw*.32,th*.238*.68)
        cover(paper,pad,th*.233,cw,th*.238)
        local x=pad+cw+s(14)
        text(paper,'同行的书',x,th*.237,tw-pad-x,10)
        text(paper,title,x,th*.276,tw-pad-x,21,true,false,th*.104)
        text(paper,author,x,th*.408,tw-pad-x,12)
        dashed(paper,th*.51)
        local labels={'阅读日期','今日阅读','相伴天数'}
        local values={date,duration(model.today_seconds),tostring(model.day_count or 0)..' 天'}
        for i=1,3 do
            text(paper,labels[i],pad+(i-1)*iw/3,th*.546,iw/3,10,false,true)
            text(paper,values[i],pad+(i-1)*iw/3,th*.585,iw/3,12,true,true)
        end
        text(paper,'此刻抵达 / CURRENT CHAPTER',pad,th*.66,iw,10)
        text(paper,clean(model.chapter_title,'尚未开始'),pad,th*.701,iw,18,true,false,th*.071)
        progress(paper,pad,th*.807,iw,model.fraction)
        text(paper,clean(model.position_text,'暂无记录')..'   ·   '..clean(model.progress_text,'暂无进度'),pad,th*.835,iw,12,false,true)
    elseif style=='library' then
        text(paper,'私人图书馆',pad,th*.034,iw,25,true,true)
        text(paper,'PERSONAL LIBRARY / 借阅记录',pad,th*.096,iw,10,false,true)
        rect(paper,pad,th*.143,iw,s(2),black)
        local cw=math.min(iw*.22,th*.155*.68)
        cover(paper,tw-pad-cw,th*.171,cw,th*.155)
        text(paper,title,pad,th*.175,iw-cw-s(12),20,true,false,th*.09)
        text(paper,'作者 / '..author,pad,th*.283,iw-cw-s(12),12)
        local top,row_h=th*.368,th*.073
        rect(paper,pad,top,iw,row_h*6,gray,s(1))
        rect(paper,pad+iw*.38,top,s(1),row_h*6,gray)
        local entries={{'登记项目','阅读记录'},{'起始日期',clean(model.start_date,'暂无记录')},
            {'最近阅读',date},{'相伴天数',tostring(model.day_count or 0)..' 天'},
            {'累计时长',duration(total_seconds)},{'阅读进度',clean(model.progress_text,'暂无进度')}}
        for i,entry in ipairs(entries) do
            local y=top+(i-1)*row_h
            if i>1 then rect(paper,pad,y,iw,s(1),gray) end
            text(paper,entry[1],pad+s(6),y+row_h*.30,iw*.38-s(12),12,i==1,true)
            text(paper,entry[2],pad+iw*.38+s(6),y+row_h*.30,iw*.62-s(12),13,i==1,true)
        end
        local statuses={reading='在读',paused='搁置',finished='读完',unread='未读'}
        text(paper,'阅读状态  [ '..(statuses[model.status] or '未读')..' ]',pad,th*.833,iw,13,true,true)
    elseif style=='cinema' then
        text(paper,'CINEMA / 阅读放映室',pad,th*.033,iw,11,true,true)
        text(paper,title,pad,th*.085,iw,23,true,true,th*.081)
        text(paper,author,pad,th*.186,iw,12,false,true)
        local ch=th*.323
        local cw=math.min(iw*.6,ch*.68)
        rect(paper,pad,th*.237,iw,ch+s(12),black,nil,s(3))
        rect(paper,(tw-cw)/2,th*.237+s(6),cw,ch,white)
        cover(paper,(tw-cw)/2,th*.237+s(6),cw,ch)
        dashed(paper,th*.612)
        local labels={'放映日期','今日阅读','累计阅读'}
        local values={date,duration(model.today_seconds),duration(total_seconds)}
        for i=1,3 do
            text(paper,labels[i],pad+(i-1)*iw/3,th*.644,iw/3,10,false,true)
            text(paper,values[i],pad+(i-1)*iw/3,th*.683,iw/3,12,true,true)
        end
        progress(paper,pad,th*.752,iw,model.fraction)
        text(paper,clean(model.chapter_title,'尚未开始'),pad,th*.79,iw,13,false,true,th*.042)
        text(paper,'NO. '..clean(model.receipt_id,'READING')..'  /  '..clean(model.progress_text,'暂无进度'),pad,th*.85,iw,9,false,true)
    elseif style=='postcard' then
        text(paper,'寄给未来的自己',pad,th*.048,iw,23,true,true)
        text(paper,'POSTCARD / 阅读来信',pad,th*.11,iw,10,false,true)
        local cw=math.min(iw*.42,th*.32*.68)
        rect(paper,pad,th*.183,cw+s(10),th*.32+s(10),gray,s(1),s(3))
        cover(paper,pad+s(5),th*.183+s(5),cw,th*.32)
        local x=pad+cw+s(27)
        rect(paper,x-s(8),th*.184,s(1),th*.349,gray)
        text(paper,'TO / 未来的我',x,th*.20,tw-pad-x,10)
        text(paper,title,x,th*.276,tw-pad-x,18,true,false,th*.13)
        text(paper,author,x,th*.46,tw-pad-x,11)
        text(paper,'在这一页，留下片刻。',pad,th*.565,iw,12)
        text(paper,clean(model.chapter_title,'故事还未开始'),pad,th*.61,iw,18,false,false,th*.082)
        rect(paper,pad,th*.706,iw,s(1),gray)
        text(paper,date..'  寄出',pad,th*.737,iw,12)
        text(paper,'已相伴 '..duration(total_seconds),pad,th*.78,iw,12)
        progress(paper,pad,th*.831,iw*.67,model.fraction)
        text(paper,clean(model.progress_text,'暂无进度'),pad+iw*.7,th*.815,iw*.3,13,true,true)
    elseif style=='newspaper' then
        text(paper,'阅读日报',pad,th*.032,iw,34,true,true)
        rect(paper,pad,th*.12,iw,s(2),black)
        rect(paper,pad,th*.128,iw,s(1),black)
        text(paper,date,pad,th*.144,iw*.6,10)
        text(paper,'相伴第 '..tostring(model.day_count or 0)..' 天',pad+iw*.6,th*.144,iw*.4,10,false,true)
        rect(paper,pad,th*.178,iw,s(1),black)
        text(paper,title,pad,th*.209,iw,24,true,false,th*.079)
        text(paper,'作者 / '..author,pad,th*.302,iw,11)
        local cw=math.min(iw*.39,th*.267*.68)
        cover(paper,tw-pad-cw,th*.36,cw,th*.267)
        local lw=iw-cw-s(16)
        text(paper,'今日阅读',pad,th*.37,lw,11)
        text(paper,duration(model.today_seconds),pad,th*.411,lw,26,true)
        text(paper,'累计阅读',pad,th*.517,lw,11)
        text(paper,duration(total_seconds),pad,th*.558,lw,22,true)
        rect(paper,pad,th*.664,iw,s(2),black)
        text(paper,'阅读现场 / READING NOW',pad,th*.689,iw,11,true)
        text(paper,clean(model.chapter_title,'尚未开始'),pad,th*.731,iw,17,false,false,th*.06)
        progress(paper,pad,th*.82,iw,model.fraction)
        text(paper,clean(model.position_text,'暂无记录')..'   ·   '..clean(model.progress_text,'暂无进度'),pad,th*.847,iw,11,false,true)
    elseif style=='exhibition' then
        local rail=iw*.12
        rect(paper,pad,th*.035,rail,th*.825,black)
        for i,letter in ipairs{'R','E','A','D'} do
            text(paper,letter,pad,th*(.055+i*.048),rail,16,true,true,nil,white)
        end
        text(paper,'01',pad,th*.792,rail,14,true,true,nil,white)
        local x,w=pad+iw*.18,iw*.82
        text(paper,'阅读展览',x,th*.035,w,28,true)
        text(paper,'A PRIVATE EXHIBITION',x,th*.102,w,10)
        local ch=th*.31
        local cw=math.min(w*.72,ch*.68)
        rect(paper,x,th*.16,w,ch+s(12),gray,s(1))
        cover(paper,x+(w-cw)/2,th*.16+s(6),cw,ch)
        text(paper,'作品 / TITLE',x,th*.513,w,9)
        text(paper,title,x,th*.551,w,23,true,false,th*.08)
        text(paper,author,x,th*.65,w,11)
        rect(paper,x,th*.698,w,s(1),black)
        text(paper,'参观日期',x,th*.72,w*.52,9)
        text(paper,'累计驻足',x+w*.52,th*.72,w*.48,9,false,true)
        text(paper,date,x,th*.755,w*.52,12)
        text(paper,duration(total_seconds),x+w*.52,th*.755,w*.48,12,true,true)
        progress(paper,x,th*.821,w,model.fraction)
        text(paper,clean(model.progress_text,'暂无进度'),x,th*.843,w,10,false,true)
    elseif style=='passport' then
        text(paper,'阅读护照',pad,th*.035,iw,28,true,true)
        text(paper,'PASSPORT / 书页之间的旅行',pad,th*.103,iw,10,false,true)
        local top,bottom=th*.158,th*.61
        rect(paper,pad,top,iw,bottom-top,gray,s(1),s(4))
        rect(paper,pad+iw*.46,top,s(1),bottom-top,gray)
        local ch=th*.254
        local cw=math.min(iw*.35,ch*.68)
        cover(paper,pad+(iw*.46-cw)/2,th*.208,cw,ch)
        text(paper,'BOOK / 身份页',pad+s(5),th*.517,iw*.46-s(10),10,false,true)
        local x,w=pad+iw*.46+s(10),iw*.54-s(20)
        text(paper,'随行书籍',x,th*.19,w,10)
        text(paper,title,x,th*.241,w,20,true,false,th*.12)
        text(paper,author,x,th*.399,w,11)
        text(paper,'启程 / '..clean(model.start_date,'暂无记录'),x,th*.457,w,10,false,false,th*.06)
        text(paper,'相伴 '..tostring(model.day_count or 0)..' 天',x,th*.543,w,13,true)
        local stamps={{'最近阅读',date},{'累计阅读',duration(total_seconds)}}
        for i,entry in ipairs(stamps) do
            local sx=pad+(i-1)*iw*.52
            rect(paper,sx,th*.66,iw*.48,th*.15,gray,s(1),s(5))
            text(paper,entry[1],sx+s(5),th*.686,iw*.48-s(10),10,false,true)
            text(paper,entry[2],sx+s(5),th*.737,iw*.48-s(10),15,true,true)
        end
        progress(paper,pad,th*.845,iw,model.fraction)
    elseif style=='contact' then
        text(paper,'READING / CONTACT SHEET',pad,th*.035,iw,14,true,true)
        text(paper,date..'   ·   相伴 '..tostring(model.day_count or 0)..' 天',pad,th*.084,iw,10,false,true)
        rect(paper,pad,th*.137,iw,th*.353,black)
        for x=pad+s(5),pad+iw-s(5),s(13) do
            rect(paper,x,th*.147,s(5),s(4),white)
            rect(paper,x,th*.477,s(5),s(4),white)
        end
        local gap=s(9)
        local fw=(iw-gap*4)/3
        for i=1,3 do
            local x=pad+gap+(i-1)*(fw+gap)
            text(paper,string.format('%02d',i),x,th*.17,fw,9,false,true,nil,white)
            rect(paper,x,th*.214,fw,th*.225,white)
            if i==1 then
                cover(paper,x+s(3),th*.214+s(3),fw-s(6),th*.225-s(6))
            else
                text(paper,i==2 and '今日' or '累计',x+s(3),th*.25,fw-s(6),11,false,true)
                text(paper,duration(i==2 and model.today_seconds or total_seconds),x+s(3),th*.306,fw-s(6),18,true,true,th*.087)
            end
        end
        text(paper,title,pad,th*.537,iw,27,true,true,th*.09)
        text(paper,author,pad,th*.654,iw,12,false,true)
        text(paper,clean(model.chapter_title,'尚未开始'),pad,th*.721,iw,15,false,true,th*.06)
        progress(paper,pad,th*.82,iw,model.fraction)
        text(paper,clean(model.position_text,'暂无记录')..'   /   '..clean(model.progress_text,'暂无进度'),pad,th*.846,iw,11,false,true)
    elseif style=='archive' then
        rect(paper,pad,th*.032,iw*.46,th*.052,black)
        text(paper,'PERSONAL ARCHIVE',pad+s(6),th*.044,iw*.46-s(12),10,true,false,nil,white)
        rect(paper,pad,th*.105,iw,th*.75,gray,s(1))
        local x,w=pad+s(12),iw-s(24)
        text(paper,'阅读档案',x,th*.134,w,29,true)
        text(paper,'档案号 / '..clean(model.receipt_id,'READING'),x,th*.214,w,10)
        rect(paper,x,th*.259,w,s(2),black)
        local ch=th*.22
        local cw=math.min(w*.27,ch*.68)
        cover(paper,x+w-cw,th*.293,cw,ch)
        text(paper,'题名',x,th*.298,w-cw-s(10),9)
        text(paper,title,x,th*.337,w-cw-s(10),20,true,false,th*.092)
        text(paper,'作者 / '..author,x,th*.465,w-cw-s(10),11)
        local entries={{'最近阅读',date},{'累计时长',duration(total_seconds)},
            {'当前位置',clean(model.position_text,'暂无记录')}}
        for i,entry in ipairs(entries) do
            local y=th*(.563+(i-1)*.073)
            text(paper,entry[1],x,y,w*.34,10)
            text(paper,entry[2],x+w*.34,y,w*.66,13,true)
            rect(paper,x,y+th*.042,w,s(1),gray)
        end
        progress(paper,x,th*.801,w*.65,model.fraction)
        text(paper,clean(model.progress_text,'暂无进度'),x+w*.68,th*.787,w*.32,12,true,true)
    elseif style=='timeline' then
        text(paper,'阅读时间轴',pad,th*.035,iw,27,true)
        text(paper,'ONE BOOK, MANY MOMENTS',pad,th*.101,iw,10)
        local ch=th*.217
        local cw=math.min(iw*.25,ch*.68)
        cover(paper,tw-pad-cw,th*.171,cw,ch)
        text(paper,title,pad,th*.18,iw-cw-s(14),22,true,false,th*.099)
        text(paper,author,pad,th*.316,iw-cw-s(14),11)
        local line_x=pad+s(9)
        rect(paper,line_x,th*.458,s(1),th*.358,gray)
        local entries={
            {'开始相伴',clean(model.start_date,'暂无记录')},
            {'最近阅读',date..'   ·   今日 '..duration(model.today_seconds)},
            {'此刻停在',clean(model.chapter_title,'尚未开始')},
        }
        for i,entry in ipairs(entries) do
            local y=th*(.447+(i-1)*.136)
            rect(paper,line_x-s(4),y+s(3),s(9),s(9),black,nil,s(4))
            text(paper,entry[1],line_x+s(20),y,iw-s(30),11,true)
            text(paper,entry[2],line_x+s(20),y+th*.041,iw-s(30),14,false,false,th*.067)
        end
        text(paper,'累计 '..duration(total_seconds)..'   ·   '..clean(model.progress_text,'暂无进度'),pad,th*.848,iw,11,false,true)
    elseif style=='bookmark' then
        local x,w=pad+iw*.16,iw*.68
        rect(paper,x,th*.025,w,th*.839,gray,s(1),s(4))
        text(paper,'BOOKMARK',x+s(6),th*.055,w-s(12),12,true,true)
        rect(paper,tw/2-s(9),th*.105,s(18),s(2),black)
        local ch=th*.237
        local cw=math.min(w*.61,ch*.68)
        cover(paper,(tw-cw)/2,th*.162,cw,ch)
        text(paper,title,x+s(10),th*.453,w-s(20),22,true,true,th*.11)
        text(paper,author,x+s(10),th*.602,w-s(20),11,false,true)
        progress(paper,x+w*.15,th*.689,w*.7,model.fraction)
        text(paper,clean(model.progress_text,'暂无进度'),x+s(10),th*.724,w-s(20),19,true,true)
        text(paper,date,x+s(10),th*.81,w-s(20),10,false,true)
    end
    dashed(paper,comment_y)
    local comment=tappable(paper,pad,comment_y+s(5),iw,th-comment_y-s(18),options.on_comment or model.on_comment,model.comment or '')
    local comment_text=clean(model.comment)
    local comment_top=comment_text=='' and s(16) or 0
    if comment_text=='' then text(comment,'短评 · 点击编辑',0,0,iw,9,false,true) end
    text(comment,comment_text~='' and comment_text or '写下此刻的阅读感受',0,comment_top,iw,12,false,true,
        math.max(s(14),comment.dimen.h-comment_top))
    widget.comment_button=comment;rows[#rows+1]={comment}

    local controls=canvas(tw-s(20),s(42))
    local control_buttons={}
    rect(controls,0,0,controls.dimen.w,controls.dimen.h,white)
    local function cleanup()
        if closed then return false end
        closed,widget.alive=true,false
        widget.is_always_active=false
        for _,handle in ipairs(handles) do
            if type(handle.cancel)=='function' then pcall(handle.cancel,handle)
            elseif type(handle.free)=='function' then pcall(handle.free,handle) end
        end
        widget:free()
        if not widget.controls_visible then controls:free() end
        return true
    end
    local function close(terminal)
        if closed then return false end
        cleanup();d.ui:close(widget);d.ui:setDirty(nil,'ui')
        if terminal and options.on_back then pcall(options.on_back) end
        return true
    end
    widget.onClose=function() return close(true) end
    widget.closeForReplacement=function() return close(false) end
    widget.onCloseWidget=cleanup
    local entries={{'返回',widget.onClose},{'宽度 / 高度',options.on_edit,'size'},{'样式',options.on_edit,'style'}}
    for i,entry in ipairs(entries) do
        control_buttons[i]=button(controls,entry[1],(i-1)*controls.dimen.w/3+s(2),s(3),controls.dimen.w/3-s(4),s(36),entry[2],entry[3])
    end
    widget.control_buttons=control_buttons
    local paper_y=(height-th)/2
    local control_y=paper_y+th/4
    -- The screen's whole top quarter is the toggle zone. Kindle touch
    -- coordinates are imprecise, so tapping anywhere in this header works.
    local trigger_top=0
    local trigger_bottom=height/4+s(12)
    local function show_controls(show)
        if show==widget.controls_visible then return end
        widget.controls_visible=show
        if show then
            put(widget,controls,(width-controls.dimen.w)/2,math.max(0,math.floor(control_y-controls.dimen.h/2)))
            table.insert(rows,1,control_buttons)
        else table.remove(widget);table.remove(widget.spots);table.remove(rows,1) end
        -- nil only refreshes existing pixels. Mark this window for repaint so
        -- the controls are drawn (or erased) and get their tap coordinates.
        d.ui:setDirty(widget,'ui')
        logger.info('[LegadoReceipt] requested controls=',show)
    end
    function widget:propagateEvent(event)
        if self.controls_visible and controls:handleEvent(event) then return true end
        -- Some native text/container widgets consume Gesture before it reaches
        -- the parent. Check the header toggle at the root first.
        if event and event.handler=='onGesture' and self:onGesture(unpack(event.args,1,event.args.n)) then return true end
        return paper:handleEvent(event)
    end
    function widget:onGesture(gesture)
        if closed or not self.alive then return false end
        local p = gesture and (gesture.pos or gesture)
        local px = p and (p.x or p[1])
        local py = p and (p.y or p[2])
        if gesture and gesture.ges=='tap' and px and py then
            local in_top_quarter = px>=0 and px<=width
                and py>=trigger_top and py<=trigger_bottom
            local in_legacy_quarter = math.abs(px-width/2)<=tw/2
                and math.abs(py-control_y)<=math.max(s(24),th*.045)
            if in_top_quarter or in_legacy_quarter then
                show_controls(not self.controls_visible)
                return true
            elseif self.controls_visible then show_controls(false) end
        end
        return self.controls_visible
    end
    -- FocusManager dispatches ges_events.Tap/TapSelect to these handlers;
    -- without them the event falls through to the underlying reader chrome.
    -- InputContainer emits Event("Tap", gsseq.args, gesture), so the gesture
    -- is the second argument when gsseq.args is nil.
    function widget:onTap(first, gesture) return self:onGesture(gesture or first) end
    function widget:onTapSelect(first, gesture) return self:onGesture(gesture or first) end
    if d.device.input and d.device.input.group and d.device.input.group.Back then
        widget.key_events.Close={{d.device.input.group.Back}}
    end
    return widget
end

return ReceiptScreen
