-- One ordered list for the picker, persisted settings and receipt renderer.
local Styles = {
    list = {
        {'classic', '阅读票据'}, {'simple', '封面进度卡'}, {'calendar', '日历胶片'},
        {'bookshop', '书店结账单'}, {'boarding', '阅读登机牌'}, {'library', '图书馆借阅卡'},
        {'cinema', '影院票根'}, {'postcard', '阅读明信片'}, {'newspaper', '阅读日报'},
        {'exhibition', '展览入场券'}, {'passport', '阅读护照'}, {'contact', '胶片联系表'},
        {'archive', '阅读档案'}, {'timeline', '阅读时间轴'}, {'bookmark', '极简书签'},
    },
    allowed = {},
}
for _,entry in ipairs(Styles.list) do Styles.allowed[entry[1]] = true end
function Styles.normalize(value)
    return type(value)=='string' and Styles.allowed[value] and value or 'classic'
end
return Styles
