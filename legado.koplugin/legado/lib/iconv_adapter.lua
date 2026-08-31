local IconvAdapter = {}
IconvAdapter.__index = IconvAdapter

local CDEF = [[
unsigned long miniconv_open2(const char *toenc, const char *fromenc, int *error);
unsigned long miniconv2(unsigned long cd, const char **inbuf, unsigned long *inbytesleft,
    char **outbuf, unsigned long *outbytesleft, int *error);
int miniconv_close(unsigned long cd);
void *iconv_open(const char *tocode, const char *fromcode);
unsigned long iconv(void *cd, const char **inbuf, unsigned long *inbytesleft,
    char **outbuf, unsigned long *outbytesleft);
int iconv_close(void *cd);
]]

local function optional_require(name)
    local ok, value = pcall(require, name)
    if ok then return value end
    return nil
end

local function symbols(library, prefix)
    if not library then return nil end
    local names = prefix == "mini"
        and { "miniconv_open2", "miniconv2", "miniconv_close" }
        or { "iconv_open", "iconv", "iconv_close" }
    local found = {}
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return library[name] end)
        if not ok or value == nil then return nil end
        found[#found + 1] = value
    end
    return { open = found[1], convert = found[2], close = found[3], mini = prefix == "mini" }
end

local function load_runtime(ffi)
    if not ffi then return nil end
    if type(ffi.cdef) == "function" then pcall(ffi.cdef, CDEF) end
    pcall(require, "ffi/loadlib")
    local candidates = {}
    if type(ffi.loadlib) == "function" then
        local ok, library = pcall(ffi.loadlib, "iconv")
        if ok then candidates[#candidates + 1] = library end
    end
    if ffi.C then candidates[#candidates + 1] = ffi.C end
    if type(ffi.load) == "function" then
        for _, path in ipairs({ "libs/libiconv.so", "libs/libkoreader-monolibtic.so" }) do
            local ok, library = pcall(ffi.load, path)
            if ok then candidates[#candidates + 1] = library end
        end
    end
    for _, library in ipairs(candidates) do
        -- Prefer full GNU/POSIX iconv: KOReader's pinned miniconv 1.03 has
        -- compatible symbols but does not implement GBK or GB18030.
        local found = symbols(library, "gnu") or symbols(library, "mini")
        if found then return found end
    end
    return nil
end

local function invalid_descriptor(ffi, descriptor, mini)
    if descriptor == nil then return true end
    if type(ffi.cast) ~= "function" then return false end
    local ok, invalid = pcall(ffi.cast, mini and "unsigned long" or "void *", -1)
    if not ok then return false end
    local compared, equal = pcall(function() return descriptor == invalid end)
    return compared and equal or false
end

function IconvAdapter.new(options)
    options = options or {}
    local ffi = options.ffi
    if ffi == nil then ffi = optional_require("ffi") end
    if ffi == false then ffi = nil end
    local native
    if options.library and ffi then
        if type(ffi.cdef) == "function" then pcall(ffi.cdef, CDEF) end
        native = symbols(options.library, "mini") or symbols(options.library, "gnu")
    elseif options.library ~= false then
        native = load_runtime(ffi)
    end
    return setmetatable({ ffi = ffi, native = native }, IconvAdapter)
end

function IconvAdapter:available()
    return self.ffi ~= nil and self.native ~= nil
end

function IconvAdapter:convert(input, from, to)
    if not self:available() then return nil, "native iconv capability is unavailable" end
    if type(input) ~= "string" then return nil, "iconv input must be a string" end
    local ffi, native = self.ffi, self.native
    from, to = tostring(from):upper(), tostring(to):upper()
    local error_out = ffi.new("int[1]", 0)
    local descriptor
    if native.mini then descriptor = native.open(to, from, error_out)
    else descriptor = native.open(to, from) end
    if invalid_descriptor(ffi, descriptor, native.mini) or error_out[0] ~= 0 then
        return nil, "iconv_open failed"
    end

    local capacity = math.max(32, #input * 4 + 16)
    local output = ffi.new("char[?]", capacity)
    local input_pointer = ffi.new("const char *[1]", input)
    local input_left = ffi.new("unsigned long[1]", #input)
    local output_pointer = ffi.new("char *[1]", output)
    local output_left = ffi.new("unsigned long[1]", capacity)
    local result
    if native.mini then
        result = native.convert(descriptor, input_pointer, input_left, output_pointer, output_left, error_out)
    else
        result = native.convert(descriptor, input_pointer, input_left, output_pointer, output_left)
    end
    native.close(descriptor)
    local numeric = tonumber(result)
    local failed_result = numeric == -1
    if type(ffi.cast) == "function" then
        local ok, invalid = pcall(ffi.cast, "unsigned long", -1)
        if ok then
            local compared, equal = pcall(function() return result == invalid end)
            failed_result = failed_result or (compared and equal)
        end
    end
    if error_out[0] ~= 0 or failed_result or input_left[0] ~= 0 then
        return nil, "iconv conversion failed"
    end
    return ffi.string(output, capacity - tonumber(output_left[0])), nil
end

return IconvAdapter
