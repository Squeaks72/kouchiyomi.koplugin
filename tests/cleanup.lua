--[[
    Unit test for the retention rule behind uchi/sync.lua's processCleanup.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/cleanup.lua              (from the plugin folder)

    What it is guarding: when a finished chapter's file is allowed to go. It
    used to go the moment Uchiyomi confirmed the chapter read, which deleted the
    one chapter you are most likely to want straight back -- the previous-chapter
    turn and a catch-up jump both land in it. Two rules now hold a chapter, a
    grace period and a per-series "newest few", and either one is enough.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

-- The KOReader modules sync.lua pulls in at load time. None are touched by the
-- rule under test, which is the point of it being a function of numbers.
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ui/uimanager"] = function() return { nextTick = function() end, scheduleIn = function() end } end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["docsettings"] = function() return {} end

local Sync = require("uchi/sync")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local DAY = 86400
local verdict = Sync.cleanupVerdict

-- 1. The old behaviour is still reachable: with no grace period a finished
--    chapter is handed to the server the moment it is looked at.
check("no delay asks at once", verdict(0, 0, true, false) == "ask", verdict(0, 0, true, false))

-- 2. Inside the grace period nothing happens -- and nothing is asked of the
--    server either, which is why a week of pending files costs no requests.
check("fresh chapter waits", verdict(60, 7 * DAY, true, false) == "wait")
check("a day into a week still waits", verdict(1 * DAY, 7 * DAY, true, false) == "wait")
check("six days into a week still waits", verdict(6 * DAY, 7 * DAY, true, false) == "wait")

-- 3. The period is up: now the server decides.
check("the period ends exactly on time", verdict(7 * DAY, 7 * DAY, true, false) == "ask")
check("long past it asks too", verdict(90 * DAY, 7 * DAY, true, false) == "ask")

-- 4. Reopening the chapter restarts the clock rather than letting it run out
--    under a chapter being read right now.
check("the open chapter is touched", verdict(90 * DAY, 7 * DAY, true, true) == "touch")
check("touch wins even with no delay set", verdict(0, 0, true, true) == "touch")

-- 5. A file deleted some other way (by hand, by the storage cap) is forgotten
--    instead of being asked about forever.
check("a missing file is forgotten", verdict(90 * DAY, 7 * DAY, false, false) == "forget")
check("a missing file is forgotten mid-period", verdict(1, 7 * DAY, false, false) == "forget")
check("but an open chapter is never forgotten", verdict(1, 7 * DAY, false, true) == "touch")

-- 6. A clock that went backwards (or an entry written in the future) must not
--    read as "long overdue" and delete early.
check("a future timestamp waits", verdict(-5 * DAY, 7 * DAY, true, false) == "wait")

-- 7. Junk in the settings file is not a reason to delete anything early.
check("a nil age is treated as brand new", verdict(nil, 7 * DAY, true, false) == "wait")
check("a nil delay is no delay", verdict(0, nil, true, false) == "ask")

-- 8. The second rule: being one of the newest few in the series holds a
--    chapter however long ago it was read, and either rule alone is enough.
check("newest holds a chapter the clock gave up on", verdict(90 * DAY, 7 * DAY, true, false, true) == "wait")
check("neither rule holding lets it go", verdict(90 * DAY, 7 * DAY, true, false, false) == "ask")
check("newest holds it with no grace period at all", verdict(0, 0, true, false, true) == "wait")
check("a missing file is still forgotten", verdict(0, 0, false, false, true) == "forget")

-- 9. The "newest few" answer costs a walk of the pending list, so it is asked
--    for lazily -- and only once everything cheaper has failed to settle the
--    entry. A chapter still inside its grace period must not even ask.
local asked
local function among(v) return function() asked = asked + 1; return v end end
asked = 0
check("inside the grace period nothing is asked", verdict(1, 7 * DAY, true, false, among(true)) == "wait" and asked == 0, asked)
asked = 0
check("an open chapter asks nothing either", verdict(90 * DAY, 7 * DAY, true, true, among(true)) == "touch" and asked == 0, asked)
asked = 0
check("a missing file asks nothing either", verdict(90 * DAY, 7 * DAY, false, false, among(true)) == "forget" and asked == 0, asked)
asked = 0
check("out of the period it is asked, once", verdict(90 * DAY, 7 * DAY, true, false, among(true)) == "wait" and asked == 1, asked)
asked = 0
check("and its answer decides", verdict(90 * DAY, 7 * DAY, true, false, among(false)) == "ask" and asked == 1, asked)

-- ---------------------------------------------------------------------------
-- Which chapters count as the newest few, from the pending list alone
-- ---------------------------------------------------------------------------

local newest = Sync.isAmongNewest

--- A pending-cleanup list: path -> { id, ts }, one series per folder.
local function reg(entries)
    local r = {}
    for _i, e in ipairs(entries) do r[e[1]] = { id = e[1], ts = e[2] } end
    return r
end

local shelf = reg{
    { "/m/One Piece/ch1.cbz", 100 },
    { "/m/One Piece/ch2.cbz", 200 },
    { "/m/One Piece/ch3.cbz", 300 },
    { "/m/One Piece/ch4.cbz", 400 },
    { "/m/Berserk/ch1.cbz",   500 },
    { "/m/Berserk/ch2.cbz",   600 },
}

check("the newest is kept", newest("/m/One Piece/ch4.cbz", shelf, 2) == true)
check("the one below it is kept", newest("/m/One Piece/ch3.cbz", shelf, 2) == true)
check("the third one down is not", newest("/m/One Piece/ch2.cbz", shelf, 2) == false)
check("nor the oldest", newest("/m/One Piece/ch1.cbz", shelf, 2) == false)

-- The count is per folder, so a series you are not reading cannot use up
-- another series' budget -- the whole reason for counting per folder.
check("another series does not eat the budget", newest("/m/Berserk/ch1.cbz", shelf, 2) == true)
check("and its own budget is its own", newest("/m/One Piece/ch4.cbz", shelf, 1) == true)
check("only one kept when the budget is one", newest("/m/One Piece/ch3.cbz", shelf, 1) == false)

-- Off, and the degenerate inputs around it.
check("zero keeps nothing", newest("/m/One Piece/ch4.cbz", shelf, 0) == false)
check("a nil count keeps nothing", newest("/m/One Piece/ch4.cbz", shelf, nil) == false)
check("a negative count keeps nothing", newest("/m/One Piece/ch4.cbz", shelf, -1) == false)
check("no registry keeps nothing", newest("/m/One Piece/ch4.cbz", nil, 3) == false)

-- Anything not awaiting cleanup -- an unread chapter sitting ahead of the
-- reader from the read-ahead, above all -- is not in the list and so cannot
-- spend the budget. That is the whole reason for ranking the read ones.
check("a chapter not awaiting cleanup is not held", newest("/m/One Piece/ch9.cbz", shelf, 3) == false)
check("and it does not displace one that is", newest("/m/One Piece/ch3.cbz", shelf, 2) == true)

-- The invariant the rule is for: past `count` read chapters in a series,
-- finishing another releases exactly the oldest one, and never more.
local function held(list, count)
    local n, set = 0, reg(list)
    for path in pairs(set) do if newest(path, set, count) then n = n + 1 end end
    return n
end
check("below the budget everything is held",
      held({ { "/m/S/a.cbz", 1 }, { "/m/S/b.cbz", 2 } }, 3) == 2)
check("at the budget everything is held",
      held({ { "/m/S/a.cbz", 1 }, { "/m/S/b.cbz", 2 }, { "/m/S/c.cbz", 3 } }, 3) == 3)
check("one over the budget releases exactly one",
      held({ { "/m/S/a.cbz", 1 }, { "/m/S/b.cbz", 2 }, { "/m/S/c.cbz", 3 }, { "/m/S/d.cbz", 4 } }, 3) == 3)
check("and it is the oldest that goes",
      newest("/m/S/a.cbz", reg{ { "/m/S/a.cbz", 1 }, { "/m/S/b.cbz", 2 },
                                { "/m/S/c.cbz", 3 }, { "/m/S/d.cbz", 4 } }, 3) == false)

-- A bare timestamp is read the same as an { id, ts } entry, so a pending list
-- half-migrated from an older version cannot make the rule misfire.
check("a bare timestamp is read as one", newest("/m/T/a.cbz", { ["/m/T/a.cbz"] = 5 }, 1) == true)

-- A batch that landed in the same second must still resolve to exactly `count`
-- kept files, not "all of them" -- otherwise a series downloaded in one go
-- would never be cleaned up.
local batch = reg{
    { "/m/S/a.cbz", 100 }, { "/m/S/b.cbz", 100 }, { "/m/S/c.cbz", 100 }, { "/m/S/d.cbz", 100 },
}
local kept = 0
for _i, f in ipairs{ "/m/S/a.cbz", "/m/S/b.cbz", "/m/S/c.cbz", "/m/S/d.cbz" } do
    if newest(f, batch, 2) then kept = kept + 1 end
end
check("a same-second batch keeps exactly the count", kept == 2, kept .. " kept")

-- Folders are matched whole: a series whose name is a prefix of another's is
-- a different folder, not part of it.
local prefix = reg{
    { "/m/Naruto/ch1.cbz", 100 },
    { "/m/Naruto Shippuden/ch1.cbz", 200 },
    { "/m/Naruto Shippuden/ch2.cbz", 300 },
}
check("a prefix folder is a different series", newest("/m/Naruto/ch1.cbz", prefix, 1) == true)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
