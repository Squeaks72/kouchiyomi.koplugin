--[[
    Keeping an 18+ chapter off the sleep screen.

    The sleep screen cannot be fixed after the fact. KOReader shows it from
    `Device:onPowerEvent` -- `Screensaver:setup()` then `Screensaver:show()` --
    and only calls `Device:_beforeSuspend()`, which broadcasts the `Suspend`
    event a plugin could hear, afterwards. By the time this plugin is told the
    device is suspending, the screen has already been painted.

    So it is arranged in advance instead: while an 18+ chapter is on screen, the
    two settings `Screensaver:setup()` reads are held at values that cover the
    screen, and put back when the chapter closes.

      screensaver_type        -- "disable" leaves the last screen on the panel,
                                 which on e-ink means the page stays visible for
                                 as long as the device sleeps. "cover" is safe
                                 for a streamed chapter (no document is opened,
                                 so `lastfile` never becomes the 18+ one), but
                                 not worth relying on.
      screensaver_msg_background -- defaults to "none", which draws the message
                                 OVER whatever was on screen. Without this the
                                 override would be decoration, not a guarantee.

    The original values are stashed in the plugin's own settings, not in memory:
    if KOReader is killed or the battery dies while a chapter is open, the next
    start puts them back (restoreIfStale).
--]]

local logger = require("logger")

local Sleep = {}

-- What is forced while an 18+ chapter is open. "message" paints the screen and
-- says nothing about what is behind it.
local FORCED = {
    screensaver_type = "message",
    screensaver_msg_background = "black",
}

local STASH = "sleep_screen_restore"

local function settings()
    return G_reader_settings
end

--- Hold the sleep screen at something that shows nothing. Idempotent: arming
-- twice must not stash the forced values as if they were the reader's own.
function Sleep.arm(plugin)
    if plugin.settings.guard_sleep_screen == false then return false end
    local g = settings()
    if not g then return false end
    if plugin.settings[STASH] then return true end
    local stash = {}
    for key, forced in pairs(FORCED) do
        -- `false` marks "there was no setting", so disarming can delete it again
        -- rather than inventing a value the reader never chose. Spelled out
        -- rather than `current == nil and false or current`, which cannot ever
        -- yield false and so would stash nothing at all for an unset key.
        local current = g:readSetting(key)
        if current == nil then stash[key] = false else stash[key] = current end
        g:saveSetting(key, forced)
    end
    plugin.settings[STASH] = stash
    plugin:saveSettings()
    logger.dbg("kouchiyomi: sleep screen held for an 18+ chapter")
    return true
end

--- Put the reader's own sleep screen back.
function Sleep.disarm(plugin)
    local stash = plugin.settings[STASH]
    if not stash then return false end
    local g = settings()
    plugin.settings[STASH] = nil
    if g then
        for key, saved in pairs(stash) do
            if saved == false then g:delSetting(key) else g:saveSetting(key, saved) end
        end
    end
    plugin:saveSettings()
    logger.dbg("kouchiyomi: sleep screen released")
    return true
end

--- A stash left over from a session that was killed while a chapter was open.
-- Called at startup, before anything has been armed in this one.
function Sleep.restoreIfStale(plugin)
    if not plugin.settings[STASH] then return false end
    logger.info("kouchiyomi: restoring a sleep screen left held by a previous session")
    return Sleep.disarm(plugin)
end

--- Arm or disarm according to whether what is on screen is 18+.
function Sleep.forBook(plugin, book, series)
    local Adult = require("uchi/adult")
    local ok, verdict = pcall(Adult.isBook, plugin, book, series)
    if ok and verdict == true then return Sleep.arm(plugin) end
    return Sleep.disarm(plugin)
end

function Sleep.forPath(plugin, filepath)
    local Adult = require("uchi/adult")
    local ok, verdict = pcall(Adult.isPath, plugin, filepath)
    if ok and verdict == true then return Sleep.arm(plugin) end
    return Sleep.disarm(plugin)
end

return Sleep
