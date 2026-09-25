--[[
    Unit test for the retention rule behind uchi/sync.lua's processCleanup.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no server:
      lua5.1 tests/cleanup.lua              (from the plugin folder)

    What it is guarding: when a finished chapter's file is allowed to go. It
    used to go the moment Uchiyomi confirmed the chapter read, which deleted the
    one chapter you are most likely to want straight back -- the previous-chapter
    turn and a catch-up jump both land in it. The grace period is the fix, and
    the rule has four outcomes that are easy to get subtly wrong.
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

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
