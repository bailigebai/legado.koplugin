local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, ror, tobit = bit.lshift, bit.rshift, bit.rol, bit.ror, bit.tobit

local Safe = {}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function utf8_character(codepoint)
    if type(codepoint) ~= "number" or codepoint < 0 or codepoint > 0x10ffff
        or (codepoint >= 0xd800 and codepoint <= 0xdfff) then return nil end
    if codepoint <= 0x7f then return string.char(codepoint) end
    if codepoint <= 0x7ff then
        return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    end
    if codepoint <= 0xffff then
        return string.char(0xe0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xf0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

local function url_encode(value)
    return (tostring(value or ""):gsub("([^A-Za-z0-9%-._~])", function(character)
        return string.format("%%%02X", string.byte(character))
    end))
end

local function url_decode(value)
    return (tostring(value or ""):gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local html_entities = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
}

local function html_decode(value)
    return (tostring(value or ""):gsub("&(#?x?[%w]+);", function(entity)
        if entity:sub(1, 2):lower() == "#x" then
            local number = tonumber(entity:sub(3), 16)
            local decoded = number and utf8_character(number)
            return decoded or "&" .. entity .. ";"
        elseif entity:sub(1, 1) == "#" then
            local number = tonumber(entity:sub(2), 10)
            local decoded = number and utf8_character(number)
            return decoded or "&" .. entity .. ";"
        end
        return html_entities[entity] or "&" .. entity .. ";"
    end))
end

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64_encode(value)
    local input, output = tostring(value or ""), {}
    for index = 1, #input, 3 do
        local a, b, c = input:byte(index, index + 2)
        local triple = a * 65536 + (b or 0) * 256 + (c or 0)
        output[#output + 1] = alphabet:sub(math.floor(triple / 262144) % 64 + 1, math.floor(triple / 262144) % 64 + 1)
        output[#output + 1] = alphabet:sub(math.floor(triple / 4096) % 64 + 1, math.floor(triple / 4096) % 64 + 1)
        output[#output + 1] = b and alphabet:sub(math.floor(triple / 64) % 64 + 1, math.floor(triple / 64) % 64 + 1) or "="
        output[#output + 1] = c and alphabet:sub(triple % 64 + 1, triple % 64 + 1) or "="
    end
    return table.concat(output)
end

local decode64 = {}
for index = 1, #alphabet do decode64[alphabet:sub(index, index)] = index - 1 end
local function base64_decode(value)
    local input = tostring(value or ""):gsub("%s+", "")
    if #input % 4 ~= 0 or input:find("[^A-Za-z0-9+/=]") then error("invalid Base64") end
    local data, padding = input:match("^(.-)(=*)$")
    if #padding > 2 or data:find("=", 1, true) then error("invalid Base64 padding") end
    if #padding == 2 and band(decode64[data:sub(-1)] or -1, 0x0f) ~= 0 then error("non-canonical Base64 padding") end
    if #padding == 1 and band(decode64[data:sub(-1)] or -1, 0x03) ~= 0 then error("non-canonical Base64 padding") end
    local output = {}
    for index = 1, #input, 4 do
        local chars = { input:sub(index, index), input:sub(index + 1, index + 1), input:sub(index + 2, index + 2), input:sub(index + 3, index + 3) }
        if not decode64[chars[1]] or not decode64[chars[2]] then error("invalid Base64") end
        local triple = decode64[chars[1]] * 262144 + decode64[chars[2]] * 4096
            + (decode64[chars[3]] or 0) * 64 + (decode64[chars[4]] or 0)
        output[#output + 1] = string.char(math.floor(triple / 65536) % 256)
        if chars[3] ~= "=" then output[#output + 1] = string.char(math.floor(triple / 256) % 256) end
        if chars[4] ~= "=" then output[#output + 1] = string.char(triple % 256) end
    end
    return table.concat(output)
end

local function le_word(text, index)
    local a, b, c, d = text:byte(index, index + 3)
    return tobit((a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216)
end

local function be_word(text, index)
    local a, b, c, d = text:byte(index, index + 3)
    return tobit((a or 0) * 16777216 + (b or 0) * 65536 + (c or 0) * 256 + (d or 0))
end

local function hex_le(word)
    local unsigned = word < 0 and word + 4294967296 or word
    local bytes = {}
    for _ = 1, 4 do
        bytes[#bytes + 1] = string.format("%02x", unsigned % 256)
        unsigned = math.floor(unsigned / 256)
    end
    return table.concat(bytes)
end

local function hex_be(word)
    return bit.tohex(word, 8)
end

local md5_shifts = { 7,12,17,22, 5,9,14,20, 4,11,16,23, 6,10,15,21 }
local md5_constants = {}
for index = 1, 64 do md5_constants[index] = tobit(math.floor(math.abs(math.sin(index)) * 4294967296)) end

local function md5(value)
    local input = tostring(value or "")
    local bit_length = #input * 8
    input = input .. string.char(0x80)
    while #input % 64 ~= 56 do input = input .. "\0" end
    local low = bit_length % 4294967296
    local high = math.floor(bit_length / 4294967296)
    for _ = 1, 4 do input = input .. string.char(low % 256); low = math.floor(low / 256) end
    for _ = 1, 4 do input = input .. string.char(high % 256); high = math.floor(high / 256) end

    local a0, b0, c0, d0 = tobit(0x67452301), tobit(0xefcdab89), tobit(0x98badcfe), tobit(0x10325476)
    for offset = 1, #input, 64 do
        local words = {}
        for index = 0, 15 do words[index] = le_word(input, offset + index * 4) end
        local a, b, c, d = a0, b0, c0, d0
        for index = 0, 63 do
            local f, g, round
            if index < 16 then f, g, round = bor(band(b, c), band(bnot(b), d)), index, 1
            elseif index < 32 then f, g, round = bor(band(d, b), band(bnot(d), c)), (5 * index + 1) % 16, 2
            elseif index < 48 then f, g, round = bxor(b, c, d), (3 * index + 5) % 16, 3
            else f, g, round = bxor(c, bor(b, bnot(d))), (7 * index) % 16, 4 end
            local next_d = d
            d, c = c, b
            b = tobit(b + rol(tobit(a + f + md5_constants[index + 1] + words[g]), md5_shifts[(index % 4) + 1 + (round - 1) * 4]))
            a = next_d
        end
        a0, b0, c0, d0 = tobit(a0 + a), tobit(b0 + b), tobit(c0 + c), tobit(d0 + d)
    end
    return hex_le(a0) .. hex_le(b0) .. hex_le(c0) .. hex_le(d0)
end

local function sha_padding(input)
    local bit_length = #input * 8
    input = input .. string.char(0x80)
    while #input % 64 ~= 56 do input = input .. "\0" end
    local high, low = math.floor(bit_length / 4294967296), bit_length % 4294967296
    for shift = 24, 0, -8 do input = input .. string.char(math.floor(high / 2^shift) % 256) end
    for shift = 24, 0, -8 do input = input .. string.char(math.floor(low / 2^shift) % 256) end
    return input
end

local function sha1(value)
    local input = sha_padding(tostring(value or ""))
    local h0, h1, h2, h3, h4 = tobit(0x67452301), tobit(0xefcdab89), tobit(0x98badcfe), tobit(0x10325476), tobit(0xc3d2e1f0)
    for offset = 1, #input, 64 do
        local words = {}
        for index = 0, 15 do words[index] = be_word(input, offset + index * 4) end
        for index = 16, 79 do words[index] = rol(bxor(words[index - 3], words[index - 8], words[index - 14], words[index - 16]), 1) end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for index = 0, 79 do
            local f, k
            if index < 20 then f, k = bor(band(b, c), band(bnot(b), d)), tobit(0x5a827999)
            elseif index < 40 then f, k = bxor(b, c, d), tobit(0x6ed9eba1)
            elseif index < 60 then f, k = bor(band(b, c), band(b, d), band(c, d)), tobit(0x8f1bbcdc)
            else f, k = bxor(b, c, d), tobit(0xca62c1d6) end
            local temp = tobit(rol(a, 5) + f + e + k + words[index])
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end
        h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
    end
    return hex_be(h0) .. hex_be(h1) .. hex_be(h2) .. hex_be(h3) .. hex_be(h4)
end

local sha256_constants = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}
for index, value in ipairs(sha256_constants) do sha256_constants[index] = tobit(value) end

local function sha256(value)
    local input = sha_padding(tostring(value or ""))
    local hash = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
    for index, value2 in ipairs(hash) do hash[index] = tobit(value2) end
    for offset = 1, #input, 64 do
        local words = {}
        for index = 0, 15 do words[index] = be_word(input, offset + index * 4) end
        for index = 16, 63 do
            local x, y = words[index - 15], words[index - 2]
            local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
            local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
            words[index] = tobit(words[index - 16] + s0 + words[index - 7] + s1)
        end
        local a,b,c,d,e,f,g,h = unpack(hash)
        for index = 0, 63 do
            local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local choice = bxor(band(e, f), band(bnot(e), g))
            local temp1 = tobit(h + s1 + choice + sha256_constants[index + 1] + words[index])
            local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local majority = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = tobit(s0 + majority)
            h,g,f,e,d,c,b,a = g,f,e,tobit(d + temp1),c,b,a,tobit(temp1 + temp2)
        end
        local values = { a,b,c,d,e,f,g,h }
        for index = 1, 8 do hash[index] = tobit(hash[index] + values[index]) end
    end
    local output = {}
    for index = 1, 8 do output[index] = hex_be(hash[index]) end
    return table.concat(output)
end

local function normalize_path(path)
    local parts = {}
    local trailing = path:sub(-1) == "/" or path:match("/%.%.?$") ~= nil
    for part in path:gmatch("[^/]+") do
        if part == ".." then if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." and part ~= "" then parts[#parts + 1] = part end
    end
    local normalized = "/" .. table.concat(parts, "/")
    if trailing and normalized ~= "/" then normalized = normalized .. "/" end
    return normalized
end

local function resolve_url(base, relative)
    base, relative = tostring(base or ""), tostring(relative or "")
    if relative:match("^[%a][%w+.-]*:") then return relative end
    local scheme, authority, remainder = base:match("^([%a][%w+.-]*):%/%/([^/?#]+)(.*)$")
    if not scheme then return relative end
    if relative:sub(1, 2) == "//" then return scheme .. ":" .. relative end
    local origin = scheme .. "://" .. authority
    local base_path = remainder:match("^([^?#]*)") or ""
    if base_path == "" then base_path = "/" end
    local base_query = remainder:match("(%?[^#]*)") or ""
    if relative == "" then return origin .. base_path .. base_query end
    if relative:sub(1, 1) == "#" then return origin .. base_path .. base_query .. relative end
    if relative:sub(1, 1) == "?" then return origin .. base_path .. relative end

    local suffix = relative:match("([?#].*)$") or ""
    local clean = relative:gsub("[?#].*$", "")
    local target
    if clean:sub(1, 1) == "/" then target = clean
    else
        local directory = base_path:sub(-1) == "/" and base_path or base_path:gsub("[^/]*$", "")
        target = directory .. clean
    end
    return origin .. normalize_path(target) .. suffix
end

Safe.resolve_url = resolve_url
Safe.functions = {
    urlencode = url_encode,
    urldecode = url_decode,
    htmldecode = html_decode,
    base64encode = base64_encode,
    base64decode = base64_decode,
    md5 = md5,
    sha = sha1,
    sha1 = sha1,
    sha256 = sha256,
    trim = trim,
    lower = function(value) return tostring(value or ""):lower() end,
    upper = function(value) return tostring(value or ""):upper() end,
    replace = function(value, pattern, replacement)
        local ok, result = pcall(string.gsub, tostring(value or ""), tostring(pattern or ""), tostring(replacement or ""))
        if not ok then error("invalid Lua replacement pattern") end
        return result
    end,
    resolveurl = resolve_url,
}

return Safe
