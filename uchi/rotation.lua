--[[
    Turning the screen for double-page spreads.

    A manga page is taller than it is wide, so a chapter reads upright. Every so
    often two pages are scanned as one image -- a spread -- and on a portrait
    screen that lands as two postage stamps with half the screen empty. The fix
    is to turn the device, which is a thing to do with your hands rather than a
    setting, so this does it for you: the page's own shape says which way the
    screen should be, and the screen follows.

    KOReader already has "Toggle orientation" as a gesture action of its own
    (Dispatcher's `toggle_rotation`); what it has no idea about is which way a
    page wants to be read. That part lives here.

    Everything KOReader-specific is required inside a function, so the rules
    below can be read (and tested) on a plain Lua.
--]]

local Rotation = {}

--[[
    Width/height at which a page stops being a page and becomes a spread.

    Two manga pages side by side come out around 1.43 (the pages themselves run
    1.40-1.50 tall, see LONG_STRIP_RATIO in main.lua), while a single page is
    about 0.7 and the squarish odd ones out -- covers, credits, a colour insert
    -- sit near 1.0. 1.2 is the gap between "nearly square" and "unmistakably two
    pages", with room on both sides, so a cover never turns the screen.
--]]
Rotation.WIDE_PAGE_RATIO = 1.2

-- KOReader's own convention (ffi/framebuffer.lua): 0 upright, 1 clockwise,
-- 2 upside down, 3 counter-clockwise -- so portrait is even, landscape is odd,
-- and each portrait's landscape is itself + 1.
function Rotation.isPortrait(mode)
    return (tonumber(mode) or 0) % 2 == 0
end

--- The other orientation, keeping which way up the device is. The same
-- arithmetic DeviceListener:onSwapRotation uses for the built-in toggle.
function Rotation.swap(mode)
    mode = tonumber(mode) or 0
    if Rotation.isPortrait(mode) then return (mode + 1) % 4 end
    return (mode - 1) % 4
end

--[[
    Which landscape to turn to.

    `pref` is the spread_rotation setting:
      "cw"     always clockwise
      "ccw"    always counter-clockwise
      "follow" (or anything else) KOReader's own rule -- the landscape that keeps
               which way up the device is being held, which is what its built-in
               "Toggle orientation" does

    Which of the two puts a Kobo's page-turn buttons under your thumb depends on
    which edge you hold, so this is a preference and not something to work out.
--]]
function Rotation.landscapeFor(mode, pref)
    if pref == "cw" then return 1 end
    if pref == "ccw" then return 3 end
    mode = tonumber(mode) or 0
    if Rotation.isPortrait(mode) then return Rotation.swap(mode) end
    return mode
end

--[[
    A toggle by hand: to landscape the preferred way, or back to portrait.

    `from` is the portrait it was last turned away from, and the reason this is
    not simply swap(): with a direction forced, the way back out of it is not the
    way in. Turning upright portrait (0) to counter-clockwise landscape (3) and
    then swapping would land on upside-down portrait (2) -- the screen the right
    way round for nobody. Returns the mode to go to, and the portrait to
    remember for the way back.
--]]
function Rotation.toggleTo(now, pref, from)
    now = tonumber(now) or 0
    if Rotation.isPortrait(now) then
        return Rotation.landscapeFor(now, pref), now
    end
    return from or Rotation.swap(now), nil
end

--- Width/height of one page of an open document, or nil when the document
-- cannot say (a reflowable one, a page that failed to load).
function Rotation.pageAspect(doc, pageno)
    if not (doc and doc.getNativePageDimensions and pageno) then return nil end
    local ok, dim = pcall(doc.getNativePageDimensions, doc, pageno)
    if not ok or type(dim) ~= "table" then return nil end
    local w, h = tonumber(dim.w), tonumber(dim.h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    return w / h
end

--- Is this page a spread? nil when the document will not say, which means
-- "leave the screen alone" rather than "no".
function Rotation.isWidePage(doc, pageno)
    local aspect = Rotation.pageAspect(doc, pageno)
    if not aspect then return nil end
    return aspect >= Rotation.WIDE_PAGE_RATIO
end

--[[
    The whole rule, as a function of three numbers and a boolean.

    `now`  the rotation the screen is in
    `wide` is the page a spread (nil = unknown; nothing moves)
    `base` the orientation to come back to, when the screen is currently turned
           because of a spread, else nil

    `pref` is which landscape a spread turns to (see landscapeFor).

    Returns the mode to switch to (nil = stay put) and the base to remember from
    here on. Turning back is only ever to an orientation this took the screen
    away from: a reader who turned the device themselves is left alone. Note the
    way back is that remembered portrait and never derived, so forcing a
    direction cannot strand the screen upside down.
--]]
function Rotation.decide(now, wide, base, pref)
    now = tonumber(now) or 0
    if wide == nil then return nil, base end
    if wide then
        -- Already landscape, even the other one: an orientation that is already
        -- readable is not worth wrenching around.
        if not Rotation.isPortrait(now) then return nil, base end
        return Rotation.landscapeFor(now, pref), now
    end
    if base == nil or base == now then return nil, nil end
    return base, nil
end

--- Put the screen in `mode`. ReaderView announces every rotation it makes;
-- `silent` drops that, because a page turn did not ask for one. (Notification
-- only shows a message whose source is in the reader's mask, and a nil source
-- is in nobody's.)
function Rotation.apply(ui, mode, silent)
    if not ui or mode == nil then return false end
    local Event = require("ui/event")
    local send = function() ui:handleEvent(Event:new("SetRotationMode", mode)) end
    if not silent then
        send()
        return true
    end
    local Notification = require("ui/widget/notification")
    local previous = Notification:getNotifySource()
    Notification:setNotifySource(nil)
    local ok, err = pcall(send)
    Notification:setNotifySource(previous)
    if not ok then
        require("logger").warn("kouchiyomi: rotation failed:", tostring(err))
        return false
    end
    return true
end

--[[
    A rotation happened, from anywhere.

    Ours arrive carrying the mode we had just asked for; anything else is the
    reader's own hand -- KOReader's own "Toggle orientation", the gear menu, a
    G-sensor -- and their orientation wins. It wins for as long as the page stays
    the shape it is now, so a run of spreads is left the way they just put it
    rather than being wrenched back on every turn.
--]]
function Rotation.observe(plugin, mode)
    if mode == nil or mode == plugin.rotation_set then return end
    plugin.rotation_base = nil
    plugin.rotation_set = nil
    local ui = plugin.ui
    local page = ui and ui.view and ui.view.state and ui.view.state.page
    local wide
    if page and ui.document then wide = Rotation.isWidePage(ui.document, page) end
    plugin.rotation_hold = wide
end

--- Is the wide-page rotation standing down for a page of this shape? A hold is
-- the shape the page had when the reader last turned the device themselves.
function Rotation.holds(hold, wide)
    return hold ~= nil and hold == wide
end

--- The screen's rotation right now.
function Rotation.current()
    local ok, Screen = pcall(function() return require("device").screen end)
    if not ok or not Screen or not Screen.getRotationMode then return nil end
    local got, mode = pcall(Screen.getRotationMode, Screen)
    return got and mode or nil
end

--[[
    Called as a page becomes the current one: turn the screen if the page wants
    the other orientation.

    Done here rather than before the turn on purpose: UIManager coalesces the
    repaints of one event dispatch, so rotating while the page-turn event is
    still being handled costs the one full refresh the rotation needs anyway,
    instead of a second one after the page has already been drawn.

    State lives on the plugin instance, which is exactly one document's worth:
      rotation_base  the orientation to come back to after a spread
      rotation_set   the last rotation this set, so a reader turning the device
                     themselves can be told apart from our own doing
      rotation_hold  the page shape at which the reader last turned it by hand
--]]
function Rotation.forPage(plugin, pageno)
    if plugin.settings.auto_rotate_wide_pages == false then return end
    local ui = plugin.ui
    if not ui or not ui.document or not ui.view then return end
    -- Spreads are a paged-manga idea. A webtoon read as one long strip has no
    -- page to be wide, and turning the screen mid-scroll is only disruptive.
    if ui.view.page_scroll then return end
    local now = Rotation.current()
    if now == nil then return end
    local wide = Rotation.isWidePage(ui.document, pageno)

    -- Safety net for a rotation that never reached observe(): at the very least
    -- never drag the screen back to an orientation the reader has moved off.
    if plugin.rotation_set ~= nil and now ~= plugin.rotation_set then
        plugin.rotation_base = nil
        plugin.rotation_set = nil
    end

    -- Turned by hand while the pages were this shape: leave it turned.
    if Rotation.holds(plugin.rotation_hold, wide) then return end
    plugin.rotation_hold = nil

    local want, base = Rotation.decide(now, wide, plugin.rotation_base, plugin.settings.spread_rotation)
    plugin.rotation_base = base
    if want == nil then return end
    plugin.rotation_set = want
    Rotation.apply(ui, want, true)
end

--[[
    Leaving the document: put the screen back the way the reader had it.

    Not merely tidiness -- ReaderView writes the rotation it is closing in into
    the chapter's own settings (`kopt_rotation_mode`) and restores it on the next
    open, so closing a chapter on a spread would otherwise open the next one
    sideways, and hand the file manager a sideways screen on the way out.
--]]
function Rotation.restore(plugin)
    local base = plugin.rotation_base
    plugin.rotation_base = nil
    plugin.rotation_set = nil
    plugin.rotation_hold = nil
    plugin.rotation_manual_from = nil
    if base == nil then return end
    local ui = plugin.ui
    if not ui then return end
    if Rotation.current() ~= base then
        -- Claimed first, so observe() reads this as our own doing rather than a
        -- turn by hand and leaves no hold behind on the way out.
        plugin.rotation_set = base
        Rotation.apply(ui, base, true)
        plugin.rotation_set = nil
    end
    -- Whichever way round the close handlers run, the chapter keeps the
    -- reader's orientation and not the spread's.
    pcall(function() ui.document.configurable.rotation_mode = base end)
    pcall(function() ui.doc_settings:saveSetting("kopt_rotation_mode", base) end)
end

return Rotation
