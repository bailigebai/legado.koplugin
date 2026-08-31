local assertx = require("assertions")
local CookieJar = require("legado.lib.cookie_jar")

local now = 1000
local jar = CookieJar.new({ now = function() return now end })

jar:store("source-a", "https://books.test/account/login", {
    "session=alpha; Path=/account; Secure; Max-Age=60",
    "site=one; Path=/",
})
assertx.equal(
    "session=alpha; site=one",
    jar:header("source-a", "https://books.test/account/shelf"),
    "matching secure path cookies are sent")
assertx.equal("site=one", jar:header("source-a", "http://books.test/account/shelf"), "secure cookie stays on HTTPS")
assertx.equal("site=one", jar:header("source-a", "https://books.test/public"), "cookie path is honored")
assertx.equal(nil, jar:header("source-b", "https://books.test/account/shelf"), "cookie jars never cross source IDs")

jar:store("source-a", "https://books.test/", "domainwide=yes; Domain=.books.test; Path=/")
assertx.equal(
    "domainwide=yes",
    jar:header("source-a", "https://cdn.books.test/image"),
    "valid domain cookies include subdomains")

jar:store("source-a", "https://books.test/", "poison=no; Domain=attacker.test; Path=/")
assertx.equal(nil, jar:header("source-a", "https://attacker.test/"), "unrelated cookie domains are rejected")

now = 1061
assertx.equal(
    "site=one; domainwide=yes",
    jar:header("source-a", "https://books.test/account/shelf"),
    "expired cookie is removed")

jar:store("source-a", "https://books.test/", "site=gone; Path=/; Max-Age=0")
assertx.equal("domainwide=yes", jar:header("source-a", "https://books.test/"), "Max-Age zero deletes a cookie")

local guarded = CookieJar.new({ now = function() return 1000 end })
guarded:store("source-a", "https://victim.test/login", "session=victim; Path=/")
assertx.equal(nil, guarded:header("source-a", "https://victim.test:pw@attacker.test/"),
    "deceptive authority userinfo cannot receive victim cookies")
assertx.equal(nil, guarded:header("source-a", "https://us%65r:p%40ss@victim.test/"),
    "percent-encoded userinfo is rejected fail-closed")
assertx.equal(nil, guarded:header("source-a", "https://victim.test%40attacker.test/"),
    "percent-encoded authority delimiter is rejected fail-closed")

guarded:store("source-v6", "https://[2001:db8::1]:8443/login", "v6=yes; Path=/")
assertx.equal("v6=yes", guarded:header("source-v6", "https://[2001:db8::1]:9443/books"),
    "IPv6 authority and port remain supported without userinfo")
guarded:store("source-port", "https://books.test:8443/login", "port=yes; Path=/")
assertx.equal("port=yes", guarded:header("source-port", "https://books.test:9443/books"),
    "host cookies remain port agnostic without userinfo")

return 13
