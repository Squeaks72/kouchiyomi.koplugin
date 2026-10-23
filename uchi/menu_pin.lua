--[[
    Puts Uchiyomi's icon in KOReader's top menu bar (the row of tabs: navigation, settings, tools, ... main menu),
    in the reader and in the file browser, by maintaining the user menu-order override files -- the way BookOrbit
    (bookorbit.koplugin) puts its own icon there.

    KOReader merges <settings>/<prefix>_menu_order.lua over its bundled order table per top-level key, and a button
    only counts as a tab when it has an order list of its own, so the override carries two keys: the button row with
    our tab id in it, and `kouchiyomi_tab = {}`.

    BookOrbit keeps the SAME two files. It marks the ones it generated with a comment on the first line and rewrites
    those from KOReader's bundled order at every start, which would silently drop our tab. So we never write a
    generated file of our own: an existing file is parsed and edited in place (other plugins' keys and tabs are kept),
    and its first-line marker is dropped, which makes BookOrbit treat it as hand-kept and only touch its own ids. Our
    tab goes just before BookOrbit's when that is there, else just before the main menu. Whichever plugin starts
    first, the file converges to the same content.
--]]

local TAB_ID = "kouchiyomi_tab"
local BUTTONS = "KOMenu:menu_buttons"
local OTHER_TAB_BEFORE = "bookorbit_tab"

local PREFIXES = {
    { prefix = "reader", order_module = "ui/elements/reader_menu_order" },
    { prefix = "filemanager", order_module = "ui/elements/filemanager_menu_order" },
}

local Pin = { done = false, tab = true }

local function removeId(list, id)
    local removed = false
    for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i); removed = true end
    end
    return removed
end

local function copyList(list)
    local out = {}
    for _i, v in ipairs(list) do out[#out + 1] = v end
    return out
end

--- The button row with our tab in it (or without). Exposed for the tests.
function Pin.normalizeButtons(buttons, with_tab)
    removeId(buttons, TAB_ID)
    if not with_tab then return buttons end
    local at
    for i, id in ipairs(buttons) do
        if id == OTHER_TAB_BEFORE then at = i; break end
    end
    if not at then
        for i, id in ipairs(buttons) do
            if id == "main" then at = i; break end
        end
    end
    table.insert(buttons, at or (#buttons + 1), TAB_ID)
    return buttons
end

local function settingsPath(prefix)
    return require("datastorage"):getSettingsDir() .. "/" .. prefix .. "_menu_order.lua"
end

local function ensureOne(prefix, order_module, with_tab)
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    local dump = require("dump")
    local logger = require("logger")
    local path = settingsPath(prefix)

    local bundled = require(order_module)
    if type(bundled) ~= "table" or type(bundled[BUTTONS]) ~= "table" then return end

    local existing, user
    if lfs.attributes(path) then
        existing = util.readFromFile(path, "r")
        if not existing then
            logger.warn("kouchiyomi: cannot read menu order file, leaving it alone:", path)
            return
        end
        local ok, parsed = pcall(dofile, path)
        if not ok or type(parsed) ~= "table" then
            logger.warn("kouchiyomi: cannot parse menu order file, leaving it alone:", path)
            return
        end
        user = parsed
    else
        -- Nothing to remove and nothing to add: leave KOReader's own order alone.
        if not with_tab then return end
        user = {}
    end

    if type(user[BUTTONS]) ~= "table" then
        if not with_tab then return end
        user[BUTTONS] = copyList(bundled[BUTTONS])
    end
    Pin.normalizeButtons(user[BUTTONS], with_tab)
    user[TAB_ID] = with_tab and {} or nil

    local content = dump(user, nil, true)
    if existing == content then return end
    local ok, err = util.writeToFile(content, path, true, true)
    if not ok then logger.warn("kouchiyomi: cannot write menu order file", path, err) end
end

local function ensureAll(with_tab)
    for _i, entry in ipairs(PREFIXES) do
        local ok, err = pcall(ensureOne, entry.prefix, entry.order_module, with_tab)
        if not ok then require("logger").warn("kouchiyomi: menu pin failed for", entry.prefix, err) end
    end
end

--- Once per start: make the files say what the setting says.
function Pin.ensure(with_tab)
    if Pin.done then return end
    Pin.done = true
    if with_tab ~= nil then Pin.tab = with_tab end
    ensureAll(Pin.tab)
end

--- After the setting changes.
function Pin.refresh(with_tab)
    Pin.tab = with_tab ~= false
    Pin.done = true
    ensureAll(Pin.tab)
end

return Pin
