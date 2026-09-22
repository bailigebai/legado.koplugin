-- Restricted expressions only: no statements, dynamic calls, regex, objects or host APIs.
local Json = require('legado.lib.json_codec')
local Expression = { MAX_BYTES = 4 * 1024 * 1024, MAX_DEPTH = 16, MAX_TOKENS = 128 }
local roots = { result = true, key = true, page = true, baseUrl = true }
local spaces = { '\194\160', '\225\154\128', '\226\128\128', '\226\128\129', '\226\128\130', '\226\128\131',
    '\226\128\132', '\226\128\133', '\226\128\134', '\226\128\135', '\226\128\136', '\226\128\137', '\226\128\138',
    '\226\128\168', '\226\128\169', '\226\128\175', '\226\129\159', '\227\128\128', '\239\187\191' }
local function trim(value)
    local first, last = 1, #value
    while first <= last do
        local width = value:sub(first, first):match('[ \t\r\n\v\f]') and 1 or nil
        if not width then for _, space in ipairs(spaces) do if value:sub(first, first + #space - 1) == space then width = #space; break end end end
        if not width then break end
        first = first + width
    end
    while last >= first do
        local width = value:sub(last, last):match('[ \t\r\n\v\f]') and 1 or nil
        if not width then for _, space in ipairs(spaces) do if value:sub(last - #space + 1, last) == space then width = #space; break end end end
        if not width then break end
        last = last - width
    end
    return value:sub(first, last)
end

function Expression.splitRule(rule)
    local quote, index = nil, 1
    while index <= #rule do
        local c = rule:sub(index, index)
        if quote then
            if c == '\\' then index = index + 1 elseif c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == '@' and rule:sub(index + 1, index + 2):lower() == 'js' then
            local finish = index + 3
            while finish <= #rule and rule:sub(finish, finish):match('%s') do finish = finish + 1 end
            if rule:sub(finish, finish) == ':' then return rule:sub(1, index - 1), rule:sub(finish + 1) end
        end
        index = index + 1
    end
end

local function compile(text)
    if type(text) ~= 'string' or #text > 4096 then error('expression length limit') end
    local tokens, i = {}, 1
    while i <= #text do
        local c = text:sub(i, i)
        if c:match('%s') then i = i + 1
        else
            local token = { kind = c }
            if c == '"' or c == "'" then
                local quote, output, closed = c, {}, false
                i = i + 1
                while i <= #text do
                    c = text:sub(i, i)
                    if c == quote then i, closed = i + 1, true; break end
                    if c:byte() < 32 then error('newline in string literal') end
                    if c == '\\' then
                        local escape = text:sub(i + 1, i + 1)
                        if escape == "'" then output[#output + 1] = "'"
                        elseif escape == 'v' then output[#output + 1] = '\\u000b'
                        elseif escape:match('^["\\/bfnrt]$') then output[#output + 1] = '\\' .. escape
                        elseif escape == 'u' and text:sub(i + 2, i + 5):match('^%x%x%x%x$') then
                            output[#output + 1] = text:sub(i, i + 5); i = i + 4
                        else error('unsupported string escape') end
                        i = i + 2
                    else output[#output + 1] = c == '"' and '\\"' or c; i = i + 1 end
                end
                if not closed then error('unterminated string') end
                token.kind, token.value = 'literal', Json.decode('"' .. table.concat(output) .. '"')
            elseif c:match('%d') then
                local number = text:sub(i):match('^%d+%.?%d*')
                token.kind, token.value, i = 'literal', tonumber(number), i + #number
            elseif c:match('[%a_]') then
                local name = text:sub(i):match('^[%a_][%w_]*')
                token.kind, token.value, i = 'name', name, i + #name
            elseif c:find('[().,%[%]+*/%%;%-]') then i = i + 1
            else error('unsupported expression token') end
            tokens[#tokens + 1] = token
            if #tokens > Expression.MAX_TOKENS then error('expression token limit') end
        end
    end
    local cursor, transforms, nesting = 1, 0, 0
    local function take(kind)
        local token = tokens[cursor]
        if not token or token.kind ~= kind then error('unexpected expression token') end
        cursor = cursor + 1
        return token.value
    end
    local function kind() return tokens[cursor] and tokens[cursor].kind end
    local function node(value, left, right)
        value.depth = 1 + math.max(left and left.depth or 0, right and right.depth or 0)
        if value.depth > Expression.MAX_DEPTH then error('expression depth limit') end
        return value
    end
    local expression, unary
    local function primary()
        local value
        if kind() == '(' then
            take('('); nesting = nesting + 1
            if nesting > Expression.MAX_DEPTH then error('expression nesting limit') end
            value = expression(); take(')'); nesting = nesting - 1
        elseif kind() == 'literal' then value = node({ kind = 'literal', value = take('literal') })
        elseif kind() == 'name' then
            local name = take('name')
            if not roots[name] then error('unknown expression variable') end
            value = node({ kind = 'variable', name = name })
        else error('expected expression value') end
        while kind() == '.' do
            take('.'); local method = take('name'); take('(')
            local args, index = {}, nil
            if method ~= 'trim' then
                args[1] = take('literal')
                if type(args[1]) ~= 'string' then error('string method requires literal strings') end
                if method == 'replace' then
                    take(','); args[2] = take('literal')
                    if type(args[2]) ~= 'string' or args[2]:find('$', 1, true) then error('replacement substitution is unsupported') end
                elseif method ~= 'split' or args[1] == '' then error('unsupported string method') end
            end
            take(')')
            if method == 'split' then
                take('['); index = take('literal'); take(']')
                if type(index) ~= 'number' or index % 1 ~= 0 or index < 0 or index > 1000 then error('split index limit') end
            end
            value = node({ kind = 'method', name = method, target = value, args = args, index = index }, value)
            transforms = transforms + 1
        end
        return value
    end
    unary = function()
        if kind() == '+' or kind() == '-' then
            local op = kind(); take(op); nesting = nesting + 1
            if nesting > Expression.MAX_DEPTH then error('expression nesting limit') end
            local right = unary(); nesting = nesting - 1
            return node({ kind = 'unary', op = op, right = right }, right)
        end
        return primary()
    end
    local function multiply()
        local left = unary()
        while kind() == '*' or kind() == '/' or kind() == '%' do
            local op = kind(); take(op); local right = unary()
            left = node({ kind = 'binary', op = op, left = left, right = right }, left, right)
        end
        return left
    end
    expression = function()
        local left = multiply()
        while kind() == '+' or kind() == '-' do
            local op = kind(); take(op); local right = multiply()
            left = node({ kind = 'binary', op = op, left = left, right = right }, left, right)
        end
        return left
    end
    local ast = expression()
    if kind() == ';' then take(';') end
    if kind() then error('trailing expression tokens') end
    ast.transforms = transforms
    return ast
end

function Expression.compile(text)
    local ok, ast = pcall(compile, text)
    if ok then return ast end
    return nil, 'unsupported restricted expression'
end

function Expression.evaluate(ast, context)
    local function checked(value)
        if type(value) == 'string' then if #value > Expression.MAX_BYTES then error('expression output limit') end
        elseif type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then error('invalid expression value') end
        return value
    end
    local function concat(a, b)
        a, b = tostring(a), tostring(b)
        if #a + #b > Expression.MAX_BYTES then error('expression output limit') end
        return a .. b
    end
    local function evaluate(node)
        if node.kind == 'literal' then return checked(node.value) end
        if node.kind == 'variable' then return checked(context[node.name]) end
        if node.kind == 'method' then
            local value = evaluate(node.target)
            if type(value) ~= 'string' then error('string method requires a string') end
            if node.name == 'trim' then return trim(value) end
            local separator = node.args[1]
            if node.name == 'replace' then
                local first, last = value:find(separator, 1, true)
                if not first then return value end
                return concat(concat(value:sub(1, first - 1), node.args[2]), value:sub(last + 1))
            end
            local start = 1
            for index = 0, node.index do
                local first, last = value:find(separator, start, true)
                if index == node.index then return value:sub(start, first and first - 1 or #value) end
                if not first then error('split index outside result') end
                start = last + 1
            end
        end
        local right = evaluate(node.right)
        if node.kind == 'unary' then
            if type(right) ~= 'number' then error('numeric operand required') end
            return checked(node.op == '-' and -right or right)
        end
        local left = evaluate(node.left)
        if node.op == '+' and (type(left) == 'string' or type(right) == 'string') then return concat(left, right) end
        if type(left) ~= 'number' or type(right) ~= 'number' then error('numeric operands required') end
        if node.op == '+' then return checked(left + right) end
        if node.op == '-' then return checked(left - right) end
        if node.op == '*' then return checked(left * right) end
        if node.op == '/' then return checked(left / right) end
        return checked(math.fmod(left, right))
    end
    local ok, value = pcall(evaluate, ast)
    if ok then return value end
    return nil, 'restricted expression exceeds its value or output limits'
end

return Expression
