require('library_screen_stub')
local A=require('assertions')
local App=require('legado.ui.app')
local Presenter=require('legado.ui.presenter')
local count=0
local function eq(expected,actual,why) count=count+1;A.equal(expected,actual,why) end

local source_book={id='source-1',source_id='source',name='书源书'}
local local_book={id='local-1',source_id='local',is_local=true,local_path='/books/one.epub',name='本地书'}
local writes={}
local storage={
    listShelf=function() return {source_book} end,
    getProgress=function() end,
    updateBooks=function(_,books)
        writes[#writes+1]=books
        for _,book in ipairs(books) do
            if book.id==local_book.id then local_book.custom_categories=book.custom_categories end
        end
        return true
    end,
}
local settings={get=function(_,key) if key=='shelf_categories' then return {'待读'} end end}
local local_library={scan=function() return {local_book} end}
local shown={}
local presenter=Presenter.new{ui_manager={show=function(_,widget) shown[#shown+1]=widget end,close=function() end}}
local app=App.new{storage=storage,settings=settings,local_library=local_library,
    show=function(view) return presenter:show(view) end}
presenter.app=app
local function last() return shown[#shown] end
local function press(field,label)
    for _,item in ipairs(last()[field] or {}) do
        if item.text==label then return item.callback() end
    end
    error('missing action '..label)
end

app:openBookshelf('local')
eq('local-1',last().items[1].book.id,'local shelf shows the scanned local book')
press('actions','整理书架')
press('items','批量选择')
last().items[1].callback()
eq(true,last().selected_books['local-1'],'local book is selected')
press('actions','整理书架')
press('items','批量分类')
eq('编辑分类',last().title,'local batch selection reaches category editor')
press('item_table','待读')
eq(1,#writes,'batch category writes selected local book')
eq('local-1',writes[1][1].id,'source shelf book is excluded')
eq('待读',local_book.custom_categories[1],'local book receives category')

last().close_callback()
eq(true,last().batch_select,'return from category editor preserves current batch mode')
last().header_action.callback()
eq('sources',last().storage and presenter.library_view.source_mode,'header switches to source shelf')
eq(false,last().batch_select,'switching shelves exits batch mode')
eq(nil,last().selected_books['local-1'],'switching shelves clears hidden local selection')

return count
