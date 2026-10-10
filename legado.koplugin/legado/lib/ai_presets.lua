-- Shared by service, settings validation and UI; no network or storage here.
local Presets={}
Presets.providers={
    deepseek={label='DeepSeek',base_url='https://api.deepseek.com',model='deepseek-flash',models={
        {id='deepseek-flash',label='DeepSeek Flash'},
        {id='deepseek-v4-pro',label='DeepSeek V4 Pro'},
    }},
    mimo={label='小米 MiMo',base_url='https://api.xiaomimimo.com/v1',model='mimo-v2.6-pro',models={
        {id='mimo-v2.6-pro',label='MiMo 2.6 Pro'},
        {id='mimo-v2.6-flash',label='MiMo 2.6 Flash'},
    }},
}
local faithful='只分析给出的阅读内容；区分原文事实和推测，不编造信息，不透露后续情节。不确定的背景知识请明确说明。'
Presets.templates={
    {id='explain',label='通俗解释',prompt='请用通俗中文解释下面这段阅读内容。先说明不熟悉的名称或术语，再解释句子的意思和上下文；不要编造原文没有的信息。'},
    {id='background',label='名词背景',prompt='找出所选内容中的重要人物、地名、作品、典故和术语，说明含义、历史背景及其与原文的关系。'},
    {id='summary',label='段落总结',prompt='用三到五个要点总结所选段落，提炼主要信息、人物行动或论点，最后用一句话概括。'},
    {id='character',label='人物心理',prompt='结合所选内容分析人物的动机、情绪和人物关系；引用少量原句作为依据，明确哪些判断只是推测。'},
    {id='literary',label='文学赏析',prompt='赏析所选文字的意象、修辞、叙述视角、节奏与情感，解释表达效果，并结合原句说明。'},
    {id='argument',label='观点辨析',prompt='梳理所选内容的主张、前提、证据和推理，指出适用范围、潜在反例与值得追问的问题。'},
    {id='life',label='联系生活',prompt='说明所选内容对日常生活的启发，给出两三个具体可行的做法。举例时注明虚构情境，不把例子当作原文事实。'},
    {id='translation',label='翻译解读',prompt='将所选外语或文言内容翻译为自然的现代汉语，解释关键词、语法与语气；如原文已是现代汉语，说明难句和表达含义。'},
}
function Presets.validModel(value)
    return type(value)=='string' and #value>0 and #value<=128 and value:match('^[%w%._/%-:]+$')~=nil
end
function Presets.template(id)
    for _,item in ipairs(Presets.templates) do if item.id==(id or 'explain') then return item end end
end
function Presets.prompt(id)
    local item=Presets.template(id)
    return item and (item.prompt..'\n'..faithful)
end
return Presets
