local h=require('native_footer_harness').install()
local A=require('assertions')
local count=0
local function eq(want,got,message) count=count+1;A.equal(want,got,message) end
local Settings=require('legado.lib.settings')
local Adapter=require('legado.lib.koreader_reader_ui')
local Chrome=require('legado.lib.reader_chrome')
local persisted,fail={},false
local backend={read=function() return persisted end,write=function(value) if fail then return false end;persisted=value;return true end}
local settings=Settings.new(backend)
eq('details',settings:get('progress_bar_mode'),'default shows bar and chapter details')
eq('hidden',Settings.new{read=function() return {progress_bar=false} end}:get('progress_bar_mode'),'old disabled preference migrates to hidden')
local reader,footer=h:newReader()
local original=footer.settings
local adapter=Adapter.new{settings=settings}
local proxy={reading_state={book={name='阳神'},chapters={{title='第一章 天意民意'}},index=1,catalog_complete=true},getProgressFraction=function() return 9/13 end}
local chrome=Chrome.new(reader,settings,proxy):start()
for _,mode in ipairs{'details','bar','hidden','details'} do
    settings:set('progress_bar_mode',mode)
    eq(true,adapter:applyProgressBar(reader),'native footer supports mode '..mode)
    chrome:refresh()
    footer:onUpdateFooter()
    if reader.view.footer_visible then footer:paintTo(h.buffer,0,0) end
    chrome:paintTo(h.buffer,0,0)
    eq(mode~='hidden',reader.view.footer_visible,'visibility follows saved mode '..mode)
    eq(mode=='details' and '69% · 约 13 分钟' or '',footer:genFooterText(),'only requested footer items are rendered')
    if mode=='hidden' then eq(0,footer:getHeight(),'hidden footer releases its space')
    else
        eq(9/13,footer.progress_bar.percentage,'bar shows current chapter progress')
        eq(true,chrome.labels.br.dimen.y+chrome.labels.br:getSize().h < footer.footer_content.dimen.y,'whole-book progress stays above native footer')
    end
end
eq(original.disable_progress_bar,false,'native settings table is not changed in place')
eq(original.all_at_once,false,'native item defaults are preserved')
settings:set('progress_bar_font_size',22)
settings:set('progress_bar_height',16)
adapter:applyProgressBar(reader)
footer:paintTo(h.buffer,0,0)
chrome:refresh();chrome:paintTo(h.buffer,0,0)
eq(22,footer.footer_text.face.orig_size,'chosen font size reaches native font')
eq(true,footer.height>=footer.footer_text:getSize().h+6,'row expands when font is taller than requested height')
local painted=h.painted[footer.footer_text]
eq(true,painted.y>=footer.footer_content.dimen.y,'text top stays inside native footer')
eq(true,painted.y+painted.h<=h.dimensions.h,'text bottom stays on screen')
eq(true,chrome.labels.br.dimen.y+chrome.labels.br:getSize().h<painted.y,'large detail text does not overlap novel progress')
-- Repeated mode changes and rotation must preserve the measured text height.
for _,dimensions in ipairs{{600,800},{800,600}} do
    h.dimensions.w,h.dimensions.h=unpack(dimensions)
    for _,mode in ipairs{'hidden','details','bar','details'} do
        settings:set('progress_bar_mode',mode)
        adapter:applyProgressBar(reader);chrome:refresh()
        footer:onUpdateFooter()
        if reader.view.footer_visible then footer:paintTo(h.buffer,0,0) end
        chrome:paintTo(h.buffer,0,0)
        if mode=='details' then
            local rect=h.painted[footer.footer_text]
            eq(true,rect.y>=footer.footer_content.dimen.y,'mode changes keep large text inside footer')
            eq(true,rect.x>=0 and rect.x+rect.w<=h.dimensions.w,'details stay horizontally on screen')
            eq(true,chrome.labels.br.dimen.y+chrome.labels.br:getSize().h<rect.y,'rotation preserves vertical separation')
        end
    end
end
reader.statistics=nil
eq('69% · 时间待估算',footer:genFooterText(),'missing reading-speed estimate is explicit')
eq('details',Settings.new(backend):get('progress_bar_mode'),'mode persists')
eq(22,Settings.new(backend):get('progress_bar_font_size'),'size persists')
settings:set('progress_bar',false)
eq('details',settings:get('progress_bar_mode'),'independent toggle preserves the selected display mode')
eq(false,settings:get('progress_bar'),'independent toggle is persisted separately')
settings:set('progress_bar_mode','bar')
eq(true,settings:get('progress_bar'),'mode updates legacy boolean atomically')
fail=true
eq(nil,settings:set('progress_bar_mode','hidden'),'failed write is reported')
eq('bar',settings:get('progress_bar_mode'),'failed mode save keeps old state')
eq(true,settings:get('progress_bar'),'failed mode save keeps old toggle')
fail=false
eq(8,settings:set('progress_bar_font_size',-1),'font size lower bound')
eq(22,settings:set('progress_bar_font_size',100),'font size upper bound')
eq(48,settings:set('progress_bar_height',999),'row height upper bound')
eq(false,adapter:applyProgressBar({view={footer={settings={disabled=true}}}}),'globally disabled native footer is reported')
settings:set('progress_bar_mode','hidden')
eq(true,adapter:applyProgressBar({view={footer={settings={disabled=true}}}}),'hiding a globally disabled footer is already satisfied')
settings:set('progress_bar_mode','details')

-- Exercise the real App/SettingsView path used by the reader toolbar and all controls.
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local menu={new=function(_,options) return options end}
local app=App.new{settings=settings,reader_session={ui=adapter}}
local view=app:openSettings({reader=reader,chrome=chrome},true)
local presenter=Presenter.new{ui_manager=h.ui,menu=menu,info_message=menu}
presenter:_settings(view)
for _,item in ipairs(presenter.settings_widget.item_table) do if item.text=='底部进度栏' then item.callback();break end end
eq('底部进度栏',presenter.settings_widget.title,'toolbar header/footer settings expose footer controls')
eq('阅读进度：启用',presenter.settings_widget.item_table[1].text,'footer settings expose an independent enable toggle')
presenter.settings_widget.item_table[1].callback()
eq(false,settings:get('progress_bar'),'footer toggle can disable the progress display')
eq('details',settings:get('progress_bar_mode'),'footer toggle does not change the selected display mode')
eq(false,reader.view.footer_visible,'disabling the footer updates the current reader')
presenter.settings_widget.item_table[1].callback()
eq(true,settings:get('progress_bar'),'footer toggle can re-enable the progress display')
eq('details',settings:get('progress_bar_mode'),'re-enabling restores the prior display mode')
for i,mode in ipairs{'hidden','bar','details'} do
    local old=presenter.settings_widget
    old.item_table[2].sub_item_table[i].callback()
    old.close_callback() -- Native Menu closes the selected leaf after its callback.
    eq('底部进度栏',presenter.settings_widget.title,'native auto-close does not dismiss replacement settings')
    eq(mode,settings:get('progress_bar_mode'),'mode menu saves '..mode)
    eq(mode~='hidden',reader.view.footer_visible,'mode menu updates the current reader')
end
presenter.settings_widget.item_table[3].sub_item_table[1].callback()
eq(8,footer.settings.text_font_size,'font menu updates the current reader')
presenter.settings_widget.item_table[4].sub_item_table[7].callback()
eq(48,footer.height,'height menu updates the current reader')
fail=true
local previous=presenter.settings_widget
previous.item_table[2].sub_item_table[1].callback()
eq('details',settings:get('progress_bar_mode'),'failed UI save keeps stored display mode')
eq(true,reader.view.footer_visible,'failed UI save keeps the live footer unchanged')
eq(true,h.shown.text:find('设置保存失败',1,true)~=nil,'failed UI save displays a useful error')
fail=false
previous.close_callback()
eq('页眉页脚设置',presenter.settings_widget.title,'footer return restores header settings')
local last=presenter.settings_widget
last.close_callback()
eq(last,h.closed[#h.closed],'header settings return closes the entire menu')
chrome:close()
return count
