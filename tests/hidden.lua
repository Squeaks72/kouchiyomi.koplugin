--[[
    Hidden libraries: what a search asks for, what the other listings keep, and that a failed read loses nothing.
    Plain Lua 5.1, no KOReader:
      lua5.1 tests/hidden.lua     (from the plugin folder)
--]]
package.path = "./?.lua;" .. package.path
local H = require("uchi/hidden")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local function plugin(settings, api)
    return { settings = settings, api = api, saveSettings = function(self) self.saved = (self.saved or 0) + 1 end }
end
local function ids(l, key)
    local t = {}
    for _i, e in ipairs(l) do t[#t + 1] = e[key or "id"] end
    return table.concat(t)
end

-- Nothing hidden: nothing changes, nothing is asked.
local asked = 0
local p = plugin({}, { series_ids_in = function() asked = asked + 1; return {} end })
local list = { { id = "a", libraryId = "w" } }
check("nothing hidden: same list back", H.withoutSeries(p, list) == list)
check("nothing hidden: condition untouched", H.condition(p) == nil)
check("nothing hidden: refresh asks nothing", H.refresh(p) == true and asked == 0)

-- Search.
p = plugin({ hidden_libraries = { w = "Webtoons" } })
local c = H.condition(p)
check("search leaves the library out", c.allOf[1].libraryId.operator == "isNot" and c.allOf[1].libraryId.value == "w" and #c.allOf == 1)
c = H.condition(p, { readStatus = { operator = "is", value = "READ" } })
check("search keeps the condition it was given", c.allOf[1].readStatus ~= nil and c.allOf[2].libraryId.value == "w")

-- Series name their library; chapters and bookmarks only their series.
p = plugin({ hidden_libraries = { w = "Webtoons" }, hidden_series = { s2 = true, moved = true } })
check("array of series", ids(H.withoutSeries(p, { { id = "s1", libraryId = "m" }, { id = "s2", libraryId = "w" } })) == "s1")
local res = H.withoutSeries(p, { content = { { id = "s1", libraryId = "m" }, { id = "s2", libraryId = "w" } }, totalPages = 1 })
check("response keeps its shape", ids(res.content) == "s1" and res.totalPages == 1)
res = H.withoutSeries(p, { items = { { id = "s3", libraryId = "w" }, { id = "s4", libraryId = "m" } }, name = "L" })
check("a list's items", ids(res.items) == "s4" and res.name == "L")
check("a new series in the library, not yet in the kept ids", H.isSeries(p, "new", { libraryId = "w" }) == true)
check("a series moved out wins over the kept ids", H.isSeries(p, "moved", { libraryId = "m" }) == false)
check("a series with no library falls back to the kept ids", ids(H.withoutSeries(p, { { id = "s2" }, { id = "s9" } })) == "s9")
check("chapters by seriesId", ids(H.withoutChapters(p, { { id = "b1", seriesId = "s2" }, { id = "b2", seriesId = "s1" } })) == "b2")
check("bookmarks by series_id", ids(H.withoutChapters(p, { content = { { book_id = "b1", series_id = "s2" }, { book_id = "b2", series_id = "s1" } } }).content, "book_id") == "b2")
check("libraries", ids(H.withoutLibraries(p, { { id = "w" }, { id = "m" } })) == "m")
check("an error passes through", H.withoutSeries(p, nil) == nil)

-- Reading the ids.
local answer = { s5 = true }
asked = 0
p = plugin({ hidden_libraries = { w = "Webtoons" }, hidden_series = { old = true }, hidden_series_at = os.time() },
    { series_ids_in = function(_s, l) asked = asked + 1; return answer, l end })
check("fresh ids are not read again", H.refresh(p) == true and asked == 0)
check("forced read replaces them", H.refresh(p, true) == true and asked == 1 and p.settings.hidden_series.s5 and not p.settings.hidden_series.old)
p.settings.hidden_series_at = os.time() - H.TTL - 1
check("stale ids are read again", H.refresh(p) == true and asked == 2)
answer = nil
p.settings.hidden_series = { keep = true }
check("a failed read says so", H.refresh(p, true) == false)
check("a failed read keeps the ids and tries again", p.settings.hidden_series.keep and p.settings.hidden_series_at == 0)

-- Changing what is hidden.
answer = { s2 = true }
local d = { hidden_series_at = 0, home_rows = {
    onDeck = { { id = "b1", seriesId = "s2" }, { id = "b2", seriesId = "s1" } },
    popular = { { id = "s2", seriesId = "s2" } },
} }
p = plugin(d, { series_ids_in = function() return answer end })
p._home_cache, p._scope_cache = {}, {}
check("hide reports success", H.set(p, "w", "Webtoons", true) == true)
check("hide is remembered with its name", p.settings.hidden_libraries.w == "Webtoons" and H.isLibrary(p, "w"))
check("hide clears what is saved on the device", ids(d.home_rows.onDeck) == "b2" and #d.home_rows.popular == 0)
check("hide drops the browser's caches", p._home_cache == nil and p._scope_cache == nil)
answer = nil
check("a failed read is reported, the library stays hidden", H.set(p, "x", "Other", true) == false and H.isLibrary(p, "x"))
answer = {}
H.set(p, "x", nil, false)
H.set(p, "w", nil, false)
check("showing the last one clears the ids", not H.any(p) and next(p.settings.hidden_series) == nil)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
