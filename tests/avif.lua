--[[
    Chapters with AVIF pages, which KOReader cannot decode. Plain Lua 5.1, stubs KOReader:
      lua5.1 tests/avif.lua     (from the plugin folder)
--]]
package.path = "./?.lua;" .. package.path
for _i, name in ipairs{ "socket.http", "ssl.https", "ltn12", "socket.url", "logger", "json", "uchi/spreads", "uchi/zip" } do
    package.preload[name] = function()
        return { escape = function(s) return s end, source = {}, sink = {},
                 dbg = function() end, info = function() end, warn = function() end, err = function() end,
                 joins = function() return {}, 0 end }
    end
end
local API = require("uchi/api")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local AVIF = "\0\0\0\28ftypavif-rest"
local WEBP = "RIFF\0\0\0\0WEBP-rest"
local JPEG = "\255\216\255-rest"

--- An API whose server holds `pages` (file names), serving each by name, with what was asked for recorded.
local function server(names, opds, joined_off)
    local zip = { files = {} }
    package.loaded["uchi/zip"] = { open = function() return {
        add = function(_z, name, bytes) table.insert(zip.files, { name = name, bytes = bytes }) end,
        close = function() return true end, abort = function() end,
    } end }
    local api = API:new("http://stub", { api_token = "uy_stub", username = opds and "u" or nil, opds_token = opds and "t" or nil,
                                         settings = { join_split_spreads = not joined_off } })
    api.asked, api.opds_used = {}, false
    function api:get_book_pages()
        local list = {}
        for i, name in ipairs(names) do list[i] = { number = i, fileName = name } end
        return list
    end
    function api:request_raw(path)
        table.insert(self.asked, path)
        local n = tonumber(path:match("/pages/(%d+)$"))
        if n then return names[n]:match("avif$") and AVIF or JPEG end
        if path:match("/img/lib/books/.+/page/%d+%?w=2000$") then return WEBP end
        return nil, "unexpected " .. path
    end
    function api:download_book_opds() self.opds_used = true; return true end
    return api, zip
end

-- A page that is AVIF comes back from the route that re-encodes it, and the others are left alone.
local api = server{ "1.avif", "2.jpg" }
check("an AVIF page is re-encoded", api:download_page("b", 1) == WEBP)
check("asked for by its number", api.asked[2] == "/img/lib/books/b/page/1?w=2000", api.asked[2])
api.asked = {}
check("any other page is what the server holds", api:download_page("b", 2) == JPEG)
check("in one request", #api.asked == 1, #api.asked)

-- A failed fetch still says why.
function api:request_raw() return nil, "timeout", 504 end
local bytes, err, code = api:download_page("b", 1)
check("a failed fetch is passed on", bytes == nil and err == "timeout" and code == 504)

-- Downloading: the server's file is skipped, the pages are named for what they now are.
local zip
api, zip = server({ "0001.avif", "0002.jpg" }, true)
check("the download succeeds", api:download_book("b", "/tmp/x") == true)
check("the file with AVIF in it is not fetched", api.opds_used == false)
check("the AVIF page is named as what it became", zip.files[1].name == "0001.webp", zip.files[1].name)
check("and holds that", zip.files[1].bytes == WEBP)
check("a page that was fine keeps its type", zip.files[2].name == "0002.jpg", zip.files[2].name)

-- Spread joining off, so nothing else asks for the list: it still has to be seen.
api, zip = server({ "0001.avif" }, true, true)
api:download_book("b", "/tmp/x")
check("noticed with spread joining off", api.opds_used == false and zip.files[1].name == "0001.webp")

-- An ordinary chapter still takes the quick whole-file route.
api = server({ "0001.png", "0002.png" }, true)
check("an ordinary chapter is a whole file", api:download_book("b", "/tmp/x") == true and api.opds_used == true)

-- The sweep: what it finds, and that it runs once. Sync needs KOReader, so it is stubbed around.
local dummy = setmetatable({}, { __index = function() return function() end end, __call = function() return {} end })
table.insert(package.loaders, 2, function(name)
    if name == "uchi/sync" or name == "uchi/labels" then return nil end
    if package.preload[name] or package.loaded[name] then return nil end
    return function() return dummy end
end)
local Sync = require("uchi/sync")
local function cbz(path, names)
    local f = assert(io.open(path, "wb"))
    f:write(string.rep("x", 70000), table.concat(names, "PK"))
    f:close()
end
local dir = os.tmpname(); os.remove(dir)
local bad, good = dir .. "-bad.cbz", dir .. "-good.cbz"
cbz(bad, { "0001.AVIF", "0002.avif" })
cbz(good, { "0001.png", "avif-is-only-in-this-name.png" })
check("names AVIF pages, in either case", Sync.holdsAvifPages(bad) == true)
check("not fooled by a name", Sync.holdsAvifPages(good) == false)
check("a missing file holds nothing", Sync.holdsAvifPages(dir .. "-none.cbz") == false)

local deleted, saved = {}, 0
local s = setmetatable({ plugin = { settings = {}, saveSettings = function() saved = saved + 1 end } }, { __index = Sync })
s.getDownloadedBookInfos = function() return { { path = bad }, { path = good } } end
s.deleteDownloadedFile = function(_s, path) table.insert(deleted, path) end
s:sweepAvifDownloads()
check("the sweep removes only the unreadable one", #deleted == 1 and deleted[1] == bad, #deleted)
check("and remembers", s.plugin.settings.avif_sweep_done == true and saved == 1)
s:sweepAvifDownloads()
check("once", #deleted == 1, #deleted)
os.remove(bad); os.remove(good)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
