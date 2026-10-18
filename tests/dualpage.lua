--[[
    Unit test for uchi/dualpage.lua: which pages share a landscape screen, and where a turn lands.

    Runs on a plain Lua 5.1 / LuaJIT with no KOReader and no device:
      lua5.1 tests/dualpage.lua              (from the plugin folder)

    What it is guarding: a page turn that must never lose a page. Turning forward over a pair and back again has
    to land where it started, a spread has to keep the screen to itself, and the last page of a chapter has to be
    reachable and has to end the chapter -- off by one anywhere here skips a page or strands the reader.
--]]

local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local D = require("uchi/dualpage")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

-- wide set -> the `wide` lookup the document would give
local function lookup(set, unknown)
    return function(p)
        if unknown and unknown[p] then return nil end
        return set[p] == true
    end
end
local none = lookup({})

-- 1. Wide or not.
check("a portrait page is not wide", D.isWide(0.7) == false)
check("a square-ish cover is not wide", D.isWide(1.0) == false)
check("two pages in one image is wide", D.isWide(1.43) == true)
check("unknown stays unknown", D.isWide(nil) == nil)

-- 2. How many pages share the screen.
check("two ordinary pages pair", D.span(5, 20, none) == 2)
check("the last page is alone", D.span(20, 20, none) == 1)
check("the second to last still pairs with the last", D.span(19, 20, none) == 2)
check("a spread is alone", D.span(5, 20, lookup({ [5] = true })) == 1)
check("the page before a spread is alone", D.span(4, 20, lookup({ [5] = true })) == 1)
check("a page the document will not describe is alone", D.span(5, 20, lookup({}, { [5] = true })) == 1)
check("so is one whose partner it will not describe", D.span(5, 20, lookup({}, { [6] = true })) == 1)
check("a one-page chapter", D.span(1, 1, none) == 1)

-- 3. Forward.
check("forward over a pair", D.forwardTarget(5, 20, none) == 7)
check("forward off the end announces the end", D.forwardTarget(19, 20, none) == 21)
check("forward from a lone last page", D.forwardTarget(20, 20, none) == 21)
check("forward past a spread goes one", D.forwardTarget(4, 20, lookup({ [5] = true })) == 5)

-- 4. Back, without a trail: a guess that never loses the page right behind the reader.
check("back from the first page is not ours", D.backTarget(1, none) == nil)
check("back from the second lands on the first", D.backTarget(2, none) == 1)
check("back over a pair", D.backTarget(7, none) == 5)
check("back onto a spread just behind", D.backTarget(6, lookup({ [5] = true })) == 5)
check("back with a spread two behind goes one", D.backTarget(7, lookup({ [5] = true })) == 6)
check("a trail wins over the guess", D.backTarget(7, none, 6) == 6)
check("a trail from the future is ignored", D.backTarget(7, none, 9) == 5)

-- 5. Invariants, for any layout of spreads.
local function covers(t, p, count, wide)
    -- the screen starting at t shows page p
    return t <= p and p < D.forwardTarget(t, count, wide)
end
local function layouts_ok(count, set)
    local wide = lookup(set)
    -- (a) walking forward visits every page exactly once and ends on the announced end
    local starts, p = {}, 1
    while p <= count do
        starts[#starts + 1] = p
        p = D.forwardTarget(p, count, wide)
    end
    if p ~= count + 1 then return false, "ended at " .. p end
    -- (b) with the trail, back retraces forward exactly
    for i = #starts, 2, -1 do
        if D.backTarget(starts[i], wide, starts[i - 1]) ~= starts[i - 1] then return false, "trail broke at " .. starts[i] end
    end
    -- (c) without it, from ANY page the screen landed on shows the page just behind
    for q = 2, count do
        local t = D.backTarget(q, wide)
        if not (t and t >= 1 and covers(t, q - 1, count, wide)) then return false, "lost page " .. (q - 1) .. " going back from " .. q end
    end
    return true
end
for _, case in ipairs({
    { 1, {} }, { 2, {} }, { 3, {} }, { 20, {} }, { 21, {} },
    { 20, { [5] = true } }, { 20, { [2] = true } }, { 20, { [1] = true } }, { 20, { [20] = true } },
    { 20, { [5] = true, [6] = true } }, { 21, { [8] = true, [14] = true } }, { 12, { [3] = true, [5] = true, [9] = true } },
}) do
    local ok, why = layouts_ok(case[1], case[2])
    local label = {}
    for k in pairs(case[2]) do label[#label + 1] = k end
    table.sort(label)
    check(string.format("%d pages, wide: %s", case[1], table.concat(label, ",")), ok, why)
end

-- 6. Zoom: one zoom for both pages, the pair as large as the area lets it be.
check("height-limited", math.abs(D.zoom(2000, 1000, { w = 700, h = 1000 }, { w = 700, h = 1000 }) - 1.0) < 1e-9)
check("a Kobo landscape is width-limited for two portrait pages", math.abs(D.zoom(1680, 1264, { w = 700, h = 1000 }, { w = 700, h = 1000 }) - 1.2) < 1e-9)
check("width-limited", math.abs(D.zoom(1000, 1264, { w = 700, h = 1000 }, { w = 700, h = 1000 }) - 1000 / 1400) < 1e-9)
check("the taller page sets the height", math.abs(D.zoom(5000, 1000, { w = 700, h = 800 }, { w = 700, h = 1000 }) - 1.0) < 1e-9)
check("nothing to show", D.zoom(1680, 1264, { w = 0, h = 0 }, { w = 0, h = 0 }) == nil)

-- 7. Placement: one block, centred, touching at the gutter.
local l, r = D.place(1680, 1264, { w = 800, h = 1200 }, { w = 800, h = 1200 })
check("the left page starts at the block's edge", l.x == 40)
check("the right page starts where the left ends", r.x == 840)
check("pages centre up and down", l.y == 32 and r.y == 32)
local l2, r2 = D.place(1000, 1000, { w = 400, h = 900 }, { w = 400, h = 700 })
check("a shorter page centres on its own", l2.y == 50 and r2.y == 150)
check("they still touch", r2.x == l2.x + 400)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
