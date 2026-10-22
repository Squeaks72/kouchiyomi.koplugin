--[[
    The settings tree drawn in BookOrbit's style (bookorbit.koplugin), as a page of its own.

    `Menu:createMainMenu()` is a tree of TouchMenu items; this page renders the same tree with BookOrbit's parts
    (uchi/ui_theme) -- a page header with Back, grouped cards of rows, toggle switches, radio dots, chevrons and a
    value on the right -- and gives each item the behaviour TouchMenu would, so nothing in uchi/menu.lua is
    written twice:

      * `sub_item_table` / `sub_item_table_func`  a chevron row; tapping pushes a page (built when tapped)
      * `checked_func` / `checked`               a switch, or a radio dot when the table is a pick-one list
      * `text_func`                              "Label: value" shows the value on the right, greyed
      * `help_text`                              an info button that shows it
      * `enabled_func`                           a row that is not enabled is greyed and does nothing
      * `callback`                               run with a menu shim (`updateItems`, `closeMenu`); the page closes
                                                 after it unless the item has `keep_menu_open` or is a switch
      * `is_header`, `separator`                 start a new labelled group / a new card

    Long lists are paged (arrows, swipe, page keys). Only usable when Theme.available is true.
--]]

local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

local Theme = require("uchi/ui_theme")
local Page = {}

-- A value longer than this goes on a second line under its label instead of beside it, where it would be cut.
local VALUE_BESIDE_CHARS = 18

--- "Label: value" -> label, value. Only for rows whose text is built by a function, which is where a value lives.
local function splitValue(str, item)
    if not item.text_func then return str, nil end
    local label, value = str:match("^(.-):%s+(.+)$")
    if label and value and label ~= "" then return label, value end
    return str, nil
end

local function isOn(item)
    if item.checked_func then return item.checked_func() and true or false end
    return item.checked and true or false
end

local function isEnabled(item)
    if item.select_enabled == false or item.enabled == false then return false end
    if item.enabled_func and not item.enabled_func() then return false end
    return true
end

local function labelOf(item)
    return (item.text_func and item.text_func()) or item.text or ""
end

-- ----------------------------------------------------------------- build
--- A row that only says something (a disabled line such as "When tapping a chapter:") is a heading for the rows under it.
local function isLabel(item)
    if item.sub_item_table ~= nil or item.sub_item_table_func ~= nil or item.callback or item.callback_func then return false end
    if item.checked_func or item.checked ~= nil then return false end
    return item.is_header or item.enabled == false or item.select_enabled == false
        or (item.enabled_func ~= nil and not item.enabled_func())
end

--- The level's items as blocks: { header = text } | { item = item, group = n } | { split = true }. Rows between
-- headings and splits form a group, and a group is drawn as one card.
local function blocks(items)
    local out, group = {}, 1
    for _i, item in ipairs(items) do
        if isLabel(item) then
            group = group + 1
            out[#out + 1] = { header = (labelOf(item):gsub("%s*:%s*$", "")) }
        else
            out[#out + 1] = { item = item, group = group }
            if item.separator then
                group = group + 1
                out[#out + 1] = { split = true }
            end
        end
    end
    return out
end

--- Which groups are pick-one lists: every row a choice, at least two, at most one on.
local function radioGroups(list)
    local stats, radio = {}, {}
    for _i, b in ipairs(list) do
        if b.item then
            local st = stats[b.group] or { choices = 0, on = 0, plain = false }
            stats[b.group] = st
            if b.item.checked_func or b.item.checked ~= nil then
                st.choices = st.choices + 1
                if isOn(b.item) then st.on = st.on + 1 end
            else
                st.plain = true
            end
        end
    end
    for group, st in pairs(stats) do radio[group] = not st.plain and st.choices >= 2 and st.on <= 1 end
    -- A row that says so (`radio = true`) is a radio dot whatever its neighbours are; a group where any row says so
    -- is not guessed at.
    local flagged = {}
    for _i, b in ipairs(list) do
        if b.item and b.item.radio ~= nil then flagged[b.group] = true end
    end
    return radio, flagged
end

local function rowFor(page, block, w, radio_group)
    local MenuUI, BoardUI, INK, px = Theme.MenuUI, Theme.UI, Theme.INK, Theme.px
    local item = block.item
    local enabled = isEnabled(item)
    local label, value = splitValue(labelOf(item), item)
    local o = { label = label, action = enabled and { kind = "item", item = item } or nil }
    if value then
        if #value <= VALUE_BESIDE_CHARS then o.value = value else o.sub, o.sublines, o.sub_data = value, 2, true end
    end
    local submenu = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil
    if submenu then
        o.chevron = true
    elseif item.checked_func or item.checked ~= nil then
        if radio_group then o.radio = isOn(item) else o.toggle = isOn(item) end
    end
    if item.help_text and item.help_text ~= "" then
        o.trail = BoardUI.hit(MenuUI.iconButton("info", nil, { size = 18, sw = 2 }), { kind = "help", item = item })
    end
    if not enabled then
        -- A disabled row reads as plain grey text with nothing to press.
        o.value = o.value
        o.label = label
        o.chevron, o.toggle, o.radio = nil, nil, nil
        return MenuUI.row(w, { label = label, value = o.value, sub = o.sub, sublines = o.sublines, sub_data = true })
    end
    return MenuUI.row(w, o)
end

local function build(page, sw, sh)
    local MenuUI, BoardUI, INK, px = Theme.MenuUI, Theme.UI, Theme.INK, Theme.px
    local text, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon
    local level = page.levels[#page.levels]
    local mx = MenuUI.mx()
    local cw = sw - 2 * mx
    -- A wide screen keeps the column to a readable width.
    local w = math.min(cw, px(720))
    local side = mx + math.floor((cw - w) / 2)
    local top, bottom = px(6), px(12)
    local iw = MenuUI.rowsIn(w)

    local header = MenuUI.pageHeader(w, level.title, { sub = level.sub })
    local list = blocks(level.items)
    local radio, flagged = radioGroups(list)

    -- Build every row once, so their heights can be measured to fill pages.
    local built = {}
    for index, b in ipairs(list) do
        if b.item then
            b.widget = rowFor(page, b, iw, b.item.radio == true or (radio[b.group] and not flagged[b.group]))
            b.h = b.widget:getSize().h
        elseif b.header then
            b.h = px(13) * 2 + px(8)
        else
            b.h = px(12)
        end
        built[index] = b
    end

    local footer_h = px(52)
    local avail = sh - top - bottom - px(64) - px(8)
    -- Which blocks land on which page (a page leaves room for the footer once there is more than one).
    local pages, cur, used = {}, {}, 0
    local limit = avail - footer_h
    for _i, b in ipairs(built) do
        local card_chrome = px(4)
        if used + b.h + card_chrome > limit and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = b
        used = used + b.h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    if #pages <= 1 then
        pages = { built }
        footer_h = 0
    end
    page.page_count = #pages
    level.page = math.max(1, math.min(level.page or 1, #pages))
    local shown = pages[level.page] or {}

    -- Group into cards: a header or a split starts a new one.
    local children = { header, space(nil, px(8)) }
    local group, label = {}, nil
    local function flush()
        if #group > 0 then
            if label then table.insert(children, MenuUI.label(w, label)); table.insert(children, space(nil, px(8))) end
            table.insert(children, MenuUI.group(w, group))
            table.insert(children, space(nil, px(14)))
        end
        group, label = {}, nil
    end
    for _i, b in ipairs(shown) do
        if b.header then flush(); label = b.header
        elseif b.split then flush()
        else group[#group + 1] = b.widget end
    end
    flush()
    if #shown == 0 then
        table.insert(children, text(page.plugin.i18n._("Nothing here."), { s = 14, col = INK.g4, w = w }))
    end

    if footer_h > 0 then
        table.insert(children, flex(px(8)))
        table.insert(children, hstack({ w = w, h = footer_h }, {
            level.page > 1 and MenuUI.iconButton("chevron-left", { kind = "page", delta = -1 }, { size = 24 }) or space(px(44), 1),
            flex(0),
            text(string.format("%d / %d", level.page, #pages), { s = 14, col = INK.g4 }),
            flex(0),
            level.page < #pages and MenuUI.iconButton("chevron-right", { kind = "page", delta = 1 }, { size = 24 }) or space(px(44), 1),
        }))
    end
    page.panel_rect = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    return vstack({ w = sw, h = sh, pad = { top, side, bottom, side } }, children)
end

-- --------------------------------------------------------------- actions
--- What the tree's callbacks are handed in place of a TouchMenu.
local function shimFor(page)
    return {
        updateItems = function() if not page.closed then page:refresh() end end,
        closeMenu = function() page:close() end,
        item_table = page.levels[#page.levels].items,
    }
end

local function pushLevel(page, item)
    local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
    if type(sub) ~= "table" or #sub == 0 then return end
    local label = splitValue(labelOf(item), item)
    table.insert(page.levels, { title = label, sub = page.levels[#page.levels].title, items = sub, page = 1 })
    page:refresh()
end

local function onAction(page, action)
    if action.kind == "page" then
        local level = page.levels[#page.levels]
        level.page = math.max(1, math.min((level.page or 1) + action.delta, page.page_count or 1))
        page:refresh()
    elseif action.kind == "help" then
        local item = action.item
        local TextViewer = require("ui/widget/textviewer")
        UIManager:show(TextViewer:new{ title = (splitValue(labelOf(item), item)), text = item.help_text })
    elseif action.kind == "item" then
        local item = action.item
        -- A row with a page of its own (the tap zones' pictures) opens that; the plain submenu is its fallback.
        if item.custom_page == "tapzones" then
            local ok, opened = pcall(function() return require("uchi/ui_tapzones_page").open(page.plugin) end)
            if ok and opened then return true end
        end
        if item.sub_item_table ~= nil or item.sub_item_table_func ~= nil then
            return pushLevel(page, item)
        end
        local callback = item.callback_func and item.callback_func() or item.callback
        if not callback then return end
        callback(shimFor(page))
        if page.closed then return end
        if item.checked_func or item.checked ~= nil or item.keep_menu_open then
            page:refresh()
        else
            page:close()
        end
    end
    return true
end

local function onBack(page)
    if #page.levels > 1 then
        table.remove(page.levels)
        page:refresh()
        return true
    end
    return false
end

local function onSwipe(page, ges)
    local dir = ges and ges.direction
    if dir == "west" then onAction(page, { kind = "page", delta = 1 }); return true end
    if dir == "east" then onAction(page, { kind = "page", delta = -1 }); return true end
    return false
end

--- Open the settings. `open_index` opens that top-level row's submenu at once.
function Page.open(plugin, open_index)
    if not (Theme.available and plugin and plugin.menu and plugin.menu.createMainMenu) then return false end
    local items = plugin.menu:createMainMenu()
    local version
    if plugin.updater and plugin.updater.localVersion then version = plugin.updater:localVersion() end
    local page = Theme.MenuPage:new{
        name = "kouchiyomi_settings",
        build = build,
        on_action = onAction,
        on_back = onBack,
        on_swipe = onSwipe,
        on_page_key = function(p, delta) onAction(p, { kind = "page", delta = delta }) end,
        plugin = plugin,
        levels = { { title = plugin.i18n._("Uchiyomi"), sub = version and ("kouchiyomi " .. version) or nil, items = items, page = 1 } },
    }
    UIManager:show(page, "ui")
    if open_index and items[open_index] then pushLevel(page, items[open_index]) end
    return true
end

return Page
