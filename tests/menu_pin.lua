-- The menu-bar tab and the menu-order files it lives in, against stubs (no KOReader needed).
local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p " .. dir)
local function ser(v, indent)
    indent = indent or ""
    if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = indent .. "  [" .. ser(k) .. "] = " .. ser(v[k], indent .. "  ") end
    return "{\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "}"
end
package.loaded["datastorage"] = { getSettingsDir = function() return dir end }
package.loaded["libs/libkoreader-lfs"] = { attributes = function(p) local f = io.open(p); if f then f:close(); return { mode = "file" } end end }
package.loaded["util"] = {
    readFromFile = function(p) local f = io.open(p); if not f then return nil end local s = f:read("*a"); f:close(); return s end,
    writeToFile = function(s, p) local f = io.open(p, "w"); f:write(s); f:close(); return true end,
}
package.loaded["dump"] = function(v) return "return " .. ser(v) .. "\n" end
package.loaded["logger"] = { warn = function() end, info = function() end }
local function bundled(buttons) return { ["KOMenu:menu_buttons"] = buttons, tools = { "a", "b" } } end
package.loaded["ui/elements/reader_menu_order"] = bundled({ "navi", "tools", "filemanager", "main" })
package.loaded["ui/elements/filemanager_menu_order"] = bundled({ "setting", "tools", "main" })

local function fresh() package.loaded["uchi/menu_pin"] = nil; return require("uchi/menu_pin") end
local function read(prefix) return dofile(dir .. "/" .. prefix .. "_menu_order.lua") end
local function write(prefix, s) local f = io.open(dir .. "/" .. prefix .. "_menu_order.lua", "w"); f:write(s); f:close() end
local function wipe() os.execute("rm -f " .. dir .. "/*.lua") end
local function join(t) return table.concat(t, ",") end

-- normalizeButtons
local Pin = fresh()
check("before main", join(Pin.normalizeButtons({ "navi", "main" }, true)) == "navi,kouchiyomi_tab,main")
check("before BookOrbit's tab", join(Pin.normalizeButtons({ "navi", "bookorbit_tab", "main" }, true)) == "navi,kouchiyomi_tab,bookorbit_tab,main")
check("never twice", join(Pin.normalizeButtons({ "navi", "kouchiyomi_tab", "main" }, true)) == "navi,kouchiyomi_tab,main")
check("removed", join(Pin.normalizeButtons({ "navi", "kouchiyomi_tab", "main" }, false)) == "navi,main")

-- no file: written from the bundled row, with the tab key
wipe(); Pin = fresh(); Pin.ensure(true)
local o = read("reader")
check("reader file made", join(o["KOMenu:menu_buttons"]) == "navi,tools,filemanager,kouchiyomi_tab,main", join(o["KOMenu:menu_buttons"] or {}))
check("tab has its order list", type(o.kouchiyomi_tab) == "table")
check("file manager too", join(read("filemanager")["KOMenu:menu_buttons"]) == "setting,tools,kouchiyomi_tab,main")
check("bundled keys are not copied over", o.tools == nil)

-- off with no file: nothing created
wipe(); Pin = fresh(); Pin.ensure(false)
check("off writes nothing", io.open(dir .. "/reader_menu_order.lua") == nil)

-- refresh removes the tab again
wipe(); Pin = fresh(); Pin.ensure(true); Pin.refresh(false)
check("refresh off removes it", join(read("reader")["KOMenu:menu_buttons"]) == "navi,tools,filemanager,main" and read("reader").kouchiyomi_tab == nil)

-- a file BookOrbit generated: edited in place, its keys kept, its marker dropped so it stops regenerating it
wipe()
write("reader", "-- bookorbit-menu-pin v3 (generated; delete this file to reset menu order)\nreturn " .. ser({
    ["KOMenu:menu_buttons"] = { "navi", "tools", "filemanager", "bookorbit_tab", "main" },
    bookorbit_tab = {}, tools = { "a", "bookorbit", "b" },
}) .. "\n")
Pin = fresh(); Pin.ensure(true)
o = read("reader")
check("BookOrbit's tab kept, ours before it", join(o["KOMenu:menu_buttons"]) == "navi,tools,filemanager,kouchiyomi_tab,bookorbit_tab,main", join(o["KOMenu:menu_buttons"]))
check("BookOrbit's other keys kept", o.bookorbit_tab ~= nil and join(o.tools) == "a,bookorbit,b")
local f = io.open(dir .. "/reader_menu_order.lua"); local text = f:read("*a"); f:close()
check("marker dropped", not text:find("bookorbit-menu-pin", 1, true))

-- already right: not rewritten
local before = io.open(dir .. "/reader_menu_order.lua"):read("*a")
Pin = fresh(); Pin.ensure(true)
check("idempotent", io.open(dir .. "/reader_menu_order.lua"):read("*a") == before)

-- an unreadable file is left alone
write("reader", "this is not lua {{{")
Pin = fresh(); Pin.ensure(true)
check("garbage left alone", io.open(dir .. "/reader_menu_order.lua"):read("*a") == "this is not lua {{{")

os.execute("rm -rf " .. dir)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
