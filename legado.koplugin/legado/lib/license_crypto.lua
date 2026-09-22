local Crypto = {}
local directory=debug.getinfo(1,"S").source:sub(2):match("^(.*[/\\])") or ""
local function read_file(path,limit)
    local f=io.open(path,"rb")
    if not f then return nil end
    local data=f:read(limit+1);f:close()
    if type(data)~="string" or #data>limit then return nil end
    return data
end
function Crypto.sha256(value)
    local ok,result=pcall(function()return require("ffi/sha2").sha256(value)end)
    if ok and type(result)=="string" and #result==64 and not result:find("[^0-9a-f]") then return result end
    return nil,"crypto_unavailable"
end
function Crypto.hardwareId(read)
    read=read or read_file
    for _,path in ipairs({"/proc/usid","/sys/devices/soc0/serial_number"}) do
        local ok,serial=pcall(read,path,128)
        if ok and type(serial)=="string" then
            serial=serial:match("^%s*([A-Za-z0-9]+)%s*$")
            if serial and #serial>=8 and #serial<=64 and serial:find("[^0]") then
                return Crypto.sha256("legado-kindle-1\n"..serial:upper())
            end
        end
    end
    return nil,"no_hardware_id"
end
function Crypto.randomId(read)
    -- /dev/urandom is an infinite stream: read exactly 32 bytes, never limit+1.
    local raw
    if read then raw=read("/dev/urandom",32)
    else
        local f=io.open("/dev/urandom","rb")
        if f then raw=f:read(32);f:close() end
    end
    if type(raw)~="string" or #raw~=32 then return nil,"entropy_unavailable" end
    return Crypto.sha256("legado-installation-1\n"..raw)
end
function Crypto.validSignature(s)
    return type(s)=="string" and #s==344 and s:sub(-2)=="=="
        and not s:sub(1,342):find("[^A-Za-z0-9+/]") and s:sub(342,342):match("[AQgw]")~=nil
end

local ffi,lib
local function backend()
    if lib then return true end
    local ok=pcall(function()
        ffi=require("ffi")
        ffi.cdef[[
            typedef struct bio_st SK_BIO;
            typedef struct evp_pkey_st SK_PKEY;
            typedef struct evp_md_st SK_MD;
            typedef struct evp_md_ctx_st SK_MD_CTX;
            typedef struct evp_pkey_ctx_st SK_PKEY_CTX;
            typedef struct rsa_st SK_RSA;
            SK_BIO *BIO_new_mem_buf(const void *, int);
            int BIO_free(SK_BIO *);
            SK_PKEY *PEM_read_bio_PUBKEY(SK_BIO *, SK_PKEY **, void *, void *);
            void EVP_PKEY_free(SK_PKEY *);
            SK_RSA *EVP_PKEY_get1_RSA(SK_PKEY *);
            int RSA_size(const SK_RSA *);
            void RSA_free(SK_RSA *);
            SK_MD_CTX *EVP_MD_CTX_new(void);
            void EVP_MD_CTX_free(SK_MD_CTX *);
            const SK_MD *EVP_sha256(void);
            int EVP_DigestVerifyInit(SK_MD_CTX *, SK_PKEY_CTX **, const SK_MD *, void *, SK_PKEY *);
            int EVP_PKEY_CTX_ctrl_str(SK_PKEY_CTX *, const char *, const char *);
            int EVP_DigestUpdate(SK_MD_CTX *, const void *, size_t);
            int EVP_DigestVerifyFinal(SK_MD_CTX *, const unsigned char *, size_t);
            int EVP_DecodeBlock(unsigned char *, const unsigned char *, int);
        ]]
        lib=ffi.loadlib("crypto","57")
    end)
    return ok and lib~=nil
end
function Crypto.verify(message,signature,pem)
    if type(message)~="string" or #message>256 or not Crypto.validSignature(signature) then return false end
    if not backend() then return nil,"crypto_unavailable" end
    pem=pem or read_file(directory.."license-public.pem",8192)
    if type(pem)~="string" or #pem>8192 then return nil,"public_key_unavailable" end
    local bio,pkey,rsa,ctx
    local success,valid=pcall(function()
        bio=lib.BIO_new_mem_buf(pem,#pem);if bio==nil then return false end
        pkey=lib.PEM_read_bio_PUBKEY(bio,nil,nil,nil);if pkey==nil then return false end
        rsa=lib.EVP_PKEY_get1_RSA(pkey)
        if rsa==nil or lib.RSA_size(rsa)~=256 then return false end
        local decoded=ffi.new("unsigned char[258]")
        if lib.EVP_DecodeBlock(decoded,signature,#signature)~=258 then return false end
        ctx=lib.EVP_MD_CTX_new();if ctx==nil then return false end
        local keyctx=ffi.new("SK_PKEY_CTX *[1]")
        -- LibreSSL's VerifyUpdate and set_rsa_padding names are C macros,
        -- not FFI exports. Use their public function equivalents.
        return lib.EVP_DigestVerifyInit(ctx,keyctx,lib.EVP_sha256(),nil,pkey)==1
            and lib.EVP_PKEY_CTX_ctrl_str(keyctx[0],"rsa_padding_mode","pkcs1")==1
            and lib.EVP_DigestUpdate(ctx,message,#message)==1
            and lib.EVP_DigestVerifyFinal(ctx,decoded,256)==1
    end)
    if ctx~=nil then lib.EVP_MD_CTX_free(ctx) end
    if rsa~=nil then lib.RSA_free(rsa) end
    if pkey~=nil then lib.EVP_PKEY_free(pkey) end
    if bio~=nil then lib.BIO_free(bio) end
    return success and valid==true
end
return Crypto
