local A = require("assertions")
local Path = require("legado.lib.download_cache_path")
local count = 0
local function eq(expected, actual, message) count = count + 1; A.equal(expected, actual, message) end

eq("/mnt/us/koreader/legado/offline-cache", Path.resolve("", "/mnt/us/koreader/legado/offline-cache"),
    "empty selection retains the app-owned default directory")
eq("/mnt/us/my-cache", Path.resolve("/mnt/us/my-cache", "/default"),
    "an absolute device directory can be selected")
eq(nil, Path.resolve("relative/cache", "/default"), "relative path cannot redirect storage")
eq(nil, Path.resolve("/mnt/us/../private", "/default"), "parent traversal is rejected")
eq(nil, Path.resolve("/", "/default"), "filesystem root cannot become the cache root")
eq(nil, Path.resolve("/mnt/us/cache\nother", "/default"), "control characters are rejected")

return count
