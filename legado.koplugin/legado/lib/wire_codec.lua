local Wire = {}
Wire.MAX_DEPTH = 64
Wire.MAX_ENTRIES = 100000
-- Keep the pipe just above the 5 MiB source-import limit; framing overhead is small.
Wire.MAX_BYTES = 5 * 1024 * 1024 + 128 * 1024

local function append(state, value)
    state.bytes = state.bytes + #value
    if state.bytes > Wire.MAX_BYTES then error("wire payload exceeds byte limit") end
    state.parts[#state.parts + 1] = value
end

local function sized(marker, value)
    value = tostring(value)
    return marker .. tostring(#value) .. ":" .. value
end

local function encode_value(value, output, seen, depth)
    if depth > Wire.MAX_DEPTH then error("wire value exceeds maximum depth") end
    local value_type = type(value)
    if value_type == "nil" then append(output, "N")
    elseif value_type == "boolean" then append(output, value and "B1" or "B0")
    elseif value_type == "number" then append(output, sized("D", value))
    elseif value_type == "string" then append(output, sized("S", value))
    elseif value_type == "table" then
        if seen[value] then error("wire value contains a cycle") end
        seen[value] = true
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        if count > Wire.MAX_ENTRIES then error("wire table has too many entries") end
        append(output, "T" .. tostring(count) .. ":")
        for key, child in pairs(value) do
            encode_value(key, output, seen, depth + 1)
            encode_value(child, output, seen, depth + 1)
        end
        seen[value] = nil
    else
        error("unsupported wire value type: " .. value_type)
    end
end

function Wire.encode(value)
    local output = { parts = {}, bytes = 0 }
    local ok, err = pcall(encode_value, value, output, {}, 1)
    if not ok then return nil, tostring(err) end
    return table.concat(output.parts), nil
end

local function length_at(input, index)
    local colon = input:find(":", index, true)
    if not colon then return nil, nil, "truncated wire length" end
    local digits = input:sub(index, colon - 1)
    if digits == "" or not digits:match("^%d+$") then return nil, nil, "invalid wire length" end
    local length = tonumber(digits)
    if not length or length > #input then return nil, nil, "wire length is outside bounds" end
    return length, colon + 1, nil
end

local function decode_value(input, index, depth)
    if depth > Wire.MAX_DEPTH then return nil, index, "wire value exceeds maximum depth" end
    local marker = input:sub(index, index)
    if marker == "" then return nil, index, "truncated wire value" end
    if marker == "N" then return nil, index + 1, nil end
    if marker == "B" then
        local digit = input:sub(index + 1, index + 1)
        if digit ~= "0" and digit ~= "1" then return nil, index, "invalid wire boolean" end
        return digit == "1", index + 2, nil
    end
    if marker == "S" or marker == "D" then
        local length, start, length_error = length_at(input, index + 1)
        if length_error then return nil, index, length_error end
        local finish = start + length - 1
        if finish > #input then return nil, index, "truncated wire data" end
        local raw = input:sub(start, finish)
        if marker == "D" then
            local number = tonumber(raw)
            if not number then return nil, index, "invalid wire number" end
            return number, finish + 1, nil
        end
        return raw, finish + 1, nil
    end
    if marker == "T" then
        local count, cursor, count_error = length_at(input, index + 1)
        if count_error then return nil, index, count_error end
        if count > Wire.MAX_ENTRIES then return nil, index, "wire table has too many entries" end
        local result = {}
        for _ = 1, count do
            local key, next_cursor, key_error = decode_value(input, cursor, depth + 1)
            if key_error then return nil, index, key_error end
            if key == nil then return nil, index, "wire table key is nil" end
            local child, after_child, child_error = decode_value(input, next_cursor, depth + 1)
            if child_error then return nil, index, child_error end
            result[key] = child
            cursor = after_child
        end
        return result, cursor, nil
    end
    return nil, index, "unknown wire marker"
end

function Wire.decode(input)
    if type(input) ~= "string" then return nil, "wire payload must be a string" end
    if #input > Wire.MAX_BYTES then return nil, "wire payload exceeds byte limit" end
    local value, cursor, err = decode_value(input, 1, 1)
    if err then return nil, err end
    if cursor ~= #input + 1 then return nil, "trailing wire data" end
    return value, nil
end

return Wire
