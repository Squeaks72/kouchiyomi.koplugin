--[[
    Unit test for uchi/api.lua's get_series_position and chapter_is_after,
    against a stubbed server.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/series_position.lua     (from the plugin folder)

    What it is guarding: the answer to "where am I in this series?", which is
    what the catch-up prompt acts on. Getting it wrong closes the chapter the
    reader just opened and puts them somewhere else, so the cases that matter
    are this device's own stale writes, the end of the series, tombstones, the
    page that comes back with the chapter, and the forward-only rule.
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

--- An API answering the series' chapter list from a fixture (given in any order,
-- served newest first, 100 to a page as the server pages it), counting requests.
local function api_for(chapters)
    local api = API:new("http://stub", { api_token = "uy_stub" })
    api.requests = 0
    table.sort(chapters, function(a, b) return a.metadata.numberSort > b.metadata.numberSort end)
    function api:get_series_books(_id, page, size, sort)
        self.requests = self.requests + 1
        assert(sort == "metadata.numberSort,desc", "asks for newest first")
        local content = {}
        for i = page * size + 1, math.min((page + 1) * size, #chapters) do table.insert(content, chapters[i]) end
        return { content = content, last = (page + 1) * size >= #chapters }
    end
    return api
end

local function run_of(from, to, last_read, page_there)
    local list = {}
    for n = from, to do
        local p
        if n < last_read then p = { page = 20, completed = true } end
        if n == last_read then p = { page = page_there, completed = page_there >= 20 } end
        table.insert(list, chapter(n, p))
    end
    return list
end

-- 1. The reported bug, from the real timeline: the phone reached 235 page 8, then
--    the Kobo's jumps wrote 230 and 231 as the newest events. Order of writing
--    plays no part in the answer, so the position is still 235.
local pos, src = api_for(run_of(200, 251, 235, 8)):get_series_position("s1", chapter(232))
check("furthest chapter is the position", pos and pos.id == "b235", pos and pos.id)
check("and its page comes with it", pos and pos.readProgress and pos.readProgress.page == 8)
check("named as such", src == "furthest", src)

-- 2. The furthest chapter is finished: the position is the next one, at its start.
pos, src = api_for(run_of(1, 20, 7, 20)):get_series_position("s1", chapter(4))
check("finished chapter advances to the next", pos and pos.id == "b8", pos and pos.id)
check("the next one has no page to resume", pos and pos.readProgress == nil)

-- 3. Finished the newest chapter there is, several ahead of this device: that is
--    still the position. (It used to be no position, so the Kobo fell back to the
--    end of the open chapter.)
pos, src = api_for(run_of(1, 20, 20, 20)):get_series_position("s1", chapter(15))
check("the end of a series is a position", pos and pos.id == "b20", pos and pos.id)
check("and says it is the end", src == "series finished", src)

-- 4. A skipped chapter does not hide what is past it.
local skipped = run_of(1, 20, 12, 8)
skipped[1 + 12 - 3].readProgress = nil
pos = api_for(skipped):get_series_position("s1", chapter(2))
check("a gap in the reading is passed over", pos and pos.id == "b12", pos and pos.id)

-- 5. Only ever listed, never opened: readProgress present but empty is no progress.
local opened = run_of(1, 10, 3, 5)
opened[10].readProgress = { page = 0, completed = false }
pos = api_for(opened):get_series_position("s1", chapter(1))
check("page 0 is not progress", pos and pos.id == "b3", pos and pos.id)

-- 6. Tombstones are listed but cannot be opened.
local gone = run_of(1, 10, 7, 20)
gone[8].pruned = true
pos = api_for(gone):get_series_position("s1", chapter(1))
check("a pruned next chapter is skipped", pos and pos.id == "b9", pos and pos.id)
gone = run_of(1, 10, 7, 5)
gone[7].pruned = true
pos = api_for(gone):get_series_position("s1", chapter(1))
check("a pruned furthest chapter moves past it", pos and pos.id == "b8", pos and pos.id)
gone = run_of(1, 10, 10, 20)
gone[10].pruned = true
pos, src = api_for(gone):get_series_position("s1", chapter(1))
check("a pruned last chapter is no place to land", pos == nil and src == "series finished", src)

-- 7. Cost: a far-behind reader stops at the open chapter; nothing is fetched past it.
local api = api_for(run_of(1, 609, 141, 9))
pos, src = api:get_series_position("s1", chapter(600))
check("nothing ahead of the open chapter", pos == nil and src == "nothing ahead", src)
check("and one request said so", api.requests == 1, api.requests)
api = api_for(run_of(1, 1198, 1197, 5))
pos = api:get_series_position("s1", chapter(1100))
check("a current reader of a long series", pos and pos.id == "b1197" and api.requests == 1, api.requests)
api = api_for(run_of(1, 609, 141, 9))
pos = api:get_series_position("s1", chapter(100))
check("pages walk until they find it", pos and pos.id == "b141" and api.requests == 5, api.requests)

-- 8. Asked by hand there is no floor, so an earlier position can still be named.
pos = api_for(run_of(1, 20, 7, 5)):get_series_position("s1")
check("no floor finds an earlier chapter", pos and pos.id == "b7", pos and pos.id)

-- 9. Never read anywhere, or a server that will not answer.
pos, src = api_for(run_of(1, 5, 0, 0)):get_series_position("s1")
check("an untouched series has no position", pos == nil and src == "not read yet", src)
api = API:new("http://stub", { api_token = "uy_stub" })
function api:get_series_books() return nil, "timeout" end
pos, src = api:get_series_position("s1")
check("a failed fetch says why", pos == nil and src == "timeout", src)
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
