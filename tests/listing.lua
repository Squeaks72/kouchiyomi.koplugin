local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
for _, m in ipairs({ "socket.http", "ssl.https", "ltn12", "socket.url", "logger", "json" }) do package.loaded[m] = package.loaded[m] or {} end
package.loaded["socket.url"].escape = function(s) return s end
local API = require("uchi/api")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local off, on = API:new("http://x", {}), API:new("http://x", { reveal_all = true })
check("off: path untouched", off:listing("/api/home") == "/api/home")
check("on: adds adult=1", on:listing("/api/home") == "/api/home?adult=1")
check("on: appends to a query", on:listing("/api/history?limit=50") == "/api/history?limit=50&adult=1")
check("on: never doubles it", on:listing(on:withAdult("/api/series/search")) == "/api/series/search?adult=1")
local seen
on.request = function(_, path) seen = path; return {} end
on:search_series("x", 0, 10)
check("search asks for 18+", seen == "/api/series/search?adult=1", seen)
off.request = function(_, path) seen = path; return {} end
off:search_series("x", 0, 10)
check("search without it does not", seen == "/api/series/search", seen)
off:get_favorites(); check("favourites stay hidden when off", seen == "/api/favorites", seen)
on:get_favorites(); check("favourites revealed when on", seen == "/api/favorites?adult=1", seen)
on.show_adult = true; on:search_series(nil, 0, 10, nil, nil, true)
check("library reveal + setting: one adult=1", seen == "/api/series/search?adult=1", seen)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
