--[[
    Unit test for uchi/api.lua's get_series_position and chapter_is_after,
    against a stubbed server.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/series_position.lua     (from the plugin folder)

    What it is guarding: the answer to "where am I in this series?", which is
    what the catch-up prompt acts on. Getting it wrong closes the chapter the
    reader just opened and puts them somewhere else, so the cases that matter
    are the fallbacks (onDeck does not list every series), the page that comes
    back with the chapter, and the forward-only rule.
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

local function chapter(n, progress)
    return {
        id = "b" .. n, seriesId = "s1", seriesTitle = "Stub", name = "Chapter " .. n,
        metadata = { title = "Chapter " .. n, number = tostring(n), numberSort = n },
        media = { pagesCount = 20 },
        readProgress = progress,
    }
end

--- An API answering /home, /history and the per-book lookups from fixtures,
-- counting requests so the cheap path can be shown to stay cheap.
local function api_for(fixture)
    local api = API:new("http://stub", { api_token = "uy_stub" })
    api.requests = 0
    function api:get_home()
        self.requests = self.requests + 1
        return fixture.home or {}
    end
    function api:get_history(_limit)
        self.requests = self.requests + 1
        return fixture.history or { content = {} }
    end
    function api:get_book(id)
        self.requests = self.requests + 1
        return (fixture.books or {})[id] or nil, "not found", 404
    end
    function api:get_next_book(id)
        self.requests = self.requests + 1
        return (fixture.next or {})[id]
    end
    return api
end

-- 1. The server's own "Keep reading" rail answers it in one request.
local api = api_for{ home = { onDeck = {
    chapter(12, { page = 8, completed = false }),
    { id = "x1", seriesId = "s2", metadata = { number = "3", numberSort = 3 } },
} } }
local pos, src = api:get_series_position("s1")
check("on-deck chapter is the position", pos and pos.id == "b12", src)
check("and its page comes with it", pos and pos.readProgress and pos.readProgress.page == 8)
check("one request for the common case", api.requests == 1, api.requests .. " requests")

-- 2. Another series' entry on the rail is not this series' position.
pos, src = api_for{ home = { onDeck = { { id = "x1", seriesId = "s2" } } },
                    history = { content = {} } }:get_series_position("s1")
check("a different series is ignored", pos == nil, pos and pos.id)

-- 3. Off the rail (read long enough ago): history carries it, per chapter.
api = api_for{
    home = { onDeck = {} },
    history = { content = { { series_id = "s1", book_id = "b7", page = 4, completed = false } } },
    books = { b7 = chapter(7, { page = 4, completed = false }) },
}
pos, src = api:get_series_position("s1")
check("history fallback finds the chapter", pos and pos.id == "b7", src)
check("history fallback keeps the page", pos and pos.readProgress.page == 4)

-- 4. A history row for a chapter the server has no readProgress on (progress
--    written silently) still knows the page -- the row itself holds it.
api = api_for{
    home = {},
    history = { content = { { series_id = "s1", book_id = "b7", page = 11, completed = false } } },
    books = { b7 = chapter(7, nil) },
}
pos = api:get_series_position("s1")
check("page comes off the history row", pos and pos.readProgress and pos.readProgress.page == 11,
      pos and pos.readProgress and pos.readProgress.page)

-- 5. The last chapter they touched is finished: the position is the next one,
--    at its start.
api = api_for{
    home = {},
    history = { content = { { series_id = "s1", book_id = "b7", page = 20, completed = true } } },
    next = { b7 = chapter(8, nil) },
}
pos, src = api:get_series_position("s1")
check("finished chapter advances to the next", pos and pos.id == "b8", src)
check("the next one has no page to resume", pos and pos.readProgress == nil)

-- 6. Finished the last chapter there is: no position, and no crash.
api = api_for{
    home = {},
    history = { content = { { series_id = "s1", book_id = "b7", completed = true } } },
    next = {},
}
pos, src = api:get_series_position("s1")
check("the end of a series is not a position", pos == nil, pos and pos.id)

-- 7. Never read anywhere: nothing to catch up to.
pos, src = api_for{ home = {}, history = { content = {} } }:get_series_position("s1")
check("an untouched series has no position", pos == nil, pos and pos.id)
check("no series id, no answer", (API:new("http://stub", {})):get_series_position(nil) == nil)

-- 8. Forward only. This is the rule that keeps a stale server position from
--    closing the chapter the reader deliberately opened.
check("later chapter is after", API.chapter_is_after(chapter(12), chapter(4)) == true)
check("earlier chapter is not", API.chapter_is_after(chapter(2), chapter(4)) == false)
check("the same number cannot say", API.chapter_is_after(chapter(4), chapter(4)) == nil)
check("a missing number cannot say",
      API.chapter_is_after({ id = "b1", name = "Oneshot" }, chapter(4)) == nil)
check("decimal chapters compare as numbers",
      API.chapter_is_after(chapter(4.5), chapter(4)) == true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
