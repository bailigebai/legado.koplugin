-- Native discussion cards use LibraryScreen's window and image lifetime.
local Body={}
local Text=require('legado.lib.leko_text')

function Body.metadata(row)
    local parts={}
    if row.likes_count~=nil then parts[#parts+1]='赞 '..tostring(row.likes_count) end
    local replies=row.comments_count or row.replies_count
    if replies~=nil then parts[#parts+1]='回复 '..tostring(replies) end
    return table.concat(parts,' · ')
end
function Body.heading(row)
    local name=row.author and row.author~='' and row.author or '读者'
    local metadata=Body.metadata(row)
    return name..(metadata~='' and (' · '..metadata) or '')
end

function Body.new(options)
    return function(ctx)
        local d,s=ctx.deps,ctx.scale
        if options.full_text then
            return d.scrolltext:new{text=options.full_text,face=d.font:getFace('cfont',18),width=ctx.width,
                height=ctx.height,scroll_by_pan=true,dialog={}},{}
        end
        local Canvas=d.input:extend{}
        function Canvas:paintTo(bb,x,y)
            self.dimen.x,self.dimen.y=x,y
            if self.card then
                bb:paintBorder(x,y,self.dimen.w,self.dimen.h,s(self.focused and 2 or 1),d.colors.COLOR_DARK_GRAY,s(7))
            end
            for index,child in ipairs(self) do child:paintTo(bb,x+self.spots[index][1],y+self.spots[index][2]) end
        end
        function Canvas:onFocus() self.focused=true;ctx.repaint(function() return self.dimen end);return true end
        function Canvas:onUnfocus() self.focused=false;ctx.repaint(function() return self.dimen end);return true end
        function Canvas:onTapSelect() if self.callback then self.callback() end;return true end
        local function canvas(width,height)
            return Canvas:new{dimen=d.geom:new{w=math.floor(width),h=math.floor(height)},spots={}}
        end
        local function put(parent,child,x,y)
            parent[#parent+1]=child;parent.spots[#parent.spots+1]={math.floor(x),math.floor(y)}
            return #parent
        end
        local root,focus=canvas(ctx.width,ctx.height),{}
        local function card(item,y,height,header)
            local row=item.row
            local box=canvas(ctx.width,height);box.card=true
            box.callback=function() if item.callback then return item.callback() end end
            box.ges_events.TapSelect={d.gesture:new{ges='tap',range=function() return box.dimen end}}
            local inset,avatar_size=s(8),math.min(s(32),height-s(16))
            local initial=Text.utf8Window(row.author or '读者',1,1)
            if initial=='' then initial='人' end
            local avatar=ctx.cover_widget(nil,avatar_size,avatar_size,initial)
            local slot=put(box,avatar,inset,inset)
            local text_x=2*inset+avatar_size
            local text_width=ctx.width-text_x-inset
            put(box,d.text:new{text=row.author and row.author~='' and row.author or '读者',
                face=d.font:getFace('cfont',16),max_width=text_width,bold=true},text_x,inset)
            local metadata=Body.metadata(row)
            local footer=metadata~='' and s(19) or 0
            local content_y=s(30)
            local preview=row.content or ''
            if row.reply_to and row.reply_to~='' then preview='回复 '..row.reply_to..'：'..preview end
            local preview_height=math.max(s(16),height-content_y-inset-footer)
            local quote_widget
            if options.show_quote and row.abstract and row.abstract~='' and preview_height>=s(42) then
                local quote,_,more=Text.utf8Window(row.abstract,1,60)
                quote_widget=d.text:new{text='原文：'..quote..(more and '…' or ''),
                    face=d.font:getFace('cfont',12),max_width=text_width}
                put(box,quote_widget,text_x,content_y)
                content_y=content_y+s(18);preview_height=preview_height-s(18)
            end
            local preview_text=Text.utf8Window(preview,1,header and 280 or 180)
            local intro=d.textbox:new{text=preview_text,face=d.font:getFace('cfont',15),width=text_width,
                height=preview_height,height_adjust=false,line_height=0,height_overflow_show_ellipsis=true,
                alignment='left'}
            put(box,intro,text_x,content_y)
            if metadata~='' then
                put(box,d.text:new{text=metadata,face=d.font:getFace('cfont',13),max_width=text_width},
                    text_x,height-inset-s(14))
            end
            put(root,box,0,y)
            focus[#focus+1]={box}
            local cell={item=item,button=box,visual=box,frame=box,title_widget=box[2],intro_widget=intro,
                quote_widget=quote_widget,cover=avatar}
            ctx.cells[#ctx.cells+1]=cell
            if row.avatar_url then
                ctx.request_cover({id=row.author_id or row.id,cover_url=row.avatar_url,source_id='weread-avatar'},function(path)
                    if not path then return end
                    local old=cell.cover
                    local replacement=ctx.cover_widget(path,avatar_size,avatar_size,initial)
                    box[slot],cell.cover=replacement,replacement
                    if old and old.free then old:free() end
                    ctx.repaint(function() return box.dimen end)
                end)
            end
        end
        local y,gap=0,s(6)
        if options.review then
            local height=math.min(s(155),math.floor(ctx.height*.25))
            card({row=options.review,callback=options.on_full_text},0,height,true)
            y=height+gap
        end
        local items=options.items or {}
        if #items>0 then
            local height=math.min(s(136),math.floor((ctx.height-y-gap*(#items-1))/#items))
            for _,item in ipairs(items) do card(item,y,height);y=y+height+gap end
        else
            put(root,d.textbox:new{text=options.empty_text or '',face=d.font:getFace('cfont',16),
                width=ctx.width-s(16),height=math.max(s(20),ctx.height-y),height_adjust=false,
                height_overflow_show_ellipsis=true,alignment='left'},s(8),y)
        end
        return root,focus
    end
end
return Body
