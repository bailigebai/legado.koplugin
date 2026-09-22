local Errors = require("legado.lib.errors")
local Compression = {}

function Compression.decode(body, encoding, limit)
    encoding = tostring(encoding or "identity"):lower():match("^%s*(.-)%s*$")
    if encoding == "" or encoding == "identity" then return body end
    if encoding ~= "gzip" and encoding ~= "x-gzip" and encoding ~= "deflate" then
        return nil, Errors.new(Errors.ENCODING_ERROR, "unsupported HTTP content encoding")
    end
    local ok, ffi = pcall(require, "ffi")
    if not ok or type(ffi.loadlib) ~= "function" then
        return nil, Errors.new(Errors.ENCODING_ERROR, "native HTTP decompressor unavailable")
    end
    -- KOReader already ships zlib. Bound its output buffer before inflating untrusted bytes.
    if not pcall(ffi.typeof, "legado_z_stream") then
        ffi.cdef[[
            typedef struct {
                const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
                unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
                char *msg; void *state;
                void *(*zalloc)(void *, unsigned int, unsigned int);
                void (*zfree)(void *, void *); void *opaque;
                int data_type; unsigned long adler; unsigned long reserved;
            } legado_z_stream;
            const char *zlibVersion(void);
            int inflateInit2_(legado_z_stream *, int, const char *, int);
            int inflate(legado_z_stream *, int);
            int inflateEnd(legado_z_stream *);
        ]]
    end
    local loaded, lib = pcall(ffi.loadlib, "z", 1)
    if not loaded then return nil, Errors.new(Errors.ENCODING_ERROR, "native HTTP decompressor unavailable") end
    local stream = ffi.new("legado_z_stream[1]")
    local output = ffi.new("unsigned char[?]", limit + 1)
    stream[0].next_in, stream[0].avail_in = body, #body
    stream[0].next_out, stream[0].avail_out = output, limit + 1
    local status = lib.inflateInit2_(stream, encoding == "deflate" and 15 or 31, lib.zlibVersion(), ffi.sizeof(stream[0]))
    if status ~= 0 then return nil, Errors.new(Errors.ENCODING_ERROR, "HTTP decompressor initialization failed") end
    status = lib.inflate(stream, 4) -- Z_FINISH validates stream end and checksum.
    local size, remaining = tonumber(stream[0].total_out), tonumber(stream[0].avail_in)
    lib.inflateEnd(stream)
    if size > limit then return nil, Errors.new(Errors.RESPONSE_TOO_LARGE, "decompressed response exceeds byte limit") end
    if status ~= 1 or remaining ~= 0 then return nil, Errors.new(Errors.ENCODING_ERROR, "invalid compressed HTTP response") end
    return ffi.string(output, size)
end

return Compression
