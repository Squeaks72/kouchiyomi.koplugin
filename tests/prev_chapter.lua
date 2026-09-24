--[[
    Unit test for uchi/api.lua's get_previous_book, against a stubbed series.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/prev_chapter.lua        (from the plugin folder)

    What it is guarding: the plugin works out the previous chapter itself,
    because Uchiyomi routes /next but not /previous. The order it relies on is
    the server's own (chapter number ascending, then file name), and the parts
    that can go quietly wrong are the page search on a long series and the
    chapters that are in the list but not somewhere to go back to.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

-- KOReader/luasocket modules api.lua pulls in at load time.
package.preload["socket.http"] = function() return {} end
package.preload["ssl.https"] = function() return {} end
package.preload["ltn12"] = function() return { source = {}, sink = {} } end
package.preload["socket.url"] = function() return { escape = function(s) return s end } end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["json"] = function() return { decode = function() return nil end, encode = function() return "" end } end

local API = require("uchi/api")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

--- An API bound to a fixed chapter list, counting the requests it serves.
local function api_for(books, page_size)
    local api = API:new("http://stub", { api_token = "uy_stub" })
    api.requests = 0
    local by_id = {}
    for _i, b in ipairs(books) do by_id[b.id] = b end
    function api:get_book(id)
        self.requests = self.requests + 1
        local b = by_id[id]
        if not b then return nil, "not found", 404 end
        return b
    end
    function api:get_series_books(_series_id, page, size)
        self.requests = self.requests + 1
        size = size or page_size or 100
        local content = {}
        for i = page * size + 1, math.min((page + 1) * size, #books) do
            table.insert(content, books[i])
        end
        return {
            content = content,
            totalElements = #books,
            totalPages = math.max(1, math.ceil(#books / size)),
            number = page,
            last = (page + 1) * size >= #books,
        }
    end
    return api
end

local function chapter(n, extra)
    local b = { id = "b" .. n, seriesId = "s1", seriesTitle = "Stub", name = "Chapter " .. n,
                metadata = { title = "Chapter " .. n, number = tostring(n), numberSort = n } }
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
end

local function series(count, mutate)
    local books = {}
    for i = 1, count do table.insert(books, chapter(i)) end
    if mutate then mutate(books) end
    return books
end

-- 1. The ordinary case: one page holds the series.
local api = api_for(series(20))
local prev, err = api:get_previous_book("b7")
check("previous of chapter 7 is chapter 6", prev and prev.id == "b6", err or (prev and prev.id))

-- 2. The first chapter has nothing before it -- and says so without an error,
--    which is what tells "you are at the start" from "the lookup failed".
prev, err = api:get_previous_book("b1")
check("chapter 1 has no previous", prev == nil and err == nil, err)

-- 3. A chapter the server does not know is an error, not a silent "first".
prev, err = api:get_previous_book("nope")
check("unknown chapter errors", prev == nil and err ~= nil, err)

-- 4. A long series: the chapter is found by searching pages rather than
--    walking all of them, including when it is the first entry on its page.
local long = api_for(series(1200), 100)
prev, err = long:get_previous_book("b901")          -- first entry of page 9
check("previous across a page boundary", prev and prev.id == "b900", err or (prev and prev.id))
check("page search stays cheap", long.requests <= 8, long.requests .. " requests")

-- 5. A tombstone is listed but has no pages behind it, so it is not a chapter
--    to turn back into -- the same rule the server's own /next follows.
local pruned = api_for(series(20, function(books) books[6].pruned = true end))
prev, err = pruned:get_previous_book("b7")
check("pruned chapter is skipped", prev and prev.id == "b5", err or (prev and prev.id))

-- 6. Two files can share a chapter number (this library has " (2)" copies),
--    and they are ordered by a file name the client never sees. Where that
--    happens on the scale of whole pages the page search lands on the wrong
--    one, and the full walk of the series has to catch it.
local ties = api_for(series(300, function(books)
    for i = 1, 250 do books[i].metadata.numberSort = 100; books[i].metadata.number = "100" end
end), 100)
prev, err = ties:get_previous_book("b50")
check("ties fall back to the whole list", prev and prev.id == "b49", err or (prev and prev.id))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
