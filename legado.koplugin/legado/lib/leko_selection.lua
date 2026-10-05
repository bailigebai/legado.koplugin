local Text=require('legado.lib.leko_text')
local Selection={}
Selection.__index=Selection

local function bounds(item,width)
    if item.selection_bounds then return item.selection_bounds end
    local widget=item.widget
    local chars=Text.utf8Chars(item.element.text)
    local result={}
    if widget._xtext then
        local shaping=widget._xshaping or widget._xtext:shapeLine(widget._shape_start,widget._shape_end,
            widget._shape_idx_to_substitute_with_ellipsis)
        local clusters,pen={},0
        for _,glyph in ipairs(shaping) do
            local index=glyph.text_index
            if index then
                local cluster=clusters[index]
                if not cluster then cluster={x0=pen,x1=pen,length=glyph.cluster_len or 1,rtl=glyph.is_rtl};clusters[index]=cluster end
                cluster.x1=pen+glyph.x_advance
                cluster.length=math.max(cluster.length,glyph.cluster_len or 1)
            end
            pen=pen+glyph.x_advance
        end
        for index,cluster in pairs(clusters) do
            local step=(cluster.x1-cluster.x0)/cluster.length
            for n=0,cluster.length-1 do
                local offset=cluster.rtl and cluster.length-n-1 or n
                result[index+n]={x0=cluster.x0+offset*step,x1=cluster.x0+(offset+1)*step}
            end
        end
    end
    -- Non-XText rendering uses the same kerning/bold measurement as TextWidget.
    local RenderText=require('ui/rendertext')
    local previous=0
    for index=1,#chars do
        if not result[index] then
            local measured=RenderText:sizeUtf8Text(0,width,widget.face,table.concat(chars,'',1,index),true,widget.bold).x
            result[index]={x0=previous,x1=measured};previous=measured
        else previous=result[index].x1 end
    end
    item.selection_bounds,item.selection_chars=result,chars
    return result
end
local function position(item,index)
    local line=item.element
    return {chapter=1,paragraph=line.paragraph,
        char=math.max(line.start_char,math.min(line.next_char-1,line.start_char+index-(line.prefix_chars or 0)-1))}
end
local function hit(page,widgets,pos,clamp)
    if not pos or not tonumber(pos.x) or not tonumber(pos.y) then return nil end
    local chosen,distance
    for _,item in ipairs(widgets) do
        local line=item.element
        if line and line.type=='line' then
            local delta=pos.y<item.y and item.y-pos.y or pos.y>=item.y+line.height and pos.y-item.y-line.height or 0
            if delta==0 then chosen=item;break end
            if clamp and (not distance or delta<distance) then chosen,distance=item,delta end
        end
    end
    if not chosen then return nil end
    if not clamp and (pos.x<chosen.x or pos.x>chosen.x+page.geometry.content_width) then return nil end
    local measured=bounds(chosen,page.geometry.content_width)
    local index,nearest,best=nil,nil,nil
    for i,rect in ipairs(measured) do
        local x=pos.x-chosen.x
        if x>=rect.x0 and x<rect.x1 then index=i;break end
        local delta=math.min(math.abs(x-rect.x0),math.abs(x-rect.x1))
        if not best or delta<best then nearest,best=i,delta end
    end
    index=index or nearest
    if not index then return nil end
    return position(chosen,index)
end
function Selection.new(page,widgets,pos,model)
    local start=hit(page,widgets,pos,false)
    if not start then return nil end
    return setmetatable({page=page,widgets=widgets,model=model,anchor=start,focus=Text.positionCopy(start),endpoint='focus'},Selection)
end
function Selection:move(pos)
    local value=hit(self.page,self.widgets,pos,true)
    if not value then return false end
    self[self.endpoint]=value
    return true
end
function Selection:range()
    if Text.positionLess(self.focus,self.anchor) then return self.focus,self.anchor end
    return self.anchor,self.focus
end
function Selection:_indices(item)
    local first,last=self:range()
    local line=item.element
    if not line or line.type~='line' or line.paragraph<first.paragraph or line.paragraph>last.paragraph then return nil end
    local from=math.max(line.start_char,line.paragraph==first.paragraph and first.char or line.start_char)
    local to=math.min(line.next_char-1,line.paragraph==last.paragraph and last.char or line.next_char-1)
    if from>to then return nil end
    local prefix=line.prefix_chars or 0
    return from-line.start_char+prefix+1,math.min(Text.utf8Length(line.text),to-line.start_char+prefix+1)
end
function Selection:text()
    local pieces,paragraph={},nil
    if self.model then
        local first,last=self:range()
        for index=first.paragraph,last.paragraph do
            local value=self.model.paragraphs[index]
            local start=index==first.paragraph and first.char or 1
            local ending=index==last.paragraph and last.char or Text.utf8Length(value)
            local hint=self.model._utf8_hints and self.model._utf8_hints[index]
            pieces[#pieces+1]=Text.utf8Window(value,start,ending-start+1,hint and hint.char,hint and hint.byte)
        end
        return table.concat(pieces,'\n')
    end
    for _,item in ipairs(self.widgets) do
        local first,last=self:_indices(item)
        if first then
            bounds(item,self.page.geometry.content_width)
            if paragraph and paragraph~=item.element.paragraph then pieces[#pieces+1]='\n' end
            pieces[#pieces+1]=table.concat(item.selection_chars,'',first,last)
            paragraph=item.element.paragraph
        end
    end
    return table.concat(pieces)
end
function Selection:rects()
    local result={}
    for _,item in ipairs(self.widgets) do
        local first,last=self:_indices(item)
        if first then
            local measured=bounds(item,self.page.geometry.content_width)
            local row={}
            for i=first,last do
                local rect=measured[i]
                if rect then row[#row+1]={x=math.floor(item.x+rect.x0),y=item.y,
                    w=math.max(1,math.ceil(rect.x1-rect.x0)),h=item.element.height} end
            end
            table.sort(row,function(a,b) return a.x<b.x end)
            local merged
            for _,rect in ipairs(row) do
                if merged and rect.x<=merged.x+merged.w+1 then merged.w=math.max(merged.w,rect.x+rect.w-merged.x)
                else merged=rect;result[#result+1]=rect end
            end
        end
    end
    return result
end
-- Reuse the actual shaped glyph bounds for passive links without changing
-- the reader's active selection or source character positions.
function Selection.rectsForRange(page,widgets,first,last)
    return setmetatable({page=page,widgets=widgets,anchor=first,focus=last},Selection):rects()
end
return Selection
