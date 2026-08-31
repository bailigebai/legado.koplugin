local CookieJar = {}
CookieJar.__index = CookieJar

local months = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_url(url)
    local scheme, authority, path = tostring(url or ""):match("^([%a][%w+.-]*)://([^/?#]+)([^?#]*)")
    if not scheme then return nil end
    local host = authority:match("^%[([^%]]+)%]") or authority:match("^([^:]+)")
    path = path ~= "" and path or "/"
    return { scheme = scheme:lower(), host = tostring(host):lower(), path = path }
end

local function domain_matches(host, domain)
    return host == domain or (#host > #domain and host:sub(-#domain - 1) == "." .. domain)
end

local function path_matches(path, cookie_path)
    if path == cookie_path then return true end
    if path:sub(1, #cookie_path) ~= cookie_path then return false end
    return cookie_path:sub(-1) == "/" or path:sub(#cookie_path + 1, #cookie_path + 1) == "/"
end

local function default_path(path)
    if path:sub(1, 1) ~= "/" or path == "/" then return "/" end
    local directory = path:match("^(.*)/")
    return directory == "" and "/" or directory
end

local function parse_expires(value)
    local day, month, year, hour, minute, second = value:match(
        "%a+,%s*(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT")
    if not day then return nil end
    month = months[month:lower()]
    if not month then return nil end
    local local_time = os.time({
        year = tonumber(year), month = month, day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second), isdst = false,
    })
    if not local_time then return nil end
    local local_epoch = os.time(os.date("*t", 86400))
    local utc_epoch = os.time(os.date("!*t", 86400))
    return local_time + os.difftime(local_epoch, utc_epoch)
end

function CookieJar.new(options)
    options = options or {}
    return setmetatable({
        jars = {},
        now = options.now or os.time,
        sequence = 0,
    }, CookieJar)
end

function CookieJar:_jar(source_id)
    source_id = tostring(source_id or "")
    local jar = self.jars[source_id]
    if not jar then jar = {}; self.jars[source_id] = jar end
    return jar
end

function CookieJar:store(source_id, url, set_cookie)
    local target = parse_url(url)
    if not target then return false end
    local values = type(set_cookie) == "table" and set_cookie or { set_cookie }
    local jar = self:_jar(source_id)
    for _, line in ipairs(values) do
        local parts = {}
        for part in tostring(line or ""):gmatch("[^;]+") do parts[#parts + 1] = trim(part) end
        local name, value = (parts[1] or ""):match("^([^=]+)=(.*)$")
        name = trim(name)
        if name ~= "" and not name:find("[%c%s;,]") then
            local attributes = {}
            for index = 2, #parts do
                local attribute, attribute_value = parts[index]:match("^([^=]+)=?(.*)$")
                attributes[trim(attribute):lower()] = trim(attribute_value)
            end
            local domain = (attributes.domain ~= "" and attributes.domain or target.host):lower():gsub("^%.", "")
            if domain_matches(target.host, domain) then
                local path = attributes.path ~= "" and attributes.path or default_path(target.path)
                if path:sub(1, 1) ~= "/" then path = default_path(target.path) end
                local expires
                if attributes["max-age"] ~= nil and attributes["max-age"] ~= "" then
                    local seconds = tonumber(attributes["max-age"])
                    if seconds then expires = self.now() + seconds end
                elseif attributes.expires and attributes.expires ~= "" then
                    expires = parse_expires(attributes.expires)
                end
                local key = domain .. "\0" .. path .. "\0" .. name
                if (expires and expires <= self.now()) or value == "" then
                    jar[key] = nil
                else
                    self.sequence = self.sequence + 1
                    jar[key] = {
                        name = name, value = value, domain = domain, path = path,
                        host_only = attributes.domain == nil or attributes.domain == "",
                        secure = attributes.secure ~= nil,
                        expires = expires,
                        sequence = self.sequence,
                    }
                end
            end
        end
    end
    return true
end

function CookieJar:header(source_id, url)
    local target = parse_url(url)
    if not target then return nil end
    local jar = self.jars[tostring(source_id or "")]
    if not jar then return nil end
    local matches = {}
    for key, cookie in pairs(jar) do
        if cookie.expires and cookie.expires <= self.now() then
            jar[key] = nil
        elseif (not cookie.secure or target.scheme == "https")
            and (cookie.host_only and target.host == cookie.domain or not cookie.host_only and domain_matches(target.host, cookie.domain))
            and path_matches(target.path, cookie.path) then
            matches[#matches + 1] = cookie
        end
    end
    table.sort(matches, function(left, right)
        if #left.path ~= #right.path then return #left.path > #right.path end
        return left.sequence < right.sequence
    end)
    if #matches == 0 then return nil end
    local output = {}
    for _, cookie in ipairs(matches) do output[#output + 1] = cookie.name .. "=" .. cookie.value end
    return table.concat(output, "; ")
end

return CookieJar
