local XmlText = {}

local REPLACEMENT = "\239\191\189"

local function xml_codepoint(codepoint)
    return codepoint == 0x9 or codepoint == 0xA or codepoint == 0xD
        or (codepoint >= 0x20 and codepoint <= 0xD7FF)
        or (codepoint >= 0xE000 and codepoint <= 0xFFFD)
        or (codepoint >= 0x10000 and codepoint <= 0x10FFFF)
end

function XmlText.sanitize(value)
    value = tostring(value or "")
    local output, index = {}, 1
    while index <= #value do
        local first = value:byte(index)
        local length, codepoint, minimum
        if first < 0x80 then length, codepoint, minimum = 1, first, 0
        elseif first >= 0xC2 and first <= 0xDF then length, codepoint, minimum = 2, first - 0xC0, 0x80
        elseif first >= 0xE0 and first <= 0xEF then length, codepoint, minimum = 3, first - 0xE0, 0x800
        elseif first >= 0xF0 and first <= 0xF4 then length, codepoint, minimum = 4, first - 0xF0, 0x10000 end
        local valid = length ~= nil and index + length - 1 <= #value
        if valid then
            for offset = 1, length - 1 do
                local byte = value:byte(index + offset)
                if not byte or byte < 0x80 or byte > 0xBF then valid = false; break end
                codepoint = codepoint * 0x40 + byte - 0x80
            end
        end
        if valid and (codepoint < minimum or not xml_codepoint(codepoint)) then valid = false end
        if valid then
            output[#output + 1] = value:sub(index, index + length - 1)
            index = index + length
        else
            output[#output + 1] = REPLACEMENT
            index = index + 1
        end
    end
    return table.concat(output)
end

function XmlText.escape(value)
    return XmlText.sanitize(value):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&apos;")
end

return XmlText
