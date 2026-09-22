local assertx = require("assertions")
local HtmlParser = require("legado.vendor.htmlparser")

local count = 0
for _, html in ipairs({
    [[<a href ="/chapter/1" title = 'Chapter one'>One</a>]],
    [[<a href= "/chapter/1" title= 'Chapter one'>One</a>]],
    [[<a href = "/chapter/1" title = 'Chapter one'>One</a>]],
    [[<a href="/chapter/1" title='Chapter one'>One</a>]],
    [[<a disabled href = /chapter/1 title = 'Chapter one'>One</a>]],
    [[<a href= /chapter/1 title='Chapter one' disabled>One</a>]],
}) do
    local root = HtmlParser.parse(html)
    local node = root.nodes[1]
    assertx.equal("/chapter/1", node.attributes.href, "HTML attribute whitespace preserves the chapter URL")
    assertx.equal("Chapter one", node.attributes.title, "both quote styles preserve the full value")
    count = count + 2
end

return count
