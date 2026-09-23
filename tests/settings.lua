--[[
    Offline test for the reading-direction and per-chapter doc-setting logic. No server, no device, no
    KOReader: every KOReader module main.lua pulls in is stubbed, and only Plugin:loadSettings,
    Plugin:wantInverseReadingOrder and Plugin:docDefaults are exercised for real.

    Run from the directory that HOLDS kouchiyomi.koplugin, with KOReader's own luajit (or any Lua 5.1):

        luajit kouchiyomi.koplugin/tests/settings.lua

    It covers the migration off the old `auto_reading_direction` checkbox, which is the part that cannot
    be checked by reading the code: getting it wrong silently leaves an existing install on the setting
    it was trying to move away from.
--]]
local store = {}
local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open() return setmetatable({}, LuaSettings) end
function LuaSettings:readSetting(k) return store[k] end
function LuaSettings:saveSetting(k, v) store[k] = v end
function LuaSettings:has(k) return store[k] ~= nil end
function LuaSettings:flush() end

local stub_mt
local function stub() return setmetatable({}, stub_mt) end
-- Any KOReader module we do not care about answers every call with another stub, so a widget that is
-- `extend`ed at load time still yields something indexable.
stub_mt = {
    __index = function(t, k) local f = function(...) return stub() end; rawset(t, k, f); return f end,
    __call = function(...) return stub() end,
}

local real = { ["uchi/sidecar"] = true }
local plugin_dir = "kouchiyomi.koplugin/"
table.insert(package.loaders or package.searchers, 1, function(name)
    if name == "luasettings" then return function() return LuaSettings end end
    if name == "datastorage" then return function() return { getSettingsDir = function() return "/tmp" end } end end
    if name == "gettext" then return function() return setmetatable({}, {__call = function(_, s) return s end}) end end
    local path = plugin_dir .. name:gsub("%.", "/") .. ".lua"
    local f = io.open(path)
    if f then f:close(); return assert(loadfile(path)) end
    return function() return stub() end
end)

local Plugin = dofile(plugin_dir .. "main.lua")
local p = setmetatable({}, { __index = Plugin })

-- 1. fresh install
p:loadSettings()
assert(p.settings.reading_direction == "rtl", "fresh install should default to RTL")
assert(p:wantInverseReadingOrder() == true, "RTL means inverse_reading_order")
local d = p:docDefaults()
assert(d.inverse_reading_order == true, "direction seeded by default")
assert(p.settings.chapter_view_mode == "auto", "view mode decides per series by default")
assert(d.kopt_page_scroll == nil, "an unseen series cannot be seeded a view mode")
assert(d.kopt_trim_page == nil and d.kopt_hw_dithering == nil, "the rest are left alone")
local seeded = require("uchi/sidecar").doc_defaults
assert(type(seeded) == "function", "sidecar is handed a function, since the seed depends on the series")
assert(seeded({ seriesId = "anything" }).inverse_reading_order == true, "and it answers with the defaults")

-- 2. an install that had turned the old checkbox off keeps KOReader untouched
store = { auto_reading_direction = false }
p:loadSettings()
assert(p.settings.reading_direction == "off", "legacy off -> off, got " .. tostring(p.settings.reading_direction))
assert(p:wantInverseReadingOrder() == nil, "off has no direction to seed")
assert(p:docDefaults().inverse_reading_order == nil, "and seeds none")

-- 3. an install that had it on lands on the new RTL default
store = { auto_reading_direction = true }
p:loadSettings()
assert(p.settings.reading_direction == "rtl", "legacy on -> rtl")

-- 4. auto still follows the series, and says nothing when the server says WEBTOON
store = { reading_direction = "auto" }
p:loadSettings()
assert(p:wantInverseReadingOrder("RIGHT_TO_LEFT") == true)
assert(p:wantInverseReadingOrder("LEFT_TO_RIGHT") == false)
assert(p:wantInverseReadingOrder("WEBTOON") == nil)
assert(p:wantInverseReadingOrder(nil) == nil)

-- 5. the new chapter defaults map to KOReader's own keys
store = { reading_direction = "ltr", chapter_view_mode = "page", chapter_page_crop = "none", chapter_dithering = "on" }
p:loadSettings()
d = p:docDefaults()
assert(d.inverse_reading_order == false, "ltr")
assert(d.kopt_page_scroll == 0, "page mode is kopt_page_scroll 0")
assert(d.kopt_trim_page == 3, "no crop is trim_page 3")
assert(d.kopt_hw_dithering == 1, "dithering on")
store = { chapter_view_mode = "continuous", chapter_page_crop = "auto", chapter_dithering = "off" }
p:loadSettings()
d = p:docDefaults()
assert(d.kopt_page_scroll == 1 and d.kopt_trim_page == 1 and d.kopt_hw_dithering == 0, "the other ends of each")

-- 6. interface mirroring: "match" follows the page turning, and only when there is one to follow
store = { reading_direction = "rtl", chapter_ui_mirror = "match" }
p:loadSettings()
assert(p:wantInvertUILayout() == true, "match + rtl mirrors")
assert(p:docDefaults().invert_ui_layout == true, "and is seeded")
store = { reading_direction = "ltr", chapter_ui_mirror = "match" }
p:loadSettings()
assert(p:wantInvertUILayout() == false, "match + ltr does not mirror")
store = { reading_direction = "off", chapter_ui_mirror = "match" }
p:loadSettings()
assert(p:wantInvertUILayout() == nil, "nothing to match means nothing to say")
assert(p:docDefaults().invert_ui_layout == nil, "and nothing seeded")
store = { reading_direction = "auto", chapter_ui_mirror = "match" }
p:loadSettings()
assert(p:wantInvertUILayout("RIGHT_TO_LEFT") == true, "auto still resolves per series")
assert(p:wantInvertUILayout("WEBTOON") == nil, "webtoon says nothing")
store = { chapter_ui_mirror = "off" }
p:loadSettings()
assert(p:wantInvertUILayout() == false and p:docDefaults().invert_ui_layout == false, "never mirror is explicit")
store = { chapter_ui_mirror = "leave" }
p:loadSettings()
assert(p:wantInvertUILayout() == nil, "leave alone")

-- 7. auto view mode: seeded from what an earlier chapter of that series turned out to be
store = { chapter_view_mode = "auto", long_strip_series = { webtoon = true, manga = false } }
p:loadSettings()
assert(p:docDefaults("webtoon").kopt_page_scroll == 1, "a known long-strip series scrolls")
assert(p:docDefaults("manga").kopt_page_scroll == 0, "a known page series turns")
assert(p:docDefaults("unseen").kopt_page_scroll == nil, "an unseen one says nothing")
assert(p:docDefaults().kopt_page_scroll == nil, "and so does no series at all")

-- 8. the measurement itself, against the shapes this library actually holds
local function fake_doc(count, ratios)
    return {
        getPageCount = function() return count end,
        getNativePageDimensions = function(_self, n)
            return { w = 1000, h = 1000 * (ratios[n] or ratios[#ratios]) }
        end,
    }
end
local measure = p._measureLongStrip
assert(measure(fake_doc(3, {1.41, 1.50, 1.99})) == false, "manga pages (Weeb Central's widest) are pages")
assert(measure(fake_doc(3, {13.89, 19.44, 45.63})) == true, "Toonily strips are strips")
-- The odd normal-looking page inside a long-strip chapter must not swing it, nor one tall page a manga.
assert(measure(fake_doc(3, {1.79, 20.44, 30.67})) == true, "median ignores Manhwa18's stray 1.79")
assert(measure(fake_doc(3, {1.41, 1.45, 30.00})) == false, "and ignores one stray tall page in a manga")
assert(measure(fake_doc(1, {2.49})) == false, "just under the threshold")
assert(measure(fake_doc(1, {2.50})) == true, "exactly at it")
assert(measure({}) == nil, "a document that cannot say says nothing")

print("all reading-direction / chapter-default assertions passed")
