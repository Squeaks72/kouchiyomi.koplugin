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
assert(d.inverse_reading_order == true and d.kopt_page_scroll == nil, "only direction seeded by default")
assert(require("uchi/sidecar").doc_defaults.inverse_reading_order == true, "sidecar got the seed table")

-- 2. an install that had turned the old checkbox off keeps KOReader untouched
store = { auto_reading_direction = false }
p:loadSettings()
assert(p.settings.reading_direction == "off", "legacy off -> off, got " .. tostring(p.settings.reading_direction))
assert(p:wantInverseReadingOrder() == nil and next(p:docDefaults()) == nil, "off seeds nothing")

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

print("all reading-direction / chapter-default assertions passed")
