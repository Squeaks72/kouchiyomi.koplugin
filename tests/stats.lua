--[[
    Unit test for uchi/stats.lua: which reading-statistics rows belong to an
    18+ series.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no database:
      lua5.1 tests/stats.lua                (from the plugin folder)

    What it is guarding: a match that DELETES, from a database of real reading
    history that has no undo. A miss leaves an 18+ title under Statistics ▸ Top
    books; a false positive throws away someone's record of a book they read.
    The awkward part is that the statistics plugin stores a series with its
    index glued on ("One Piece #944"), so the match cannot be equality alone --
    and must not become a wildcard either.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
-- Only dbPath/backupPath reach for KOReader; the matching rule below does not.
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/stub/settings" end }
end

local Stats = require("uchi/stats")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local adult = { ["Dirty Laundry"] = true, ["100%"] = true, ["Re_Zero"] = true }
local function row(t) return t end

-- 1. The series name, as the statistics plugin stores it: bare, or with the
--    index appended (`series .. " #" .. series_index` in its main.lua).
check("a bare series name matches", Stats.matches(row{ id = 1, series = "Dirty Laundry" }, adult) == true)
check("with a chapter number appended", Stats.matches(row{ id = 1, series = "Dirty Laundry #12" }, adult) == true)
check("with a decimal chapter number", Stats.matches(row{ id = 1, series = "Dirty Laundry #12.5" }, adult) == true)
check("another series does not", Stats.matches(row{ id = 1, series = "Berserk #41" }, adult) == false)
check("nor one that merely starts the same",
      Stats.matches(row{ id = 1, series = "Dirty Laundry Returns" }, adult) == false)
check("nor a suffix that is not an index",
      Stats.matches(row{ id = 1, series = "Dirty Laundry #extra" }, adult) == false)

-- 2. A title with SQL wildcards in it must be a title, not a pattern. This is
--    why the match is done in Lua: "100%" as a LIKE pattern matches everything
--    and would empty the table.
check("a per-cent sign is a character, not a wildcard",
      Stats.matches(row{ id = 1, series = "100%" }, adult) == true)
check("and does not match something else",
      Stats.matches(row{ id = 1, series = "Vinland Saga" }, adult) == false)
check("an underscore is a character too", Stats.matches(row{ id = 1, series = "Re_Zero" }, adult) == true)
check("so it does not match any single character",
      Stats.matches(row{ id = 1, series = "ReXZero" }, adult) == false)

-- 3. "N/A" is what the statistics plugin writes for a document with no series.
--    It identifies nothing, and a series list that somehow contained it must
--    not turn into "delete everything unfiled".
check("no series is not a match", Stats.matches(row{ id = 1, series = "N/A" }, adult) == false)
check("an empty series is not a match", Stats.matches(row{ id = 1, series = "" }, adult) == false)
check("a missing series is not a match", Stats.matches(row{ id = 1 }, adult) == false)
check("even when N/A is in the list",
      Stats.matches(row{ id = 1, series = "N/A" }, { ["N/A"] = true }) == false)

-- 4. The md5: the exact identity, taken from a file the sweep is about to
--    delete, and enough on its own when the series says nothing.
local md5s = { abc123 = true }
check("a known md5 matches", Stats.matches(row{ id = 1, md5 = "abc123", series = "N/A" }, adult, md5s) == true)
check("an unknown one does not", Stats.matches(row{ id = 1, md5 = "def456", series = "N/A" }, adult, md5s) == false)
check("the md5 wins over a series that says nothing",
      Stats.matches(row{ id = 1, md5 = "abc123" }, {}, md5s) == true)
check("and the series still works with no md5 list",
      Stats.matches(row{ id = 1, series = "Dirty Laundry" }, adult, nil) == true)

-- 5. Nothing to match against is not a licence to delete.
check("no lists at all matches nothing", Stats.matches(row{ id = 1, series = "Dirty Laundry" }, nil, nil) == false)
check("empty lists match nothing", Stats.matches(row{ id = 1, series = "Dirty Laundry" }, {}, {}) == false)
check("a row that is not a row matches nothing", Stats.matches(nil, adult, md5s) == false)
check("nor a string pretending to be one", Stats.matches("Dirty Laundry", adult, md5s) == false)

-- 6. The backup goes beside the database and is named, not guessed at.
check("the backup sits next to the database",
      Stats.backupPath() == Stats.dbPath() .. ".kouchiyomi-bkp", Stats.backupPath())

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
