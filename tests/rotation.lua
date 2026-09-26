--[[
    Unit test for uchi/rotation.lua: which way the screen should be for a page.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no device:
      lua5.1 tests/rotation.lua              (from the plugin folder)

    What it is guarding: a rule that moves the screen under the reader's hands.
    Getting it wrong is not a cosmetic bug -- it either leaves a spread as two
    postage stamps, or it keeps wrenching the screen away from someone who has
    just turned the device themselves. The orientation constants are KOReader's
    (0 upright, 1 CW, 2 upside down, 3 CCW), so "portrait" is two modes, not one,
    and every rule here has to hold for both.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local R = require("uchi/rotation")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local UR, CW, UD, CCW = 0, 1, 2, 3

-- 1. Which modes are which way up. Both portraits and both landscapes.
check("upright is portrait", R.isPortrait(UR) == true)
check("upside down is portrait too", R.isPortrait(UD) == true)
check("clockwise is not", R.isPortrait(CW) == false)
check("counter-clockwise is not", R.isPortrait(CCW) == false)

-- 2. The swap keeps which way up the device is, exactly as KOReader's own
--    toggle does -- upside-down portrait pairs with counter-clockwise, not with
--    clockwise, or a reader holding the device the other way gets it upside down.
check("upright swaps to clockwise", R.swap(UR) == CW)
check("clockwise swaps back to upright", R.swap(CW) == UR)
check("upside down swaps to counter-clockwise", R.swap(UD) == CCW)
check("counter-clockwise swaps back to upside down", R.swap(CCW) == UD)
check("swapping twice is where you started", R.swap(R.swap(UD)) == UD)

-- 3. A spread on an upright screen turns it, and remembers what to come back to.
local want, base = R.decide(UR, true, nil)
check("a spread turns the screen", want == CW, want)
check("and remembers the way back", base == UR, base)
want, base = R.decide(UD, true, nil)
check("from the other portrait it turns the other way", want == CCW, want)
check("remembering that portrait", base == UD, base)

-- 4. A spread while already landscape changes nothing.
want, base = R.decide(CW, true, nil)
check("a spread in landscape stays put", want == nil, want)
check("and claims no way back", base == nil, base)

-- 5. A single page turns the screen back, once, to where it came from.
want, base = R.decide(CW, false, UR)
check("a single page turns it back", want == UR, want)
check("and the claim is released", base == nil, base)
want, base = R.decide(UR, false, nil)
check("a single page with no claim stays put", want == nil, want)
check("still no claim", base == nil, base)

-- 6. The reader's own hand wins: with no claim of ours, a single page never
--    drags the screen out of the landscape they chose.
want = R.decide(CW, false, nil)
check("landscape by hand is left alone", want == nil, want)
want = R.decide(CCW, false, nil)
check("the other landscape too", want == nil, want)

-- 7. Already back where the claim points: nothing to do, and the claim goes.
want, base = R.decide(UR, false, UR)
check("a stale claim moves nothing", want == nil, want)
check("but is cleared", base == nil, base)

-- 8. A document that will not say how big its pages are must not move anything,
--    and must not lose a claim that is still standing.
want, base = R.decide(CW, nil, UR)
check("an unknown page stays put", want == nil, want)
check("and keeps the way back", base == UR, base)

-- 9. The spread threshold, against the shapes this library actually has: a
--    manga page ~0.7 w/h, a squarish cover ~1.0, two pages side by side ~1.43.
local function wide(aspect)
    return R.isWidePage({ getNativePageDimensions = function(_self, _p) return { w = aspect * 1000, h = 1000 } end }, 1)
end
check("a manga page is not wide", wide(0.70) == false)
check("a square cover is not wide", wide(1.00) == false)
check("a slightly wide illustration is not either", wide(1.15) == false)
check("two pages side by side are", wide(1.43) == true)
check("a wide panorama is", wide(2.00) == true)

-- 10. A document with no dimensions to give says nothing, rather than "no".
check("no document, no answer", R.isWidePage(nil, 1) == nil)
check("no page number, no answer", R.isWidePage({ getNativePageDimensions = function() end }, nil) == nil)
check("a page that fails to load says nothing",
      R.isWidePage({ getNativePageDimensions = function() error("boom") end }, 1) == nil)
check("zero-sized pages say nothing",
      R.isWidePage({ getNativePageDimensions = function() return { w = 0, h = 0 } end }, 1) == nil)

-- ---------------------------------------------------------------------------
-- Which landscape, when the direction is a preference
-- ---------------------------------------------------------------------------

-- 14. Forced directions are exactly that, from either portrait.
check("clockwise forced from upright", R.landscapeFor(UR, "cw") == CW)
check("clockwise forced from upside down", R.landscapeFor(UD, "cw") == CW)
check("counter-clockwise forced from upright", R.landscapeFor(UR, "ccw") == CCW)
check("counter-clockwise forced from upside down", R.landscapeFor(UD, "ccw") == CCW)

-- "follow" is KOReader's rule, and is what an unset or unknown value means, so
-- an old settings file (or a typo in one) reads as the behaviour that shipped.
check("follow keeps which way up", R.landscapeFor(UR, "follow") == CW)
check("follow from the other portrait", R.landscapeFor(UD, "follow") == CCW)
check("no preference means follow", R.landscapeFor(UD, nil) == CCW)
check("nonsense means follow", R.landscapeFor(UD, "sideways") == CCW)
check("already landscape is left as it is", R.landscapeFor(CCW, "follow") == CCW)

-- 15. The rule the preference feeds into: a spread turns the preferred way...
want, base = R.decide(UR, true, nil, "ccw")
check("a spread turns counter-clockwise when asked", want == CCW, want)
check("remembering the upright it came from", base == UR, base)

-- ...and the way back is that remembered upright, never derived from the
-- landscape. Deriving it would land a forced counter-clockwise on upside-down
-- portrait, which is the screen the right way round for nobody.
want, base = R.decide(CCW, false, UR, "ccw")
check("and comes back to that upright, not upside down", want == UR, want)
check("releasing the claim", base == nil, base)

-- 16. A toggle by hand honours the preference too, and knows its own way back.
want, base = R.toggleTo(UR, "ccw", nil)
check("a hand toggle turns the preferred way", want == CCW, want)
check("and remembers where from", base == UR, base)
want, base = R.toggleTo(CCW, "ccw", UR)
check("toggling back returns to that upright", want == UR, want)
check("and forgets it", base == nil, base)
-- Nothing remembered (the screen was already landscape when the chapter opened):
-- KOReader's own swap is the only sensible answer left.
want = R.toggleTo(CW, "ccw", nil)
check("with nothing remembered it falls back to a swap", want == UR, want)
check("from the other landscape too", R.toggleTo(CCW, "cw", nil) == UD)
-- With no preference set, a toggle is exactly KOReader's toggle.
check("follow toggles like KOReader out", R.toggleTo(UR, "follow", nil) == CW)
check("follow toggles like KOReader back", R.toggleTo(CW, "follow", UR) == UR)

-- ---------------------------------------------------------------------------
-- Standing down when the reader turns the device themselves
-- ---------------------------------------------------------------------------

--- A stand-in for the plugin: one document's worth of state, plus just enough
-- of the reader to say which page is on screen and what shape it is.
local function fake_plugin(page, aspect)
    return {
        rotation_base = nil, rotation_set = nil, rotation_hold = nil,
        ui = {
            view = { state = { page = page } },
            document = { getNativePageDimensions = function() return { w = aspect * 1000, h = 1000 } end },
        },
    }
end

-- 11. A rotation this module asked for is its own doing and changes nothing.
local p = fake_plugin(5, 1.43)
p.rotation_set, p.rotation_base = CW, UR
R.observe(p, CW)
check("our own rotation is not an override", p.rotation_set == CW and p.rotation_base == UR)
check("and sets no hold", p.rotation_hold == nil, p.rotation_hold)

-- 12. A rotation from anywhere else drops our claim and holds at the shape of
--     the page the reader was looking at when they did it.
p = fake_plugin(5, 1.43)
p.rotation_set, p.rotation_base = CW, UR
R.observe(p, UR)
check("a hand-turned screen drops the claim", p.rotation_base == nil and p.rotation_set == nil)
check("and holds at a wide page", p.rotation_hold == true, p.rotation_hold)

p = fake_plugin(5, 0.70)
R.observe(p, CW)
check("holding at a single page too", p.rotation_hold == false, p.rotation_hold)

-- A document that cannot say leaves no hold rather than a wrong one.
p = { ui = { view = { state = { page = 5 } }, document = { getNativePageDimensions = function() end } } }
R.observe(p, CW)
check("no shape, no hold", p.rotation_hold == nil, p.rotation_hold)
p = { ui = nil }
R.observe(p, CW)
check("no reader, no hold", p.rotation_hold == nil, p.rotation_hold)

-- 13. What a hold means: while the pages stay that shape, the reader's
--     orientation stands. This is the rule that stops a run of spreads being
--     wrenched back to landscape on every single turn.
check("a hold at wide holds through the spreads", R.holds(true, true) == true)
check("and lets go at the first single page", R.holds(true, false) == false)
check("a hold at single holds through the singles", R.holds(false, false) == true)
check("and lets go at the first spread", R.holds(false, true) == false)
check("no hold never holds", R.holds(nil, true) == false)
check("not even against an unknown page", R.holds(nil, nil) == false)
-- An unknown page shape must not be read as "the same shape" and freeze a hold
-- that should have been let go of.
check("an unknown page does not satisfy a hold", R.holds(true, nil) == false)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
