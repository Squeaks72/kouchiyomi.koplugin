--[[
    Where a tap turns the page.

    KOReader decides it for a document: a "forward" zone and a "backward" zone, the pair mirrored for a book set
    to right-to-left. The streaming viewer is a different widget (an ImageViewer) that never heard of any of it:
    its left third is always "previous", whichever way the chapter reads. These settings put both on one rule and
    let it be changed per reading style:

      * `tap_next_side_rtl` / `tap_next_side_ltr`   "auto" | "left" | "right": the side the next page is on for a
                                                    right-to-left (manga) or left-to-right chapter. Auto is the
                                                    natural one -- left for right-to-left, right for left-to-right.
      * `tap_next_width`                            nil | 0.25 .. 0.75: how much of the screen turns forward; the
                                                    rest turns back. Nil leaves the stock sizes.

    With neither set a downloaded chapter keeps KOReader's own zones untouched (including whatever zone layout is
    chosen in KOReader's own menu); only streaming changes, from "always left-to-right" to following the direction.
--]]

local Tap = {}

Tap.WIDTHS = { 0.25, 0.33, 0.5, 0.66, 0.75 }

--- "left" | "right": which side the next page is on.
function Tap.side(settings, rtl)
    local v = settings[rtl and "tap_next_side_rtl" or "tap_next_side_ltr"]
    if v == "left" or v == "right" then return v end
    return rtl and "left" or "right"
end

local function width_of(settings, default)
    local w = tonumber(settings.tap_next_width)
    if not w then return default, false end
    return math.max(0.1, math.min(0.9, w)), true
end

--- Has anything been chosen that KOReader's own zones would not do?
function Tap.customised(settings, rtl)
    local v = settings[rtl and "tap_next_side_rtl" or "tap_next_side_ltr"]
    if v == "left" or v == "right" then return true end
    return tonumber(settings.tap_next_width) ~= nil
end

local function zone(x, w) return { ratio_x = x, ratio_y = 0, ratio_w = w, ratio_h = 1 } end

--- The forward and backward zones of a document, in KOReader's own shape. 3/4 forward is its default width.
function Tap.zones(settings, rtl)
    local w = width_of(settings, 3 / 4)
    if Tap.side(settings, rtl) == "left" then return zone(0, w), zone(w, 1 - w) end
    return zone(1 - w, w), zone(0, 1 - w)
end

--- What a tap does in the streaming viewer: "next", "prev" or "middle" (which shows or hides its buttons).
-- `x` is the tap's place across the screen, 0 to 1. Out of the box the screen is thirds with the middle one
-- left for the buttons, as ImageViewer has it; choosing a width gives the whole screen to the two zones.
function Tap.streamTarget(settings, rtl, x)
    local w, chosen = width_of(settings, 1 / 3)
    local next_left = Tap.side(settings, rtl) == "left"
    local prev_w = chosen and (1 - w) or (1 / 3)
    if next_left then
        if x < w then return "next" end
        if x >= 1 - prev_w then return "prev" end
    else
        if x >= 1 - w then return "next" end
        if x < prev_w then return "prev" end
    end
    return "middle"
end

--- Put the document's tap zones under these settings. The hook costs nothing until a choice is made.
function Tap.install(plugin, ui)
    local view = ui and ui.view
    if not view or view._kouchiyomi_tap_hooked or type(view.getTapZones) ~= "function" then return end
    view._kouchiyomi_tap_hooked = true
    local orig = view.getTapZones
    view.getTapZones = function(this, ...)
        local forward, backward = orig(this, ...)
        if not plugin.current_book_id then return forward, backward end
        local ok, BD = pcall(require, "ui/bidi")
        -- KOReader's own test for a mirrored reading order
        local rtl = this.inverse_reading_order == true
        if ok and BD and BD.mirroredUILayout and BD.mirroredUILayout() then rtl = not rtl end
        if not Tap.customised(plugin.settings, rtl) then return forward, backward end
        return Tap.zones(plugin.settings, rtl)
    end
    -- The zones were registered before this hook existed.
    if type(view.setupTouchZones) == "function" then pcall(view.setupTouchZones, view) end
end

--- Re-register the open document's zones (after a setting changed).
function Tap.refresh(plugin)
    local view = plugin and plugin.ui and plugin.ui.view
    if view and type(view.setupTouchZones) == "function" then pcall(view.setupTouchZones, view) end
end

return Tap
