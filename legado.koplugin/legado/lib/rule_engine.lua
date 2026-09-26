local Errors = require("legado.lib.errors")
local Capabilities = require("legado.lib.rule_capabilities")
local Expression = require('legado.lib.rule_expression')

local RuleEngine = {}
RuleEngine.__index = RuleEngine

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_text(value)
    return trim(tostring(value or ""):gsub("%s+", " "))
end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
    return result
end

local function parse_failure(message, details)
    return nil, Errors.new(Errors.PARSE_ERROR, message, details)
end

local function unsupported(message, details)
    return nil, Errors.new(Errors.UNSUPPORTED_RULE, message, details)
end

local function nonempty(values)
    if type(values) ~= "table" or #values == 0 then return false end
    for _, value in ipairs(values) do
        if value ~= nil and (type(value) ~= "string" or value ~= "") then return true end
    end
    return false
end

local function append(output, value)
    if value ~= nil then output[#output + 1] = value end
end

local function enforce_output_limit(values, engine)
    local maximum = engine and engine.max_output_items or Capabilities.LIMITS.MAX_OUTPUT_ITEMS
    if #values > maximum then
        return parse_failure("rule output exceeds the safe item limit", {
            limit = "output_items",
            maximum = maximum,
        })
    end
    return values
end

local function split_top_level(value, operator)
    local output, start = {}, 1
    local quote, square, parentheses, templates = nil, 0, 0, 0
    local index = 1
    while index <= #value do
        local character = value:sub(index, index)
        local pair = value:sub(index, index + 1)
        if quote then
            if character == "\\" then index = index + 1
            elseif character == quote then quote = nil end
        elseif character == "'" or character == '"' then quote = character
        elseif pair == "{{" then templates = templates + 1; index = index + 1
        elseif pair == "}}" and templates > 0 then templates = templates - 1; index = index + 1
        elseif templates == 0 then
            if character == "[" then square = square + 1
            elseif character == "]" then square = square - 1
            elseif character == "(" then parentheses = parentheses + 1
            elseif character == ")" then parentheses = parentheses - 1
            elseif square == 0 and parentheses == 0 and value:sub(index, index + #operator - 1) == operator then
                output[#output + 1] = value:sub(start, index - 1)
                start = index + #operator
                index = index + #operator - 1
            end
        end
        if square < 0 or parentheses < 0 or templates < 0 then return nil, "unbalanced rule delimiters" end
        index = index + 1
    end
    if quote or square ~= 0 or parentheses ~= 0 or templates ~= 0 then return nil, "unbalanced rule delimiters" end
    output[#output + 1] = value:sub(start)
    return output
end

local function matching_close(value, start, open_character, close_character)
    local depth, quote = 0, nil
    local index = start
    while index <= #value do
        local character = value:sub(index, index)
        if quote then
            if character == "\\" then index = index + 1
            elseif character == quote then quote = nil end
        elseif character == "'" or character == '"' then quote = character
        elseif character == open_character then depth = depth + 1
        elseif character == close_character then
            depth = depth - 1
            if depth == 0 then return index end
        end
        index = index + 1
    end
    return nil
end

local function descendants(node)
    local output, seen = {}, { [node] = true }
    local stack = {}
    local children = node.nodes or {}
    for index = #children, 1, -1 do stack[#stack + 1] = { node = children[index], depth = 1 } end
    while #stack > 0 do
        local item = stack[#stack]
        stack[#stack] = nil
        if type(item.node) ~= "table" or type(item.node.nodes) ~= "table" then return nil, "invalid_dom" end
        if seen[item.node] then return nil, "dom_cycle" end
        if item.depth > Capabilities.LIMITS.MAX_DOM_DEPTH then return nil, "dom_depth" end
        seen[item.node] = true
        output[#output + 1] = item.node
        if #output > Capabilities.LIMITS.MAX_HTML_NODES then return nil, "html_nodes" end
        for index = #item.node.nodes, 1, -1 do
            stack[#stack + 1] = { node = item.node.nodes[index], depth = item.depth + 1 }
        end
    end
    return output
end

local function node_attribute(node, name)
    if not node or type(node.attributes) ~= "table" then return nil end
    if node.attributes[name] ~= nil then return node.attributes[name] end
    local lower = name:lower()
    for key, value in pairs(node.attributes) do
        if tostring(key):lower() == lower then return value end
    end
    return nil
end

local function node_html(node)
    if node and type(node.getcontent) == "function" then return node:getcontent() end
    return ""
end

local function node_outer_html(node)
    if node and type(node.gettext) == "function" then return node:gettext() end
    return ""
end

local function ordered_text_segments(node, include_descendants)
    if not node or not node.root or type(node.root._text) ~= "string" then return {} end
    local output
    local cursor = node == node.root and 1 or (node._openend or 0) + 1
    local finish = node == node.root and #node.root._text or (node._closestart or cursor) - 1
    output = {}
    local children = {}
    for _, child in ipairs(node.nodes or {}) do children[#children + 1] = child end
    table.sort(children, function(left, right) return (left._openstart or 0) < (right._openstart or 0) end)
    for _, child in ipairs(children) do
        local child_start, child_end = child._openstart or cursor, child._closeend or child._openend or cursor - 1
        if child_start > cursor then output[#output + 1] = node.root._text:sub(cursor, child_start - 1) end
        if include_descendants then
            for _, segment in ipairs(ordered_text_segments(child, true)) do output[#output + 1] = segment end
        end
        if child_end >= cursor then cursor = child_end + 1 end
    end
    if cursor <= finish then output[#output + 1] = node.root._text:sub(cursor, finish) end
    return output
end

local function direct_text_segments(node)
    local cleaned = {}
    for _, value in ipairs(ordered_text_segments(node, false)) do
        value = normalize_text(value)
        if value ~= "" then cleaned[#cleaned + 1] = value end
    end
    return cleaned
end

function RuleEngine.new(options)
    options = options or {}
    local safe_functions = {}
    for name, implementation in pairs(options.safe_functions or {}) do
        safe_functions[tostring(name):lower()] = implementation
    end
    return setmetatable({
        json_decoder = options.json_decoder,
        html_parser = options.html_parser,
        url_resolver = options.url_resolver,
        safe_functions = safe_functions,
    }, RuleEngine)
end

function RuleEngine:_decode_json(input)
    if type(input) == "table" then return input end
    if type(input) ~= "string" then return parse_failure("JSON input must be a string or table") end
    local decoder = self.json_decoder
    local decode = type(decoder) == "function" and decoder or type(decoder) == "table" and decoder.decode
    if type(decode) ~= "function" then return parse_failure("JSON decoder is unavailable") end
    local ok, result = pcall(decode, input)
    if not ok then return parse_failure("malformed JSON input", { cause = tostring(result) }) end
    return result
end

local void_elements = {
    area=true,base=true,br=true,col=true,command=true,embed=true,hr=true,img=true,input=true,
    keygen=true,link=true,meta=true,param=true,source=true,track=true,wbr=true,
}

local raw_text_elements = { script = true, style = true }

local function markup_tag_end(input, start)
    local quote, index = nil, start + 1
    while index <= #input do
        local character = input:sub(index, index)
        if quote then
            if character == quote then quote = nil; index = index + 1
            else index = index + 1 end
        elseif character == "'" or character == '"' then quote = character; index = index + 1
        elseif character == ">" then return index
        else index = index + 1 end
    end
    return nil
end

local function validate_markup(input)
    input = tostring(input or "")
    local stack, index, lower = {}, 1, input:lower()
    local normalized, cursor = {}, 1
    while index <= #input do
        local raw_name = stack[#stack]
        if raw_text_elements[raw_name] then
            local _, close = lower:find("</%s*" .. raw_name .. "%s*>", index)
            if not close then return false, "unclosed tag " .. raw_name end
            stack[#stack] = nil
            index = close + 1
        else
            local start = input:find("<", index, true)
            if not start then break end
            if input:sub(start, start + 3) == "<!--" then
                local close = input:find("-->", start + 4, true)
                if not close then return false, "unterminated comment" end
                index = close + 3
            elseif input:sub(start):match("^<%s*[/]?%s*[%w%-]")
                or input:sub(start):match("^<%s*[!?]") then
                local close = markup_tag_end(input, start)
                if not close then return false, "unterminated tag" end
                local contents = input:sub(start + 1, close - 1)
                if not contents:match("^%s*[!?]") then
                    local slash, name, tail = contents:match("^%s*(/?)%s*([%w%-]+)(.*)$")
                    if name then
                        name = name:lower()
                        if slash == "/" and name == "br" then
                            -- HTML treats </br> as a line break; the vendor parser needs an opening tag.
                            normalized[#normalized + 1] = input:sub(cursor, start - 1)
                            normalized[#normalized + 1] = "<br>"
                            cursor = close + 1
                        elseif slash == "/" then
                            if stack[#stack] ~= name then return false, "mismatched closing tag " .. name end
                            stack[#stack] = nil
                        elseif not void_elements[name] and not tail:match("/%s*$") then
                            stack[#stack + 1] = name
                        end
                    end
                end
                index = close + 1
            else
                index = start + 1
            end
        end
    end
    if #stack > 0 then return false, "unclosed tag " .. stack[#stack] end
    if cursor == 1 then return true, nil, input end
    normalized[#normalized + 1] = input:sub(cursor)
    return true, nil, table.concat(normalized)
end

local function mask_raw_text_markup(input)
    local placeholders = {}
    for byte = 1, 31 do
        local candidate = string.char(byte)
        if not input:find(candidate, 1, true) then
            placeholders[#placeholders + 1] = candidate
            if #placeholders == 2 then break end
        end
    end
    if #placeholders < 2 then return nil end
    local masked_less, masked_greater = placeholders[1], placeholders[2]
    local output, cursor, index, lower = {}, 1, 1, input:lower()
    local masked = false
    while index <= #input do
        local start = input:find("<", index, true)
        if not start then break end
        if input:sub(start, start + 3) == "<!--" then
            local close = input:find("-->", start + 4, true)
            if not close then break end
            index = close + 3
        else
            local open_end = markup_tag_end(input, start)
            if not open_end then break end
            local contents = input:sub(start + 1, open_end - 1)
            local slash, name, tail = contents:match("^%s*(/?)%s*([%w%-]+)(.*)$")
            name = name and name:lower() or nil
            if slash == "" and raw_text_elements[name] and not tail:match("/%s*$") then
                local close_start, close_end = lower:find("</%s*" .. name .. "%s*>", open_end + 1)
                if not close_start then break end
                output[#output + 1] = input:sub(cursor, open_end)
                output[#output + 1] = (input:sub(open_end + 1, close_start - 1):gsub("[<>]", function(character)
                    masked = true
                    return character == "<" and masked_less or masked_greater
                end))
                output[#output + 1] = input:sub(close_start, close_end)
                cursor, index = close_end + 1, close_end + 1
            else
                index = open_end + 1
            end
        end
    end
    output[#output + 1] = input:sub(cursor)
    if not masked then return input end
    return table.concat(output), masked_less, masked_greater
end

function RuleEngine:_html_root(input, context)
    local root = type(context.current) == "table" and context.current or type(context.node) == "table" and context.node
    if not root then
        if type(input) ~= "string" then return parse_failure("HTML input must be a string") end
        local valid, reason, normalized = validate_markup(input)
        if not valid then return parse_failure("malformed HTML input", { cause = reason }) end
        input = normalized
        local parser = self.html_parser
        local parse = type(parser) == "function" and parser or type(parser) == "table" and parser.parse
        if type(parse) ~= "function" then return parse_failure("HTML parser is unavailable") end
        local parser_input, masked_less, masked_greater = mask_raw_text_markup(input)
        if not parser_input then return parse_failure("HTML input cannot be safely masked") end
        local ok
        ok, root = pcall(parse, parser_input, Capabilities.LIMITS.MAX_HTML_NODES)
        if not ok or type(root) ~= "table" or type(root.nodes) ~= "table" then
            return parse_failure("malformed HTML input", { cause = tostring(root) })
        end
        if masked_less and type(root._text) == "string" then
            root._text = root._text:gsub(".", function(character)
                if character == masked_less then return "<" end
                if character == masked_greater then return ">" end
                return character
            end)
        end
    end

    local seen, count = {}, 0
    local stack = { { node = root, depth = 0 } }
    local within, limit = true, nil
    while #stack > 0 do
        local item = stack[#stack]
        stack[#stack] = nil
        if type(item.node) ~= "table" or type(item.node.nodes) ~= "table" then within, limit = false, "invalid_dom"; break end
        if seen[item.node] then within, limit = false, "dom_cycle"; break end
        if item.depth > Capabilities.LIMITS.MAX_DOM_DEPTH then within, limit = false, "dom_depth"; break end
        seen[item.node] = true
        count = count + 1
        if count > Capabilities.LIMITS.MAX_HTML_NODES then within, limit = false, "html_nodes"; break end
        for index = #item.node.nodes, 1, -1 do
            local child = item.node.nodes[index]
            if type(child) ~= "table" or child.parent ~= item.node then
                within, limit = false, "parent_mismatch"
                break
            end
            stack[#stack + 1] = { node = child, depth = item.depth + 1 }
        end
        if not within then break end
    end
    if not within then
        return parse_failure("HTML input exceeds a safe DOM limit", {
            limit = limit,
            maximum = limit == "dom_depth" and Capabilities.LIMITS.MAX_DOM_DEPTH
                or limit == "html_nodes" and Capabilities.LIMITS.MAX_HTML_NODES or nil,
        })
    end
    return root
end

local function parse_json_path(path)
    path = trim(path)
    if path:lower():sub(1, 6) == "@json:" then path = trim(path:sub(7)) end
    if path:sub(1, 1) ~= "$" then return nil, "JSONPath must start with $" end
    local tokens, index = {}, 2
    while index <= #path do
        local character = path:sub(index, index)
        if character == "." then
            local recursive = path:sub(index, index + 1) == '..'
            local width = recursive and 2 or 1
            local name = path:sub(index + width):match("^([%w_%-]+)")
            if not name then return nil, "invalid JSONPath property" end
            tokens[#tokens + 1] = { kind = recursive and 'recursive' or 'property', name = name }
            index = index + #name + width
        elseif character == "[" then
            local close = matching_close(path, index, "[", "]")
            if not close then return nil, "unterminated JSONPath bracket" end
            local content = trim(path:sub(index + 1, close - 1))
            local quote, key = content:match("^(['\"])(.*)%1$")
            if quote then
                key = key:gsub("\\(['\"])", "%1")
                tokens[#tokens + 1] = { kind = "property", name = key }
            elseif content == "*" then
                tokens[#tokens + 1] = { kind = "wildcard" }
            elseif content:match("^%-?%d+$") then
                local number = tonumber(content)
                if number < 0 then return nil, "negative JSONPath indexes are unsupported" end
                tokens[#tokens + 1] = { kind = "index", index = number }
            else
                local property, operator, literal = content:match("^%?%(%s*@%.([%w_%-]+)%s*([!=]=)%s*(.-)%s*%)$")
                if not property then return nil, "unsupported JSONPath bracket expression" end
                local literal_quote, string_value = literal:match("^(['\"])(.*)%1$")
                local expected
                if literal_quote then expected = string_value:gsub("\\(['\"])", "%1")
                elseif literal == "true" then expected = true
                elseif literal == "false" then expected = false
                elseif tonumber(literal) ~= nil then expected = tonumber(literal)
                else return nil, "unsupported JSONPath filter literal" end
                tokens[#tokens + 1] = { kind = "filter", property = property, operator = operator, expected = expected }
            end
            index = close + 1
        else
            return nil, "unexpected JSONPath character"
        end
    end
    return tokens
end

function RuleEngine:_json_path(input, rule)
    local root, decode_error = self:_decode_json(input)
    if decode_error then return nil, decode_error end
    local tokens, token_error = parse_json_path(rule)
    if not tokens then return parse_failure(token_error) end
    local values = { root }
    local visited = 0
    for _, token in ipairs(tokens) do
        local next_values = {}
        for _, value in ipairs(values) do
            if token.kind == "property" and type(value) == "table" then append(next_values, value[token.name])
            elseif token.kind == 'recursive' then
                local seen, traversal_error = {}, nil
                local function visit(current, depth)
                    if traversal_error then return end
                    visited = visited + 1
                    if depth > Capabilities.LIMITS.MAX_DOM_DEPTH or visited > Capabilities.LIMITS.MAX_HTML_NODES then
                        traversal_error = 'recursive JSONPath traversal limit'; return
                    end
                    if type(current) ~= 'table' then return end
                    if seen[current] then traversal_error = 'recursive JSONPath contains a cycle'; return end
                    seen[current] = true
                    append(next_values, current[token.name])
                    if #next_values > (self.max_output_items or Capabilities.LIMITS.MAX_OUTPUT_ITEMS) then traversal_error = 'recursive JSONPath output limit'; return end
                    local keys = {}
                    for key in pairs(current) do
                        keys[#keys + 1] = key
                        if #keys > Capabilities.LIMITS.MAX_HTML_NODES then traversal_error = 'recursive JSONPath traversal limit'; return end
                    end
                    table.sort(keys, function(a, b)
                        if type(a) == 'number' and type(b) == 'number' then return a < b end
                        return tostring(a) < tostring(b)
                    end)
                    for _, key in ipairs(keys) do visit(current[key], depth + 1); if traversal_error then return end end
                    seen[current] = nil
                end
                visit(value, 1)
                if traversal_error then return parse_failure(traversal_error) end
            elseif token.kind == "index" and type(value) == "table" then append(next_values, value[token.index + 1])
            elseif token.kind == "wildcard" and type(value) == "table" then
                for index = 1, #value do append(next_values, value[index]) end
            elseif token.kind == "filter" and type(value) == "table" then
                for index = 1, #value do
                    local candidate = value[index]
                    if type(candidate) == "table" then
                        local matches = candidate[token.property] == token.expected
                        if (token.operator == "==" and matches) or (token.operator == "!=" and not matches) then append(next_values, candidate) end
                    end
                end
            end
        end
        values = next_values
        local limited, limit_error = enforce_output_limit(values, self)
        if not limited then return nil, limit_error end
    end
    local output = {}
    for _, value in ipairs(values) do output[#output + 1] = copy(value) end
    return enforce_output_limit(output, self)
end

local function parse_extractor(rule)
    -- Legado accepts a leading @ before a simple CSS tag (for example
    -- @a@text).  It is equivalent to a@text; remove only that harmless
    -- prefix so compound selectors keep their existing parsing rules.
    if rule:match("^@[%w%-]+@") then rule = rule:sub(2) end
    local quote, square, parentheses, last_at = nil, 0, 0, nil
    for index = 1, #rule do
        local character = rule:sub(index, index)
        if quote then
            if character == "\\" then index = index + 1
            elseif character == quote then quote = nil end
        elseif character == "'" or character == '"' then quote = character
        elseif character == "[" then square = square + 1
        elseif character == "]" then square = square - 1
        elseif character == "(" then parentheses = parentheses + 1
        elseif character == ")" then parentheses = parentheses - 1
        elseif character == "@" and square == 0 and parentheses == 0 then last_at = index end
    end
    if not last_at then return trim(rule), "text", nil, false end
    local extractor = trim(rule:sub(last_at + 1))
    if not extractor:match("^[%w_:%-]+$") then return nil, nil, "invalid CSS value extractor" end
    return trim(rule:sub(1, last_at - 1)), extractor, nil, true
end

local function tokenize_css(selector)
    local steps, buffer, pending = {}, {}, "descendant"
    local quote, square, parentheses = nil, 0, 0
    local function flush()
        local value = trim(table.concat(buffer))
        if value ~= "" then steps[#steps + 1] = { combinator = pending, selector = value }; pending = "descendant" end
        buffer = {}
    end
    local index = 1
    while index <= #selector do
        local character = selector:sub(index, index)
        if quote then
            buffer[#buffer + 1] = character
            if character == "\\" then index = index + 1; buffer[#buffer + 1] = selector:sub(index, index)
            elseif character == quote then quote = nil end
        elseif character == "'" or character == '"' then quote = character; buffer[#buffer + 1] = character
        elseif character == "[" then square = square + 1; buffer[#buffer + 1] = character
        elseif character == "]" then square = square - 1; buffer[#buffer + 1] = character
        elseif character == "(" then parentheses = parentheses + 1; buffer[#buffer + 1] = character
        elseif character == ")" then parentheses = parentheses - 1; buffer[#buffer + 1] = character
        elseif square == 0 and parentheses == 0 and character == ">" then flush(); pending = "child"
        elseif square == 0 and parentheses == 0 and character:match("%s") then
            flush()
        else buffer[#buffer + 1] = character end
        index = index + 1
    end
    if quote or square ~= 0 or parentheses ~= 0 then return nil, "unbalanced CSS selector" end
    flush()
    if #steps == 0 then return nil, "empty CSS selector" end
    return steps
end

local supported_pseudos = {
    ["not"]=true,eq=true,gt=true,lt=true,first=true,last=true,contains=true,
    containsown=true,has=true,["nth-child"]=true,["nth-of-type"]=true,["first-child"]=true,
}

local function parse_simple_selector(selector)
    local parsed = { attributes = {}, pseudos = {}, positional = {} }
    local index = 1
    if selector:sub(1, 1) == "*" then parsed.tag = "*"; index = 2
    else
        local tag = selector:sub(index):match("^([%w_%-]+)")
        if tag then parsed.tag = tag:lower(); index = index + #tag end
    end
    while index <= #selector do
        local character = selector:sub(index, index)
        if character == "#" or character == "." then
            local name = selector:sub(index + 1):match("^([%w_%-]+)")
            if not name then return nil, "invalid CSS id or class" end
            if character == "#" then parsed.id = name else parsed.classes = parsed.classes or {}; parsed.classes[#parsed.classes + 1] = name end
            index = index + #name + 1
        elseif character == "[" then
            local close = matching_close(selector, index, "[", "]")
            if not close then return nil, "unterminated CSS attribute selector" end
            local content = trim(selector:sub(index + 1, close - 1))
            local name, operator, value = content:match("^([%w_:%.-]+)%s*([~|%^$*]?=)%s*(.-)%s*$")
            if not name then name = content:match("^([%w_:%.-]+)$") end
            if not name then return nil, "invalid CSS attribute selector" end
            if operator then
                local quote, inner = value:match("^(['\"])(.*)%1$")
                if quote then value = inner end
                if value == "" then return nil, "empty CSS attribute comparison" end
            end
            parsed.attributes[#parsed.attributes + 1] = { name = name, operator = operator, value = value }
            index = close + 1
        elseif character == ":" then
            local name = selector:sub(index + 1):match("^([%w_%-]+)")
            if not name then return nil, "invalid CSS pseudo selector" end
            name = name:lower()
            if not supported_pseudos[name] then return nil, "unsupported CSS pseudo selector: " .. name end
            index = index + #name + 1
            local argument, minimum
            if selector:sub(index, index) == "(" then
                local close = matching_close(selector, index, "(", ")")
                if not close then return nil, "unterminated CSS pseudo selector" end
                argument = trim(selector:sub(index + 1, close - 1))
                local quote, inner = argument:match("^(['\"])(.*)%1$")
                if quote and (name == "contains" or name == "containsown") then argument = inner end
                index = close + 1
            end
            if (name == "first" or name == "last") and argument ~= nil then
                return nil, "CSS first/last do not accept arguments"
            end
            if name == "first-child" then
                if argument ~= nil then return nil, "CSS first-child does not accept arguments" end
                name, argument = "nth-child", "1"
            end
            if (name == "eq" or name == "gt" or name == "lt")
                and (not argument or not argument:match("^%-?%d+$")) then return nil, "CSS position requires an integer" end
            if name == "nth-child" or name == "nth-of-type" then
                argument = argument and argument:gsub("%s+", "")
                local offset = argument == "n" and 1 or argument and tonumber(argument:match("^n%+(%d+)$"))
                if offset then argument, minimum = tostring(math.max(1, offset)), true
                elseif not argument or not argument:match("^%d+$") or tonumber(argument) < 1 then
                    return nil, "CSS child position requires a positive integer"
                end
            end
            if (name == "not" or name == "contains" or name == "containsown" or name == "has")
                and (argument == nil or trim(argument) == "") then return nil, "CSS pseudo selector requires a nonempty argument" end
            local definition = { name = name, argument = argument, minimum = minimum }
            if name == "eq" or name == "gt" or name == "lt" or name == "first" or name == "last" then
                parsed.positional[#parsed.positional + 1] = definition
            else parsed.pseudos[#parsed.pseudos + 1] = definition end
        else return nil, "unexpected CSS selector character" end
    end
    return parsed
end

local function has_class(node, wanted)
    local class = node_attribute(node, "class") or ""
    for value in class:gmatch("%S+") do if value == wanted then return true end end
    return false
end

function RuleEngine:_node_text(node)
    return normalize_text(self.safe_functions.htmldecode(table.concat(ordered_text_segments(node, true))))
end

function RuleEngine:_node_own_text(node)
    return normalize_text(self.safe_functions.htmldecode(table.concat(direct_text_segments(node), " ")))
end

local function selector_recursion_error()
    return Errors.new(Errors.PARSE_ERROR, "selector recursion exceeds the safe limit", {
        limit = "recursion", maximum = Capabilities.LIMITS.MAX_RECURSION,
    })
end

function RuleEngine:_matches_simple(node, parsed, selector_depth)
    selector_depth = selector_depth or 1
    if selector_depth > Capabilities.LIMITS.MAX_RECURSION then return nil, selector_recursion_error() end
    if parsed.tag and parsed.tag ~= "*" and tostring(node.name):lower() ~= parsed.tag then return false end
    if parsed.id and node_attribute(node, "id") ~= parsed.id then return false end
    for _, class in ipairs(parsed.classes or {}) do if not has_class(node, class) then return false end end
    for _, definition in ipairs(parsed.attributes) do
        local actual = node_attribute(node, definition.name)
        local operator, expected = definition.operator, definition.value
        if not operator then if actual == nil then return false end
        elseif actual == nil then return false
        elseif operator == "=" and actual ~= expected then return false
        elseif operator == "^=" and actual:sub(1, #expected) ~= expected then return false
        elseif operator == "$=" and actual:sub(-#expected) ~= expected then return false
        elseif operator == "*=" and not actual:find(expected, 1, true) then return false
        elseif operator == "~=" then
            local found = false
            for word in actual:gmatch("%S+") do if word == expected then found = true; break end end
            if not found then return false end
        elseif operator == "|=" and actual ~= expected and actual:sub(1, #expected + 1) ~= expected .. "-" then return false end
    end
    for _, pseudo in ipairs(parsed.pseudos) do
        if pseudo.name == "contains" and not self:_node_text(node):find(pseudo.argument, 1, true) then return false
        elseif pseudo.name == "containsown" and not self:_node_own_text(node):find(pseudo.argument, 1, true) then return false
        elseif pseudo.name == "nth-child" then
            local wanted, position = tonumber(pseudo.argument), 0
            for index, child in ipairs((node.parent or {}).nodes or {}) do if child == node then position = index; break end end
            if pseudo.minimum and position < wanted or not pseudo.minimum and position ~= wanted then return false end
        elseif pseudo.name == "nth-of-type" then
            local wanted, position = tonumber(pseudo.argument), 0
            for _, child in ipairs((node.parent or {}).nodes or {}) do
                if tostring(child.name):lower() == tostring(node.name):lower() then position = position + 1 end
                if child == node then break end
            end
            if pseudo.minimum and position < wanted or not pseudo.minimum and position ~= wanted then return false end
        elseif pseudo.name == "not" then
            local nested, nested_error = parse_simple_selector(pseudo.argument)
            if not nested then return nil, nested_error end
            local matches, match_error = self:_matches_simple(node, nested, selector_depth + 1)
            if match_error then return nil, match_error end
            if matches then return false end
        elseif pseudo.name == "has" then
            local matches, select_error = self:_css_select(node, pseudo.argument, selector_depth + 1)
            if select_error then return nil, select_error end
            if #matches == 0 then return false end
        end
    end
    return true
end

local function apply_positions(values, definitions)
    for _, definition in ipairs(definitions) do
        local filtered, count = {}, #values
        if definition.name == "first" then if count > 0 then filtered[1] = values[1] end
        elseif definition.name == "last" then if count > 0 then filtered[1] = values[count] end
        else
            local wanted = tonumber(definition.argument)
            if wanted < 0 then wanted = count + wanted end
            for index, value in ipairs(values) do
                local zero = index - 1
                if (definition.name == "eq" and zero == wanted)
                    or (definition.name == "gt" and zero > wanted)
                    or (definition.name == "lt" and zero < wanted) then filtered[#filtered + 1] = value end
            end
        end
        values = filtered
    end
    return values
end

function RuleEngine:_css_select(root, selector, selector_depth, include_root)
    selector_depth = selector_depth or 1
    if selector_depth > Capabilities.LIMITS.MAX_RECURSION then return nil, selector_recursion_error() end
    local steps, step_error = tokenize_css(selector)
    if not steps then return parse_failure(step_error) end
    local subjects = { root }
    for step_index, step in ipairs(steps) do
        local parsed, simple_error = parse_simple_selector(step.selector)
        if not parsed then return parse_failure(simple_error) end
        local candidates, seen = {}, {}
        for _, subject in ipairs(subjects) do
            local pool, traversal_error
            if step.combinator == "child" then pool = subject.nodes or {}
            else pool, traversal_error = descendants(subject) end
            if not pool then
                return parse_failure("DOM traversal exceeds a safe limit", {
                    limit = traversal_error,
                    maximum = traversal_error == "dom_depth" and Capabilities.LIMITS.MAX_DOM_DEPTH
                        or traversal_error == "html_nodes" and Capabilities.LIMITS.MAX_HTML_NODES or nil,
                })
            end
            if include_root and step_index == 1 and step.combinator ~= "child" then
                table.insert(pool, 1, subject)
            end
            for _, node in ipairs(pool) do
                local matches, match_error = self:_matches_simple(node, parsed, selector_depth)
                if match_error then
                    if type(match_error) == "table" and match_error.code then return nil, match_error end
                    return parse_failure(match_error)
                end
                if matches and not seen[node] then seen[node] = true; candidates[#candidates + 1] = node end
            end
        end
        table.sort(candidates, function(left, right) return (left.index or 0) < (right.index or 0) end)
        subjects = apply_positions(candidates, parsed.positional)
        local limited, limit_error = enforce_output_limit(subjects, self)
        if not limited then return nil, limit_error end
    end
    return subjects
end

function RuleEngine:_extract_nodes(nodes, extractor, context)
    local output, lower = {}, extractor:lower()
    for _, node in ipairs(nodes) do
        if lower == "text" then output[#output + 1] = self:_node_text(node)
        elseif lower == "owntext" then output[#output + 1] = self:_node_own_text(node)
        elseif lower == "textnodes" then
            for _, value in ipairs(direct_text_segments(node)) do output[#output + 1] = self.safe_functions.htmldecode(value) end
        elseif lower == "html" then output[#output + 1] = node_html(node)
        else
            local value = node_attribute(node, extractor)
            if value ~= nil then
                if lower == "href" or lower == "src" then
                    local ok, resolved = pcall(self.url_resolver, context.baseUrl or "", value)
                    if not ok then return parse_failure("URL resolution failed", { cause = tostring(resolved) }) end
                    value = resolved
                end
                output[#output + 1] = value
            end
        end
    end
    return enforce_output_limit(output, self)
end

function RuleEngine:_css(input, rule, context)
    local selector, extractor, extractor_error = parse_extractor(rule)
    if not selector then return parse_failure(extractor_error) end
    local root, root_error = self:_html_root(input, context)
    if root_error then return nil, root_error end
    local nodes, select_error = self:_css_select(root, selector, 1)
    if select_error then return nil, select_error end
    return self:_extract_nodes(nodes, extractor, context)
end

local function default_rule_segments(rule)
    rule = trim(rule)
    if rule:sub(1, 1) == "@" then rule = rule:sub(2) end
    return split_top_level(rule, "@")
end

local function default_selector(segment)
    segment = trim(segment)
    if segment:match("%[%s*!?[%d%s,:%-]*%]$") then
        local _, err = unsupported("unsupported default selector index syntax")
        return nil, err
    end
    local base, mode, positions = segment:match("^(.-)([.!])([%d:%-]+)$")
    base = base or segment
    local definition = { positions = {}, exclude = mode == "!" }
    if positions then
        for _, position in ipairs(split_top_level(positions, ":")) do
            if not position:match("^%-?%d+$") then
                local _, err = unsupported("unsupported default selector index syntax")
                return nil, err
            end
            definition.positions[#definition.positions + 1] = tonumber(position)
        end
        local _, limit_error = enforce_output_limit(definition.positions)
        if limit_error then return nil, limit_error end
    end
    local kind, name = base:match("^([%a]+)%.(.+)$")
    kind = kind and kind:lower()
    if base == "" or base:lower() == "children" then definition.children = true
    elseif kind == "text" then definition.own_text = name:lower()
    elseif kind == "class" and name:find("%s") then
        if not name:match("^[%w_%-%s]+$") then
            local _, err = unsupported("unsupported default class selector")
            return nil, err
        end
        definition.css = '[class="' .. name .. '"]'
    elseif kind == "class" then definition.css = "." .. name
    elseif kind == "tag" then definition.css = name
    elseif kind == "id" then definition.css = "#" .. name
    else definition.css = base end
    return definition
end

function RuleEngine:_default_select(root, rule)
    local segments, segment_error = default_rule_segments(rule)
    if not segments then return parse_failure(segment_error) end
    local subjects = { root }
    for _, segment in ipairs(segments) do
        local definition, definition_error = default_selector(segment)
        if not definition then return nil, definition_error end
        local selected = {}
        for _, subject in ipairs(subjects) do
            local values, select_error
            if definition.children then values = subject.nodes or {}
            elseif definition.own_text then
                local pool, traversal_error = descendants(subject)
                if not pool then return parse_failure("invalid default selector DOM", { limit = traversal_error }) end
                table.insert(pool, 1, subject)
                values = {}
                for _, node in ipairs(pool) do
                    if self:_node_own_text(node):lower():find(definition.own_text, 1, true) then
                        values[#values + 1] = node
                    end
                end
            else values, select_error = self:_css_select(subject, definition.css, 1, true) end
            if select_error then return nil, select_error end
            if #definition.positions > 0 then
                local indexed, seen = {}, {}
                for _, position in ipairs(definition.positions) do
                    local index = position >= 0 and position + 1 or #values + position + 1
                    if values[index] and not seen[index] then
                        seen[index] = true
                        indexed[#indexed + 1] = values[index]
                    end
                end
                if definition.exclude then
                    indexed = {}
                    for index, value in ipairs(values) do
                        if not seen[index] then indexed[#indexed + 1] = value end
                    end
                end
                values = indexed
            end
            for _, value in ipairs(values) do selected[#selected + 1] = value end
        end
        subjects = selected
        local limited, limit_error = enforce_output_limit(subjects, self)
        if not limited then return nil, limit_error end
    end
    return subjects
end

local function current_nodes(root)
    if root and root.name == "root" and #(root.nodes or {}) == 1 then return { root.nodes[1] } end
    return { root }
end

local element_value_extractors = { text=true,owntext=true,textnodes=true,html=true,href=true,src=true }
local bare_attributes = { alt=true,title=true,content=true,value=true,id=true }

local function is_default_value_rule(rule)
    local lower = trim(rule):lower()
    if lower:match("^@[%w_:%-]+$") or element_value_extractors[lower]
        or bare_attributes[lower] or lower:match("^data%-[%w_%-]+$") then return true end
    local segments = default_rule_segments(lower)
    if not segments then return false end
    return #segments > 2 or #segments > 1
        and (segments[1]:match("^class%.") or segments[1]:match("^tag%.")
            or segments[1]:match("^id%.") or segments[1]:match("^text%.")
            or segments[1]:match("^children") or segments[1]:match("[.!][%d:%-]+$")) ~= nil
end

function RuleEngine:_default_value(input, rule, context, want_list)
    local root, root_error = self:_html_root(input, context)
    if root_error then return nil, root_error end
    local segments, segment_error = default_rule_segments(rule)
    if not segments then return parse_failure(segment_error) end
    local extractor = table.remove(segments)
    local nodes
    if #segments == 0 then nodes = current_nodes(root)
    else
        local selection_root = segments[1]:lower():match("^children") and current_nodes(root)[1] or root
        nodes, root_error = self:_default_select(selection_root, table.concat(segments, "@"))
        if root_error then return nil, root_error end
    end
    local values, value_error = self:_extract_nodes(nodes, extractor, context)
    if value_error then return nil, value_error end
    if want_list or #values <= 1 then return values end
    local strings = {}
    for _, value in ipairs(values) do strings[#strings + 1] = tostring(value) end
    return { table.concat(strings, "\n") }
end

local function parse_xpath_step(raw)
    local name = raw:match("^([%w_%-]+)") or (raw:sub(1, 1) == "*" and "*")
    if not name then return nil, "invalid XPath step" end
    local predicates, index = {}, #name + 1
    while index <= #raw do
        if raw:sub(index, index) ~= "[" then return nil, "invalid XPath predicate" end
        local close = matching_close(raw, index, "[", "]")
        if not close then return nil, "unterminated XPath predicate" end
        predicates[#predicates + 1] = trim(raw:sub(index + 1, close - 1))
        index = close + 1
    end
    return { name = name:lower(), predicates = predicates }
end

function RuleEngine:_xpath_predicates(values, predicates)
    for _, predicate in ipairs(predicates) do
        if predicate:match("^%d+$") then
            local wanted = tonumber(predicate)
            values = values[wanted] and { values[wanted] } or {}
        elseif predicate == "last()" then values = #values > 0 and { values[#values] } or {}
        else
            local attribute, quote, expected = predicate:match("^@([%w_:%-]+)%s*=%s*(['\"])(.-)%2$")
            local contains_attribute, contains_quote, contains_expected = predicate:match("^contains%s*%(%s*@([%w_:%-]+)%s*,%s*(['\"])(.-)%2%s*%)$")
            local text_quote, text_expected = predicate:match("^contains%s*%(%s*text%s*%(%s*%)%s*,%s*(['\"])(.-)%1%s*%)$")
            if not attribute and not contains_attribute and not text_quote then return nil, "unsupported XPath predicate" end
            local filtered = {}
            for _, node in ipairs(values) do
                local matches = attribute and node_attribute(node, attribute) == expected
                    or contains_attribute and tostring(node_attribute(node, contains_attribute) or ""):find(contains_expected, 1, true) ~= nil
                    or text_quote and self:_node_own_text(node):find(text_expected, 1, true) ~= nil
                if matches then filtered[#filtered + 1] = node end
            end
            values = filtered
        end
    end
    return values
end

function RuleEngine:_xpath(input, rule, context, preserve_elements)
    local root, root_error = self:_html_root(input, context)
    if root_error then return nil, root_error end
    local path = trim(rule)
    if path:lower():sub(1, 7) == "@xpath:" then path = trim(path:sub(8)) end
    local subjects, index = { root }, 1
    if path:sub(1, 1) == "." then index = 2 end
    if index > #path then
        if preserve_elements then return subjects end
        local output = {}
        for _, node in ipairs(subjects) do output[#output + 1] = self:_node_text(node) end
        return output
    end
    while index <= #path do
        local axis
        if path:sub(index, index + 1) == "//" then axis = "descendant"; index = index + 2
        elseif path:sub(index, index) == "/" then axis = "child"; index = index + 1
        else axis = "child" end
        if index > #path then return parse_failure("XPath cannot end with an axis") end
        local start, quote, square = index, nil, 0
        while index <= #path do
            local character = path:sub(index, index)
            if quote then
                if character == "\\" then index = index + 1
                elseif character == quote then quote = nil end
            elseif character == "'" or character == '"' then quote = character
            elseif character == "[" then square = square + 1
            elseif character == "]" then square = square - 1
            elseif character == "/" and square == 0 then break end
            index = index + 1
        end
        local raw = trim(path:sub(start, index - 1))
        if raw == "text()" or raw:match("^@[%w_:%-]+$") then
            if index <= #path then return parse_failure("XPath value extraction must be the final step") end
            local output = {}
            for _, node in ipairs(subjects) do
                if raw == "text()" then
                    for _, value in ipairs(direct_text_segments(node)) do
                        output[#output + 1] = self.safe_functions.htmldecode(value)
                    end
                else append(output, node_attribute(node, raw:sub(2))) end
            end
            return enforce_output_limit(output, self)
        end
        local step, step_error = parse_xpath_step(raw)
        if not step then return parse_failure(step_error) end
        local next_subjects = {}
        for _, subject in ipairs(subjects) do
            local pool = axis == "descendant" and descendants(subject) or (subject.nodes or {})
            local group = {}
            for _, node in ipairs(pool) do
                if step.name == "*" or tostring(node.name):lower() == step.name then group[#group + 1] = node end
            end
            local filtered, predicate_error = self:_xpath_predicates(group, step.predicates)
            if not filtered then return parse_failure(predicate_error) end
            for _, node in ipairs(filtered) do next_subjects[#next_subjects + 1] = node end
        end
        subjects = next_subjects
        local limited, limit_error = enforce_output_limit(subjects, self)
        if not limited then return nil, limit_error end
    end
    local output = {}
    if preserve_elements then return subjects end
    for _, node in ipairs(subjects) do output[#output + 1] = self:_node_text(node) end
    return enforce_output_limit(output, self)
end

local function find_template_end(value, start)
    local depth, index, quote = 1, start + 2, nil
    while index <= #value - 1 do
        local pair = value:sub(index, index + 1)
        local character = value:sub(index, index)
        if quote then
            if character == "\\" then index = index + 2
            elseif character == quote then quote = nil; index = index + 1
            else index = index + 1 end
        elseif character == "'" or character == '"' then quote = character; index = index + 1
        elseif pair == "{{" then depth = depth + 1; index = index + 2
        elseif pair == "}}" then
            depth = depth - 1
            if depth == 0 then return index end
            index = index + 2
        else index = index + 1 end
    end
    return nil
end

local function split_arguments(value)
    local values, buffer, quote, parentheses = {}, {}, nil, 0
    local index = 1
    while index <= #value do
        local character = value:sub(index, index)
        if quote then
            buffer[#buffer + 1] = character
            if character == "\\" then index = index + 1; buffer[#buffer + 1] = value:sub(index, index)
            elseif character == quote then quote = nil end
        elseif character == "'" or character == '"' then quote = character; buffer[#buffer + 1] = character
        elseif character == "(" then parentheses = parentheses + 1; buffer[#buffer + 1] = character
        elseif character == ")" then parentheses = parentheses - 1; buffer[#buffer + 1] = character
        elseif character == "," and parentheses == 0 then values[#values + 1] = trim(table.concat(buffer)); buffer = {}
        else buffer[#buffer + 1] = character end
        index = index + 1
    end
    if quote or parentheses ~= 0 then return nil, "unbalanced function arguments" end
    if #buffer > 0 or trim(value) ~= "" then values[#values + 1] = trim(table.concat(buffer)) end
    return values
end

function RuleEngine:_expand_templates(input, rule, context, state, template_depth)
    if template_depth > Capabilities.LIMITS.MAX_TEMPLATE_DEPTH then
        return parse_failure("template nesting exceeds the safe limit", {
            limit = "template_depth", maximum = Capabilities.LIMITS.MAX_TEMPLATE_DEPTH,
        })
    end
    local output, cursor = {}, 1
    while cursor <= #rule do
        local start = rule:find("{{", cursor, true)
        if not start then output[#output + 1] = rule:sub(cursor); break end
        output[#output + 1] = rule:sub(cursor, start - 1)
        local close = find_template_end(rule, start)
        if not close then return parse_failure("unterminated template") end
        local expression = rule:sub(start + 2, close - 1)
        if expression:find("{{", 1, true) then
            local expanded, nested_error = self:_expand_templates(input, expression, context, state, template_depth + 1)
            if nested_error then return nil, nested_error end
            expression = expanded
        end
        local value, expression_error = self:_template_expression(input, trim(expression), context, state, template_depth)
        if expression_error then return nil, expression_error end
        output[#output + 1] = value == nil and "" or tostring(value)
        cursor = close + 2
    end
    return table.concat(output)
end

function RuleEngine:_template_argument(input, argument, context, state, template_depth)
    local quote, inner = argument:match("^(['\"])(.*)%1$")
    if quote then return (inner:gsub("\\(['\"])", "%1")) end
    if argument == "key" or argument == "page" or argument == "baseUrl" or argument == "result" then return context[argument] end
    if argument:find("[@$./#%[]") or argument:find("%s[>%w_%-]*[.#]") then
        local values, rule_error = self:_evaluate(input, argument, context, false, state.depth + 1, template_depth)
        if rule_error then return nil, rule_error end
        return values[1]
    end
    return argument
end

function RuleEngine:_template_expression(input, expression, context, state, template_depth)
    if expression == "key" or expression == "page" or expression == "baseUrl" or expression == "result" then return context[expression] end
    local root = expression:match('^([%a_][%w_]*)')
    if expression:match('^[%d%(%+%-%\'"]') or root == 'key' or root == 'page' or root == 'baseUrl' or root == 'result' then
        local ast, compile_error = Expression.compile(expression)
        if not ast then return unsupported(compile_error) end
        local value, value_error = Expression.evaluate(ast, context)
        if value_error then return parse_failure(value_error) end
        return value
    end
    local name, arguments_text = expression:match("^([%a_][%w_]*)%s*%((.*)%)$")
    if name then
        local normalized = name:lower()
        if not Capabilities.SAFE_FUNCTIONS[normalized] then return unsupported("template function is unsupported", { function_name = name }) end
        local implementation = self.safe_functions[normalized]
        if type(implementation) ~= "function" then return unsupported("template function is unavailable", { function_name = name }) end
        local raw_arguments, argument_error = split_arguments(arguments_text)
        if not raw_arguments then return parse_failure(argument_error) end
        local arguments = {}
        for _, raw in ipairs(raw_arguments) do
            local value, value_error = self:_template_argument(input, raw, context, state, template_depth)
            if value_error then return nil, value_error end
            arguments[#arguments + 1] = value
        end
        if normalized == "resolveurl" then table.insert(arguments, 1, context.baseUrl or "") end
        local ok, value = pcall(implementation, unpack(arguments))
        if not ok then return parse_failure("safe template function failed", { function_name = name, cause = tostring(value) }) end
        return value
    end
    local values, rule_error = self:_evaluate(input, expression, context, false, state.depth + 1, template_depth)
    if rule_error then return nil, rule_error end
    return values[1]
end

local function whole_template(rule)
    local stripped = trim(rule)
    if stripped:sub(1, 2) ~= "{{" then return false end
    local close = find_template_end(stripped, 1)
    return close == #stripped - 1
end

local function template_rule_shell(rule)
    local output, cursor = {}, 1
    while cursor <= #rule do
        local start = rule:find("{{", cursor, true)
        if not start then output[#output + 1] = rule:sub(cursor); break end
        output[#output + 1] = rule:sub(cursor, start - 1)
        local close = find_template_end(rule, start)
        if not close then return nil end
        output[#output + 1] = "legadodynamic"
        cursor = close + 2
    end
    return table.concat(output)
end

local TEMPLATE_MARKER = "legadodynamic"

local function valid_expanded_css(rule)
    local selector, _, extractor_error = parse_extractor(rule)
    if not selector then return false, extractor_error end
    local steps, step_error = tokenize_css(selector)
    if not steps then return false, step_error end
    for _, step in ipairs(steps) do
        local _, simple_error = parse_simple_selector(step.selector)
        if simple_error then return false, simple_error end
    end
    return true
end

local numeric_template_pseudos = { "eq", "gt", "lt", "nth-child", "nth-of-type" }
local numeric_template_pseudo_set = {}
for _, name in ipairs(numeric_template_pseudos) do numeric_template_pseudo_set[name] = true end

local function replace_numeric_template_slots(selector)
    local output, index, quote, square, parentheses, replacements = {}, 1, nil, 0, 0, 0
    while index <= #selector do
        local character = selector:sub(index, index)
        if quote then
            output[#output + 1] = character
            if character == "\\" then
                index = index + 1
                output[#output + 1] = selector:sub(index, index)
            elseif character == quote then quote = nil end
            index = index + 1
        elseif character == "\\" then
            output[#output + 1] = character
            index = index + 1
            output[#output + 1] = selector:sub(index, index)
            index = index + 1
        elseif character == "'" or character == '"' then
            quote = character
            output[#output + 1] = character
            index = index + 1
        elseif character == "[" then square = square + 1; output[#output + 1] = character; index = index + 1
        elseif character == "]" then square = square - 1; output[#output + 1] = character; index = index + 1
        elseif character == "(" then parentheses = parentheses + 1; output[#output + 1] = character; index = index + 1
        elseif character == ")" then parentheses = parentheses - 1; output[#output + 1] = character; index = index + 1
        elseif character == ":" and square == 0 and parentheses == 0 then
            local name = selector:sub(index + 1):match("^([%w_%-]+)")
            local normalized_name = name and name:lower()
            local value
            if normalized_name and numeric_template_pseudo_set[normalized_name] then
                value = selector:sub(index + #name + 1):match(
                    "^%(%s*" .. TEMPLATE_MARKER .. "%s*%)")
            end
            if value then
                output[#output + 1] = ":" .. normalized_name .. "(1)"
                index = index + #name + #value + 1
                replacements = replacements + 1
            else output[#output + 1] = character; index = index + 1 end
        else output[#output + 1] = character; index = index + 1 end
    end
    return table.concat(output), replacements
end

local function template_css_shell(rule)
    local selector, extractor, extractor_error, has_extractor = parse_extractor(rule)
    if not selector then return false, extractor_error end
    local marker_found = has_extractor and extractor == TEMPLATE_MARKER
    if has_extractor and extractor:find(TEMPLATE_MARKER, 1, true) and not marker_found then
        return false, "template must occupy a complete extractor slot"
    end
    local steps, step_error = tokenize_css(selector)
    if not steps then return false, step_error end
    local function complete_slot(value)
        if type(value) ~= "string" or not value:find(TEMPLATE_MARKER, 1, true) then return true end
        marker_found = true
        return value == TEMPLATE_MARKER
    end
    for _, step in ipairs(steps) do
        local shell_selector, replacements = replace_numeric_template_slots(step.selector)
        if replacements > 0 then marker_found = true end
        local parsed, simple_error = parse_simple_selector(shell_selector)
        if not parsed then return false, simple_error end
        if not complete_slot(parsed.tag) or not complete_slot(parsed.id) then
            return false, "template must occupy a complete tag or id slot"
        end
        for _, class in ipairs(parsed.classes or {}) do
            if not complete_slot(class) then return false, "template must occupy a complete class slot" end
        end
        for _, attribute in ipairs(parsed.attributes or {}) do
            if not complete_slot(attribute.name) or not complete_slot(attribute.value) then
                return false, "template must occupy a complete attribute slot"
            end
        end
        for _, pseudo in ipairs(parsed.pseudos or {}) do
            if not complete_slot(pseudo.argument) then return false, "template must occupy a complete pseudo slot" end
        end
    end
    return marker_found
end

local function template_evaluation_mode(rule, expanded)
    if whole_template(rule) then return "literal" end
    local shell = template_rule_shell(rule)
    if not shell then return "invalid" end
    local stripped = trim(shell)
    if stripped:match("^@json:") or stripped:sub(1, 1) == "$"
        or stripped:match("^@xpath:") or stripped:sub(1, 1) == "/"
        or stripped:sub(1, 2) == "./" then return "rule" end
    local shell_is_css = template_css_shell(shell)
    if shell_is_css then
        local expanded_is_css = valid_expanded_css(expanded)
        return expanded_is_css and "rule" or "invalid"
    end
    return "literal"
end

function RuleEngine:_simple(input, rule, context, state, template_depth)
    if rule:find("{{", 1, true) then
        local expanded, template_error = self:_expand_templates(input, rule, context, state, template_depth + 1)
        if template_error then return nil, template_error end
        local mode = template_evaluation_mode(rule, expanded)
        if mode == "invalid" then return parse_failure("invalid templated rule") end
        if mode == "literal" then return { expanded } end
        return self:_evaluate(input, expanded, context, state.want_list, state.depth + 1, template_depth)
    end
    local stripped = trim(rule)
    if stripped:lower():match("^@json:") or stripped:sub(1, 1) == "$" then return self:_json_path(input, stripped) end
    if stripped:lower():match("^@css:") then return self:_css(input, trim(stripped:sub(6)), context) end
    if stripped:lower():match("^@xpath:") or stripped:sub(1, 1) == "/" or stripped:sub(1, 2) == "./" or stripped:sub(1, 3) == ".//" then
        return self:_xpath(input, stripped, context)
    end
    if is_default_value_rule(stripped) then return self:_default_value(input, stripped, context, state.want_list) end
    return self:_css(input, stripped, context)
end

function RuleEngine:_evaluate(input, rule, context, want_list, depth, template_depth)
    depth, template_depth = depth or 1, template_depth or 0
    if depth > Capabilities.LIMITS.MAX_RECURSION then
        return parse_failure("rule recursion exceeds the safe limit", {
            limit = "recursion", maximum = Capabilities.LIMITS.MAX_RECURSION,
        })
    end
    local unsafe_code, unsafe_message = Capabilities.findUnsupported(rule)
    if unsafe_code then return unsupported(unsafe_message, { construct = unsafe_code }) end
    local prefix, expression = Expression.splitRule(rule)
    if expression then
        local ast = Expression.compile(expression)
        if not ast or ast.transforms == 0 then return unsupported('unsupported restricted expression') end
        local values, err
        if trim(prefix) == '' then values = { input }
        else values, err = self:_evaluate(input, prefix, context, true, depth + 1, template_depth) end
        if err then return nil, err end
        local output = {}
        for _, value in ipairs(values or {}) do
            local scope = { result = value, page = context.page, key = context.key, baseUrl = context.baseUrl }
            local transformed, transform_error = Expression.evaluate(ast, scope)
            if transform_error then return parse_failure(transform_error) end
            output[#output + 1] = transformed
        end
        return enforce_output_limit(output, self)
    end
    rule = trim(rule)
    if rule == "" then return {} end

    local cleanup, cleanup_error = split_top_level(rule, "##")
    if not cleanup then return parse_failure(cleanup_error) end
    if #cleanup > 1 then
        if #cleanup > 3 or trim(cleanup[2]) == "" then return parse_failure("invalid cleanup expression") end
        local values, value_error = self:_evaluate(input, cleanup[1], context, true, depth + 1, template_depth)
        if value_error then return nil, value_error end
        local output = {}
        for _, value in ipairs(values) do
            local ok, replaced = pcall(string.gsub, tostring(value), cleanup[2], cleanup[3] or "")
            if not ok then return parse_failure("invalid Lua cleanup pattern", { cause = tostring(replaced) }) end
            output[#output + 1] = replaced
        end
        return enforce_output_limit(output, self)
    end

    local fallbacks, fallback_error = split_top_level(rule, "||")
    if not fallbacks then return parse_failure(fallback_error) end
    if #fallbacks > 1 then
        for _, part in ipairs(fallbacks) do
            local values, value_error = self:_evaluate(input, part, context, want_list, depth + 1, template_depth)
            if value_error then return nil, value_error end
            if nonempty(values) then return values end
        end
        return {}
    end

    local concatenated, concatenation_error = split_top_level(rule, "&&")
    if not concatenated then return parse_failure(concatenation_error) end
    if #concatenated > 1 then
        local output = {}
        for _, part in ipairs(concatenated) do
            local values, value_error = self:_evaluate(input, part, context, true, depth + 1, template_depth)
            if value_error then return nil, value_error end
            for _, value in ipairs(values) do output[#output + 1] = value end
        end
        local limited, limit_error = enforce_output_limit(output, self)
        if not limited then return nil, limit_error end
        if want_list then return output end
        local strings = {}
        for _, value in ipairs(output) do strings[#strings + 1] = tostring(value) end
        return { table.concat(strings) }
    end

    local state = { depth = depth, want_list = want_list }
    return self:_simple(input, rule, context, state, template_depth)
end

function RuleEngine:parse(input, rule, context, want_list)
    if type(rule) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "rule must be a string") end
    local unsafe_code, unsafe_message = Capabilities.findUnsupported(rule)
    if unsafe_code then return nil, Errors.new(Errors.UNSUPPORTED_RULE, unsafe_message, { construct = unsafe_code }) end
    context = type(context) == "table" and context or {}
    local ok, values, err = pcall(self._evaluate, self, input, rule, context, want_list == true, 1, 0)
    if not ok then
        return nil, Errors.new(Errors.PARSE_ERROR, "rule evaluation failed safely", { cause = tostring(values) })
    end
    if err then return nil, err end
    local limited, limit_error = enforce_output_limit(values, self)
    if not limited then return nil, limit_error end
    if want_list == true then
        local output = {}
        for _, value in ipairs(values) do output[#output + 1] = copy(value) end
        return output, nil
    end
    if values[1] == nil then return nil, nil end
    return copy(values[1]), nil
end

function RuleEngine:_parse_elements(input, rule, context, depth)
    if depth > Capabilities.LIMITS.MAX_RECURSION then
        return parse_failure("rule recursion exceeds the safe limit", {
            limit = "recursion", maximum = Capabilities.LIMITS.MAX_RECURSION,
        })
    end
    rule = trim(rule)
    if rule == "" then return {} end
    local _, expression = Expression.splitRule(rule)
    if expression then return self:_evaluate(input, rule, context, true, depth, 0) end

    local cleanup, cleanup_error = split_top_level(rule, "##")
    if not cleanup then return parse_failure(cleanup_error) end
    if #cleanup > 1 then
        if #cleanup > 3 or trim(cleanup[2]) == "" then return parse_failure("invalid cleanup expression") end
        local values, value_error = self:_parse_elements(input, cleanup[1], context, depth + 1)
        if value_error then return nil, value_error end
        local output = {}
        for _, value in ipairs(values) do
            local ok, replaced = pcall(string.gsub, tostring(value), cleanup[2], cleanup[3] or "")
            if not ok then return parse_failure("invalid Lua cleanup pattern", { cause = tostring(replaced) }) end
            output[#output + 1] = replaced
        end
        return enforce_output_limit(output, self)
    end

    if rule:find("{{", 1, true) then
        local expanded, expand_error = self:_expand_templates(input, rule, context,
            { depth = depth, want_list = true }, 1)
        if expand_error then return nil, expand_error end
        return self:_parse_elements(input, expanded, context, depth + 1)
    end

    local fallbacks, fallback_error = split_top_level(rule, "||")
    if not fallbacks then return parse_failure(fallback_error) end
    if #fallbacks > 1 then
        for _, part in ipairs(fallbacks) do
            local values, value_error = self:_parse_elements(input, part, context, depth + 1)
            if value_error then return nil, value_error end
            if nonempty(values) then return values end
        end
        return {}
    end

    local concatenated, concatenation_error = split_top_level(rule, "&&")
    if not concatenated then return parse_failure(concatenation_error) end
    if #concatenated > 1 then
        local output = {}
        for _, part in ipairs(concatenated) do
            local values, value_error = self:_parse_elements(input, part, context, depth + 1)
            if value_error then return nil, value_error end
            for _, value in ipairs(values) do output[#output + 1] = value end
        end
        return enforce_output_limit(output, self)
    end

    if rule:lower():match("^@json:") or rule:sub(1, 1) == "$" then return self:_json_path(input, rule) end
    if rule:lower():match("^@xpath:") or rule:sub(1, 1) == "/" or rule:sub(1, 2) == "./" or rule:sub(1, 3) == ".//" then
        local values, xpath_error = self:_xpath(input, rule, context, true)
        if xpath_error then return nil, xpath_error end
        local output = {}
        for _, value in ipairs(values) do
            output[#output + 1] = type(value) == "table" and node_outer_html(value) or copy(value)
        end
        return enforce_output_limit(output, self)
    end

    local lower = rule:lower()
    local segments = default_rule_segments(lower)
    local value_extractor = segments and #segments == 2 and element_value_extractors[trim(segments[2])]
    if not lower:match("^@css:") and (lower:match("^@?class%.") or lower:match("^@?tag%.")
        or lower:match("^@?id%.") or lower:match("^@?text%.") or lower:match("^@?children")
        or segments and #segments > 1 and not value_extractor or lower:match("[.!][%d:%-]+$")) then
        local root, root_error = self:_html_root(input, context)
        if root_error then return nil, root_error end
        local nodes, select_error = self:_default_select(root, rule)
        if select_error then return nil, select_error end
        local output = {}
        for _, node in ipairs(nodes) do output[#output + 1] = node_outer_html(node) end
        return enforce_output_limit(output, self)
    end

    local css_rule = trim(rule:gsub("^@%s*[Cc][Ss][Ss]:%s*", ""))
    local selector, extractor, extractor_error, has_extractor = parse_extractor(css_rule)
    if not selector then return parse_failure(extractor_error) end
    local root, root_error = self:_html_root(input, context)
    if root_error then return nil, root_error end
    local nodes, select_error = self:_css_select(root, selector, 1)
    if select_error then return nil, select_error end
    if has_extractor then return self:_extract_nodes(nodes, extractor, context) end
    local output = {}
    for _, node in ipairs(nodes) do output[#output + 1] = node_outer_html(node) end
    return enforce_output_limit(output, self)
end

-- Only catalog selection gets a larger output allowance. DOM, recursion and
-- byte limits stay intact; this scoped engine cannot affect concurrent searches.
function RuleEngine:parseCatalogElements(input, rule, context)
    local catalog = setmetatable({max_output_items=10000}, {__index=self})
    return catalog:parseElements(input, rule, context)
end

function RuleEngine:parseElements(input, rule, context)
    if type(rule) ~= "string" then return nil, Errors.new(Errors.INVALID_INPUT, "rule must be a string") end
    local unsafe_code, unsafe_message = Capabilities.findUnsupported(rule)
    if unsafe_code then return nil, Errors.new(Errors.UNSUPPORTED_RULE, unsafe_message, { construct = unsafe_code }) end
    context = type(context) == "table" and context or {}
    local ok, values, err = pcall(self._parse_elements, self, input, rule, context, 1)
    if not ok then
        return nil, Errors.new(Errors.PARSE_ERROR, "element rule evaluation failed safely", { cause = tostring(values) })
    end
    if err then return nil, err end
    local limited, limit_error = enforce_output_limit(values, self)
    if not limited then return nil, limit_error end
    local output = {}
    for _, value in ipairs(values) do output[#output + 1] = copy(value) end
    return output, nil
end

function RuleEngine:expandTemplate(value, context)
    if type(value) ~= "string" then
        return nil, Errors.new(Errors.INVALID_INPUT, "template value must be a string")
    end
    local unsafe_code, unsafe_message = Capabilities.findUnsupported(value)
    if unsafe_code then return nil, Errors.new(Errors.UNSUPPORTED_RULE, unsafe_message, { construct = unsafe_code }) end
    if not value:find("{{", 1, true) then return value, nil end
    context = type(context) == "table" and context or {}
    local ok, expanded, err = pcall(self._expand_templates, self, "", value, context,
        { depth = 1, want_list = false }, 1)
    if not ok then
        return nil, Errors.new(Errors.PARSE_ERROR, "template expansion failed safely", { cause = tostring(expanded) })
    end
    if err then return nil, err end
    return expanded, nil
end

return RuleEngine
