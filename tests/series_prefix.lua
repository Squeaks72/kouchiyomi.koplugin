--[[
    Unit test for uchi/labels.lua's stripSeries: a chapter's title without the series it leads with.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/series_prefix.lua     (from the plugin folder)

    Uchiyomi can name its files "<Series> - Chapter N" (its SERIES_IN_NAMES setting), and the title it answers with is
    that name. The cases that matter are the ones that must NOT change: a plain "Chapter 5", a source's own
    "Ch. 5 - The Storm", and "Chapter 12 - Part 2".
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local Labels = require("uchi/labels")

local failed = 0
local function check(title, series, want)
    local got = Labels.stripSeries(title, series)
    if got ~= want then
        failed = failed + 1
        print(string.format("FAIL  %q (series %q): wanted %q, got %q", title, tostring(series), want, tostring(got)))
    end
end

-- Series known, spelt the same.
check("Blue Box - Chapter 211", "Blue Box", "Chapter 211")
check("blue box - Chapter 211", "Blue Box", "Chapter 211")
check("Boruto - Naruto Next Generations - Chapter 64", "Boruto - Naruto Next Generations", "Chapter 64")
check("Sakamoto Days - Days 240", "Sakamoto Days", "Days 240")
check("Blue Box: Chapter 5", "Blue Box", "Chapter 5")
check("Blue Box \226\128\147 Chapter 5", "Blue Box", "Chapter 5")
check("Blue Box - # 211", "Blue Box", "# 211")
-- Series unknown: the last " - " splits, if what follows is a chapter.
check("Blue Box - Chapter 211", nil, "Chapter 211")
check("Boruto - Naruto Next Generations - Chapter 64", nil, "Chapter 64")
check("Re - Zero - Chapter 3", "", "Chapter 3")
-- Series spelt differently from the folder ("College?" became "College_", ":" became " -").
check("Is There No Goddess in My College_ - Chapter 75", "Is There No Goddess in My College?", "Chapter 75")
check("Boruto - Naruto Next Generations - Chapter 64", "Boruto: Naruto Next Generations", "Chapter 64")
-- Left alone.
check("Chapter 211", "Blue Box", "Chapter 211")
check("Chapter 211", nil, "Chapter 211")
check("Ch. 5 - The Storm", "Blue Box", "Ch. 5 - The Storm")
check("Ch. 5 - The Storm", nil, "Ch. 5 - The Storm")
check("Chapter 12 - Part 2", nil, "Chapter 12 - Part 2")
check("Mob Psycho 100", "Mob Psycho 100", "Mob Psycho 100")
check("Blue Box", "Blue Box", "Blue Box")
check("Some Title - The End", nil, "Some Title - The End")
check("A Different Series - Chapter 9", "Blue Box", "A Different Series - Chapter 9")
check("", "Blue Box", "")

-- The three callers that use it.
assert(Labels.rawTitle({ metadata = { title = "Blue Box - Chapter 211" }, seriesTitle = "Blue Box" }) == "Chapter 211")
assert(Labels.rawTitle({ metadata = { title = "Blue Box - Chapter 211" } }) == "Chapter 211")
-- A subtitle says what a chapter's title adds to its number: here, nothing.
assert(Labels.subtitle({ metadata = { title = "Blue Box - Chapter 211", number = 211 }, seriesTitle = "Blue Box" }, "Blue Box") == nil,
    "a prefixed plain chapter gets no subtitle")
assert(Labels.subtitle({ metadata = { title = "Blue Box - Chapter 211: The Dare", number = 211 } }, "Blue Box") == "The Dare",
    "a real chapter name still shows")
assert(Labels.chapter({ metadata = { title = "Blue Box - Chapter 211", number = 211 } }) == "Ch. 211")

if failed > 0 then
    print(failed .. " check(s) failed")
    os.exit(1)
end
print("series_prefix: all checks passed")
