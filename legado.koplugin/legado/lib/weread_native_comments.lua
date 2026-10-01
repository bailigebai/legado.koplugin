local Text=require('legado.lib.leko_text')
local Native={}
Native.__index=Native
function Native.new(reader,document,open)
    local view=reader.view
    if not view or not view.registerViewModule or not reader.document.findAllText then return nil end
    local self=setmetatable({reader=reader,document=document,open=open,rows={},locations={},generation=0,
        ui=require('ui/uimanager'),screen=require('device').screen},Native)
    self.mark=require('ui/widget/textwidget'):new{text='评',face=require('ui/font'):getFace('cfont',12)}
    view:registerViewModule('legado_comments',self)
    self.zone={id='legado_inline_comments',ges='tap',screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
        overrides={'tap_forward','tap_backward','tap_link','readerhighlight_tap'},
        handler=function(ges)
            if not self:current() or not ges or not ges.pos then return false end
            for _,target in ipairs(self:getTargets()) do
                local p=ges.pos
                if p.x>=target.x and p.x<target.x+target.w and p.y>=target.y and p.y<target.y+target.h then
                    return self.open(#target.ranges==1 and target.ranges[1] or target.ranges)
                end
            end
            return false
        end}
    if reader.registerTouchZones then reader:registerTouchZones{self.zone} end
    return self
end
function Native:current()
    return not self.closed and not self.document.closed
        and (not self.document.chapter_comments or self.document.chapter_comments:current())
end
function Native:setRows(rows)
    if not self:current() then return false end
    self.generation=self.generation+1
    if self.job then self.ui:unschedule(self.job);self.job=nil end
    self.rows=rows or {}
    local queue,seen={},{}
    for _,row in ipairs(self.rows) do
        if row.position and not seen[row.range] and #queue<100 then
            seen[row.range]=true;queue[#queue+1]=row
        end
    end
    self.queue=queue
    local generation,index=self.generation,0
    local function advance()
        self.job=nil
        if not self:current() or generation~=self.generation then return end
        repeat index=index+1 until index>#queue or self.locations[queue[index].range]==nil
        local row=queue[index]
        if not row then self.ui:setDirty(self.reader,'ui');return end
        local quote=Text.plainText(row.abstract)
        local ok,matches=false,nil
        if quote~='' and #quote<=2048 then
            ok,matches=pcall(self.reader.document.findAllText,self.reader.document,quote,false,0,2,false,0)
        end
        local found=ok and matches and #matches==1 and matches[1]
        self.locations[row.range]=found and found.start and found['end'] and
            {first=found.start,last=found['end'],quote=quote} or false
        self.ui:setDirty(self.reader,'ui')
        self.job=advance;self.ui:scheduleIn(.01,advance)
    end
    self.job=advance;self.ui:scheduleIn(.01,advance)
    return true
end
function Native:getTargets()
    local targets={}
    if not self:current() then return targets end
    local width,height=self.screen:getWidth(),self.screen:getHeight()
    local marker_width=self.mark:getSize().w
    local ok,margins=pcall(function() return self.reader.document:getPageMargins() end)
    local margin=ok and type(margins)=='table' and tonumber(margins.right) or 12
    -- Paint only inside the native page margin, never over the chapter text.
    if margin<marker_width then return targets end
    local marker_x=width-marker_width
    local groups={}
    for _,row in ipairs(self.queue or {}) do
        local location=self.locations[row.range]
        if location then
            local boxes_ok,boxes=pcall(self.reader.document.getScreenBoxesFromPositions,
                self.reader.document,location.first,location.last,true)
            local box=boxes_ok and boxes and boxes[1]
            if box and box.y>=0 and box.y+box.h<=height then
                local key=math.floor(box.y/12)
                local target=groups[key]
                if not target then
                    target={x=math.max(0,width-36),y=math.max(0,box.y-6),w=36,
                        h=math.max(36,box.h+12),marker_x=marker_x,marker_y=box.y,ranges={}}
                    groups[key]=target;targets[#targets+1]=target
                end
                target.ranges[#target.ranges+1]=row.range
            end
        end
    end
    return targets
end
function Native:paintTo(buffer,x,y)
    for _,target in ipairs(self:getTargets()) do self.mark:paintTo(buffer,(x or 0)+target.marker_x,(y or 0)+target.marker_y) end
end
function Native:rangesForSelection(text)
    if not self:current() then return nil end
    text=Text.plainText(text)
    if text=='' then return nil end
    local ranges={}
    for _,row in ipairs(self.queue or {}) do
        local location=self.locations[row.range]
        if location and (text:find(location.quote,1,true) or location.quote:find(text,1,true)) then
            ranges[#ranges+1]=row.range
        end
    end
    return #ranges==1 and ranges[1] or ranges
end
function Native:close()
    if self.closed then return end
    self.closed=true;self.generation=self.generation+1
    if self.job then self.ui:unschedule(self.job);self.job=nil end
    if self.reader.unRegisterTouchZones then self.reader:unRegisterTouchZones{self.zone} end
    local modules=self.reader.view.view_modules
    if modules and modules.legado_comments==self then modules.legado_comments=nil end
    if self.mark.free then self.mark:free() end
    self.rows,self.queue,self.locations={},{},{}
end
return Native
