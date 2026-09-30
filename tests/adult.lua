--[[
    Unit test for uchi/adult.lua: which series are 18+.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/adult.lua                (from the plugin folder)

    What it is guarding: the answer that decides whether a chapter may be
    written to the device at all. A false negative puts an 18+ chapter in the
    file manager, the cover browser and KOReader's history -- the exact thing
    this is for -- so the cases that matter are the ones where the answer is
    only half known: a library list that could not be fetched, a series seen for
    the first time, a device with no network.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local Adult = require("uchi/adult")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

--- A stand-in for the plugin: a settings table, a counter of saves, and an API
-- that answers /api/libraries and /api/series from fixtures.
local function fake_plugin(libraries, series_by_id)
    local p = { settings = { adult_libraries = nil, adult_libraries_at = 0, adult_series_cache = {} }, saves = 0, calls = 0 }
    p.saveSettings = function(self) self.saves = self.saves + 1 end
    p.api = {
        get_libraries = function(_self) p.calls = p.calls + 1; return libraries end,
        get_series = function(_self, id) p.calls = p.calls + 1; return (series_by_id or {})[tostring(id)] end,
    }
    return p
end

local function series(id, library, rating)
    return { id = id, libraryId = library, metadata = { ageRating = rating } }
end

-- 1. The rule itself, over the two signals that reach the client.
check("an 18+ library is 18+", Adult.decide(true, nil) == true)
check("a rating of 18 is 18+", Adult.decide(false, 18) == true)
check("and anything above it", Adult.decide(nil, 21) == true)
check("a rating below it is not", Adult.decide(false, 13) == false)
check("neither signal is not", Adult.decide(nil, nil) == false)
check("an unrated series in a normal library is not", Adult.decide(false, nil) == false)
-- The library wins over a lower rating: the server's own order is override,
-- then the series' rating, then the library's -- but a series with NO override
-- inside an 18+ library is 18+, and a plain 0 must not read as an override.
check("an 18+ library outranks a zero rating", Adult.decide(true, 0) == true)
check("a rating as a string still counts", Adult.decide(false, "18") == true)
check("junk in the rating is ignored", Adult.decide(false, "grown-up") == false)

-- 2. Which libraries are 18+, from /api/libraries -- which needs no adult=1 and
--    carries the flag precisely so a client can know without being shown.
local libs = { { id = "hen", name = "Hentai", adult = true },
               { id = "wc",  name = "Weeb Central", adult = false },
               { id = "ton", name = "Toonily" } }
local p = fake_plugin(libs)
local ids = Adult.libraryIds(p)
check("the 18+ library is in the set", ids.hen == true)
check("a normal one is not", ids.wc == nil)
check("nor one with no flag at all", ids.ton == nil)
check("the answer is kept", type(p.settings.adult_libraries) == "table" and p.settings.adult_libraries.hen == true)

-- Kept means kept: a second ask inside the TTL does not go to the server, which
-- is what makes this answerable on a device that is offline.
p.calls = 0
Adult.libraryIds(p)
check("a fresh answer is not re-fetched", p.calls == 0, p.calls .. " calls")
p.settings.adult_libraries_at = os.time() - (48 * 60 * 60)
Adult.libraryIds(p)
check("a stale one is", p.calls == 1, p.calls .. " calls")
p.calls = 0
Adult.libraryIds(p, true)
check("and force asks anyway", p.calls == 1, p.calls .. " calls")

-- A failed fetch keeps what was known rather than answering "nothing is 18+",
-- which would be the one wrong answer that puts files on the device.
local broken = fake_plugin(nil)
broken.settings.adult_libraries = { hen = true }
broken.settings.adult_libraries_at = 0
check("a failed refresh keeps the old answer", Adult.libraryIds(broken).hen == true)
check("and no server at all does too", Adult.libraryIds({ settings = { adult_libraries = { hen = true } } }).hen == true)

-- 3. A series is 18+ by its library or by its own rating.
p = fake_plugin(libs)
check("a series in the 18+ library", Adult.isSeries(p, series("s1", "hen", nil)) == true)
check("a series rated 18 anywhere", Adult.isSeries(p, series("s2", "wc", 18)) == true)
check("an ordinary series", Adult.isSeries(p, series("s3", "wc", nil)) == false)
check("nothing is not a series", Adult.isSeries(p, nil) == nil)

-- The answer is remembered per series, both ways round, so the question can be
-- answered later with no network...
check("a yes is remembered", Adult.knownSeries(p, "s1") == true)
check("a no is remembered too", Adult.knownSeries(p, "s3") == false, Adult.knownSeries(p, "s3"))
check("an unseen series is not remembered", Adult.knownSeries(p, "s9") == nil)
-- ...and re-asking the same question does not rewrite the settings file, which
-- the sweep does once per downloaded chapter.
p.saves = 0
Adult.isSeries(p, series("s1", "hen", nil))
check("an unchanged answer is not saved again", p.saves == 0, p.saves .. " saves")

-- 4. A chapter: the series in hand, else what is remembered, else the server.
p = fake_plugin(libs, { s1 = series("s1", "hen", nil), s3 = series("s3", "wc", nil) })
check("a series passed in is used", Adult.isBook(p, { id = "b1", seriesId = "s1" }, series("s1", "hen")) == true)
p.calls = 0
check("and passing it in asks nothing", p.calls == 0, p.calls .. " calls")

-- With nothing in hand and nothing remembered, the server is asked...
p = fake_plugin(libs, { s1 = series("s1", "hen", nil), s3 = series("s3", "wc", nil) })
check("otherwise the server is asked", Adult.isBook(p, { id = "b1", seriesId = "s1" }) == true)
check("which costs a request", p.calls >= 1, p.calls .. " calls")
-- ...and only the once, however many chapters of that series follow.
p.calls = 0
check("and then it is remembered", Adult.isBook(p, { id = "b2", seriesId = "s1" }) == true)
check("without asking again", p.calls == 0, p.calls .. " calls")

-- Unknowable is nil, never false dressed up as an answer: callers treat nil as
-- "not 18+" deliberately (a chapter cannot be downloaded without the server
-- anyway), so the distinction has to survive.
check("a chapter with no series is unknowable", Adult.isBook(p, { id = "b3" }) == nil)
check("a series the server does not have is unknowable", Adult.isBook(p, { id = "b4", seriesId = "gone" }) == nil)
local offline = fake_plugin(libs)
offline.api = nil
check("no server and nothing remembered is unknowable", Adult.isBook(offline, { id = "b5", seriesId = "s1" }) == nil)
offline.settings.adult_series_cache = { s1 = true }
check("but a remembered yes survives having no server", Adult.isBook(offline, { id = "b5", seriesId = "s1" }) == true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
