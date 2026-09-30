--[[
    Unit test for uchi/sleepscreen.lua: holding KOReader's sleep screen while an
    18+ chapter is on screen.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader:
      lua5.1 tests/sleepscreen.lua          (from the plugin folder)

    What it is guarding: a change to the READER'S OWN settings, made to keep a
    page off the sleep screen and undone afterwards. The failure that matters is
    not the guarantee -- it is the restore: getting it wrong silently leaves
    somebody's sleep screen replaced forever, and arming twice would stash the
    forced values as if they had chosen them.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

--- Stand-in for KOReader's global settings, which the module reads and writes.
local function fake_globals(initial)
    local store = {}
    for k, v in pairs(initial or {}) do store[k] = v end
    return {
        store = store,
        readSetting = function(self, k) return self.store[k] end,
        saveSetting = function(self, k, v) self.store[k] = v end,
        delSetting = function(self, k) self.store[k] = nil end,
    }
end

local function fake_plugin()
    local p = { settings = {}, saves = 0 }
    p.saveSettings = function(self) self.saves = self.saves + 1 end
    return p
end

local Sleep = require("uchi/sleepscreen")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

-- 1. Arming covers the panel: the type is forced AND so is the message
--    background, which KOReader defaults to "none" -- a message with no
--    background is drawn over the page, which would be decoration, not a
--    guarantee.
G_reader_settings = fake_globals{ screensaver_type = "cover", screensaver_msg_background = "none" }
local p = fake_plugin()
check("arming reports success", Sleep.arm(p) == true)
check("the sleep screen is a message", G_reader_settings.store.screensaver_type == "message",
      G_reader_settings.store.screensaver_type)
check("with a background that covers the page", G_reader_settings.store.screensaver_msg_background == "black",
      G_reader_settings.store.screensaver_msg_background)

-- 2. Disarming puts back exactly what was there.
check("disarming reports success", Sleep.disarm(p) == true)
check("the reader's own type is back", G_reader_settings.store.screensaver_type == "cover",
      G_reader_settings.store.screensaver_type)
check("and their own background", G_reader_settings.store.screensaver_msg_background == "none",
      G_reader_settings.store.screensaver_msg_background)
check("and nothing is left stashed", p.settings.sleep_screen_restore == nil)
check("disarming again does nothing", Sleep.disarm(p) == false)

-- 3. A setting the reader never had must be DELETED on the way back, not left
--    holding the forced value -- otherwise arming once invents a preference.
G_reader_settings = fake_globals{}
p = fake_plugin()
Sleep.arm(p)
check("a setting is forced even when unset", G_reader_settings.store.screensaver_type == "message")
Sleep.disarm(p)
check("an unset type goes back to unset", G_reader_settings.store.screensaver_type == nil,
      G_reader_settings.store.screensaver_type)
check("an unset background too", G_reader_settings.store.screensaver_msg_background == nil,
      G_reader_settings.store.screensaver_msg_background)

-- 4. Arming twice must not stash the forced values as the reader's own, or
--    disarming would "restore" them to the screen it was hiding things with.
G_reader_settings = fake_globals{ screensaver_type = "cover" }
p = fake_plugin()
Sleep.arm(p)
Sleep.arm(p)
Sleep.disarm(p)
check("arming twice still restores the original", G_reader_settings.store.screensaver_type == "cover",
      G_reader_settings.store.screensaver_type)

-- 5. A session killed while armed leaves the stash behind; the next start puts
--    the reader's sleep screen back rather than leaving it replaced forever.
G_reader_settings = fake_globals{ screensaver_type = "cover" }
p = fake_plugin()
Sleep.arm(p)
local carried = p.settings.sleep_screen_restore
check("the stash is on disk, not in memory", type(carried) == "table")
local next_session = fake_plugin()
next_session.settings.sleep_screen_restore = carried
G_reader_settings = fake_globals{ screensaver_type = "message" }  -- as the dead session left it
check("a stale hold is noticed", Sleep.restoreIfStale(next_session) == true)
check("and released", G_reader_settings.store.screensaver_type == "cover",
      G_reader_settings.store.screensaver_type)
check("a clean start has nothing to release", Sleep.restoreIfStale(fake_plugin()) == false)

-- 6. Turned off means untouched.
G_reader_settings = fake_globals{ screensaver_type = "cover" }
p = fake_plugin()
p.settings.guard_sleep_screen = false
check("the setting is respected", Sleep.arm(p) == false)
check("and nothing is changed", G_reader_settings.store.screensaver_type == "cover")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
