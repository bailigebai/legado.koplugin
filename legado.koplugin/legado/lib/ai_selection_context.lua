local Context={BUTTON='11_legado_ai'}

function Context.detach(reader)
    if not reader then return end
    local context=reader.legado_ai_context
    if context and context.owned then context.document.closed=true end
    reader.legado_ai_context=nil
    if reader.highlight and reader.highlight.removeFromHighlightDialog then
        reader.highlight:removeFromHighlightDialog(Context.BUTTON)
    end
end

-- Share one action across local books and generated source/WeRead documents.
-- The context guards both cached buttons and late answers after a book closes.
function Context.attach(reader,analyze,document)
    if not reader or not reader.highlight or not reader.highlight.addToHighlightDialog then return false end
    Context.detach(reader)
    local context={document=document or {reader=reader,closed=false},owned=not document}
    reader.legado_ai_context=context
    reader.highlight:addToHighlightDialog(Context.BUTTON,function(highlight)
        return {text='AI 解释',callback=function()
            if reader.legado_ai_context~=context or context.document.closed or not reader.document then return false end
            local selected=highlight.selected_text and highlight.selected_text.text
            if type(selected)~='string' or selected=='' then return false end
            local result,err=analyze(selected,context.document)
            if result and not err and highlight.onClose then highlight:onClose() end
            return result,err
        end}
    end)
    return true
end

return Context
