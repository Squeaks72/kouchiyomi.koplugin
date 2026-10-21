--[[
    A BookOrbit-styled replacement for the stock-Menu-based catalogue page
    (uchi/list_menu.lua / uchi/grid_menu.lua), used by uchi/browser.lua only
    when uchi/ui_theme's Theme.available is true.

    All of browser.lua's data, pagination and navigation logic
    (pushCatalog/_loadCatalog/onReturn/the show* methods, the dialogs they
    open) is unchanged by this file -- it only replaces how one page of
    item_table entries is painted and how taps/holds on them are routed.
    Deliberately does NOT subclass BookOrbit's MenuPage: that widget has no
    hold gesture (BookOrbit's own pages do not need one), and kouchiyomi's
    browser depends on long-press for series/chapter actions, so this is its
    own small InputContainer, built the same way MenuPage is (collectHits +
    hitAt), with Tap, Hold and Swipe all wired up. It talks to BookOrbit only
    through the plain function tables in uchi/ui_theme.lua.

    The Home screen (uchi/browser.lua's getHomeItemTable, #paths == 0) gets
    its own layout: a search bar, then each of its sections (Keep reading,
    each configured home list, Browse) as either a horizontally-paged shelf
    of cover cards or a grid of nav tiles, grouped from the flat item_table
    by its `is_header` markers -- see _homeSections/sectionKind below.
    Every other page (series lists, chapter lists, search results, the
    offline library) is the plain paged grid/list from before.

    Public surface a subclass (UchiBrowser) can rely on, matching what the
    stock Menu class already provided: item_table, title, page, page_num,
    perpage, view_mode, columns, grid_rows, close_callback, paths,
    switchItemTable(title, item_table), updateItems(select_number),
    _recalculateDimen(), onMenuSelect(item), onMenuHold(item). Also:
    header_show_menu / header_menu_action, which uchi/browser.lua's
    toggleTitleButtons sets so the header's "..." icon opens the same
    series/chapter actions sheet the stock title bar button does.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Theme = require("uchi/ui_theme")
local UI = Theme.UI
local INK = Theme.INK
local px = Theme.px

local Cards = require("uchi/ui_cards")

local Screen = Device.screen

local HEADER_H = 56
local HOME_HEADER_H = 90
local FOOTER_H = 40
local MARGIN = 16
local SECTION_GAP = px(6)
local BAR_H = px(50)
local TILE_ROW_H = px(104)
local CARD_W = px(92)

-- A shelf card's height: a 2:3 cover plus its caption below it, the same
-- proportions Cards.cell draws (see uchi/ui_cards.lua) -- kept to Cards'
-- own caption-sizing constants so the two never drift apart. has_sub: does
-- this shelf's caption need a second line (e.g. "N unread") under the
-- title, or just the title (e.g. Keep reading, whose progress is on the
-- cover's own badge) -- the single-line case gives its cover the room back.
local function cardHeight(has_sub)
    local cap_h = Theme.lh1(Cards.CAP_TITLE_S) + (has_sub and (Cards.CAP_GAP + Theme.lh1(Cards.CAP_SUB_S)) or 0)
    return math.floor(CARD_W * 3 / 2 + 0.5) + Cards.COVER_GAP + cap_h
end

-- Icons for the home screen's non-tile notice bars, by the `kind` tag
-- uchi/browser.lua attaches (see getHomeItemTable).
local BAR_ICONS = {
    ["sync-pending"] = "cloud",
    scope = "list-filter",
    reconnect = "wifi-off",
    note = "info",
}

-- A comfortable (~40dp, or smaller for the tighter shelf title rows) tap
-- box around an icon -- a bare icon widget's own bounds make a cramped,
-- hard-to-hit target. Every tappable chevron/close/menu glyph goes through
-- this instead of wrapping UI.icon in UI.hit directly.
local function iconButton(name, action, o)
    o = o or {}
    local box = px(o.box or 40)
    local ic = UI.icon(name, px(o.size or 18), { sw = o.sw or 2.25, col = o.col })
    local body = UI.hstack({ w = box, h = box, valign = "center" }, { UI.flex(0), ic, UI.flex(0) })
    return action and UI.hit(body, action) or body
end

local BoardMenu = InputContainer:extend{
    is_interactive = true,
    plugin = nil,
    item_table = nil,
    title = "",
    paths = nil,
    page = 1,
    page_num = 1,
    perpage = 1,
    view_mode = "list",
    columns = 3,
    grid_rows = 3,
    close_callback = nil,
    header_show_menu = false,
    header_menu_action = nil,
    _shelf_page = nil,
    _shelf_bounds = nil,
    _home_page = 1,
    _home_page_num = 1,
}

function BoardMenu:init()
    self.item_table = self.item_table or {}
    self.paths = self.paths or {}
    self._shelf_page = self._shelf_page or {}
    self._shelf_bounds = self._shelf_bounds or {}
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapPage = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldPage = { GestureRange:new{ ges = "hold", range = self.dimen } },
        SwipePage = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { ClosePage = { { Device.input.group.Back } } }
    end
    self:_recalculateDimen()
    self:rebuild()
end

function BoardMenu:_ctx()
    local gettext = self.plugin and self.plugin.i18n and self.plugin.i18n._ or function(s) return s end
    return { plugin = self.plugin, selected_books = self.selected_books, _ = gettext }
end

function BoardMenu:_isHome()
    return #(self.paths or {}) == 0
end

-- --------------------------------------------------------------- layout
-- Mirrors uchi/browser.lua's own getPageSize() exactly, so the number of
-- entries a page asks the server/filter for always matches how many this
-- renderer actually has room to show. Not used on Home, which lays its
-- sections out directly instead of paging item_table.
function BoardMenu:_bodyGeometry()
    local w, h = self.dimen.w, self.dimen.h
    local mx = px(MARGIN)
    return w - 2 * mx, h - px(HEADER_H) - px(FOOTER_H), mx
end

function BoardMenu:_hasCovers()
    for _i, item in ipairs(self.item_table or {}) do
        if item.cover_id then return true end
    end
    return false
end

function BoardMenu:_listRows()
    return (self.plugin and self.plugin.settings and self.plugin.settings.list_rows) or 5
end

-- Covered entries (chapters, series) always grid -- a thumbnail-left,
-- title-beside-it list row is the one layout we never want back. Only
-- entries with nothing to show a cover for (Libraries, Bookmarks, plain nav
-- rows) fall back to text rows.
function BoardMenu:_gridMode()
    return self:_hasCovers()
end

function BoardMenu:_recalculateDimen()
    if self:_isHome() then return end
    local body_w, body_h = self:_bodyGeometry()
    if self:_gridMode() then
        local cols = self.columns or 3
        local rows = self.grid_rows or 3
        self.perpage = cols * rows
        self._row_h = math.max(px(20), math.floor(body_h / rows))
        self._col_w = math.max(px(20), math.floor(body_w / cols))
    else
        -- No covers to show at all (Libraries, Bookmarks, plain nav rows):
        -- fits more rows per page than a cover row would need.
        local rows = math.max(6, self:_listRows())
        self.perpage = rows
        self._row_h = math.max(px(20), math.floor(body_h / rows))
        self._col_w = body_w
    end
    self.page_num = math.max(1, math.ceil(#(self.item_table or {}) / math.max(1, self.perpage)))
    if self.page > self.page_num then self.page = self.page_num end
    if self.page < 1 then self.page = 1 end
end

-- ----------------------------------------------------------- sub-page chrome
function BoardMenu:_header(w)
    local back = #(self.paths or {}) > 0
    local box = px(40)
    local items = {}
    if back then
        table.insert(items, iconButton("chevron-left", { kind = "back" }, { size = 22 }))
    end
    local back_w = back and box or 0
    local menu_w = self.header_show_menu and box or 0
    local title_w = math.max(px(10), w - back_w - 2 * box - menu_w - px(4))
    table.insert(items, UI.text(self.title or "", { s = 19, b = true, w = title_w, data = true }))
    table.insert(items, UI.flex(0))
    if self.header_show_menu then
        table.insert(items, iconButton("ellipsis", { kind = "menu" }, { size = 20 }))
    end
    table.insert(items, iconButton("sliders-horizontal", { kind = "settings" }, { size = 20 }))
    table.insert(items, iconButton("x", { kind = "close" }, { size = 20 }))
    return UI.hstack({ w = w, h = px(HEADER_H), valign = "center" }, items)
end

function BoardMenu:_footer(w)
    local h = px(FOOTER_H)
    if self.page_num <= 1 then return UI.space(w, h) end
    local can_prev, can_next = self.page > 1, self.page < self.page_num
    local left = iconButton("chevron-left", can_prev and { kind = "page", delta = -1 } or nil, { size = 20, col = not can_prev and "gc" or nil })
    local right = iconButton("chevron-right", can_next and { kind = "page", delta = 1 } or nil, { size = 20, col = not can_next and "gc" or nil })
    local label = UI.text(tostring(self.page) .. " / " .. tostring(self.page_num), { s = 14, col = INK.g4 })
    return UI.hstack({ w = w, h = h, valign = "center" }, {
        UI.flex(0), left, UI.space(px(10), 1), label, UI.space(px(10), 1), right, UI.flex(0),
    })
end

function BoardMenu:_body(w, h)
    local ctx = self:_ctx()
    local start = (self.page - 1) * self.perpage
    local rows = {}
    if self:_gridMode() then
        local cols = self.columns or 3
        for r = 0, (self.grid_rows or 3) - 1 do
            local cells = {}
            for c = 1, cols do
                local idx = start + r * cols + c
                local entry = self.item_table[idx]
                table.insert(cells, entry and Cards.cell(entry, ctx, self._col_w, self._row_h) or UI.space(self._col_w, self._row_h))
            end
            table.insert(rows, UI.hstack({ w = w, h = self._row_h }, cells))
        end
    else
        for i = 1, self.perpage do
            local entry = self.item_table[start + i]
            if entry then table.insert(rows, Cards.row(entry, ctx, w, self._row_h)) end
        end
    end
    return UI.vstack({ w = w, h = h }, rows)
end

-- ------------------------------------------------------------- home chrome
function BoardMenu:_homeHeader(w)
    local title_h = px(32)
    local settings_btn = iconButton("sliders-horizontal", { kind = "settings" }, { size = 20 })
    local close = iconButton("x", { kind = "close" }, { size = 20 })
    local title_row = UI.hstack({ w = w, h = title_h, valign = "center" }, {
        UI.text(self.title or "", { s = 22, b = true, w = w - settings_btn:getSize().w - close:getSize().w - px(4), data = true }),
        UI.flex(0),
        settings_btn,
        close,
    })
    local search_h = px(38)
    local border = math.max(1, px(1.5))
    local gettext = self.plugin and self.plugin.i18n and self.plugin.i18n._ or function(s) return s end
    local placeholder = self._last_search or gettext("Search series...")
    local search_inner = UI.hstack({ w = w - 2 * border, h = search_h - 2 * border, valign = "center" }, {
        UI.space(px(14), 1),
        UI.icon("search", px(16), { sw = 2.5, col = "g4" }),
        UI.space(px(8), 1),
        UI.text(placeholder, { s = 14, col = self._last_search and INK.black or INK.g4, w = w - px(60) }),
        UI.flex(0),
    })
    local search_bar = UI.hit(
        UI.box({ w = w, h = search_h, radius = math.floor(search_h / 2), border = border, border_col = INK.g6, bg = INK.white }, search_inner),
        { kind = "search" })
    return UI.vstack({ w = w, h = px(HOME_HEADER_H) }, {
        UI.space(nil, px(4)),
        title_row,
        UI.space(nil, px(6)),
        search_bar,
    })
end

-- Buckets the flat item_table (browser.lua's getHomeItemTable) back into
-- { title, items } sections wherever an is_header entry occurs, without
-- browser.lua needing to change how it builds that list.
function BoardMenu:_homeSections()
    local sections, current = {}, nil
    for _i, entry in ipairs(self.item_table or {}) do
        if entry.is_header then
            current = { title = entry.text, items = {} }
            table.insert(sections, current)
        elseif current then
            table.insert(current.items, entry)
        else
            current = { title = nil, items = { entry } }
            table.insert(sections, current)
        end
    end
    return sections
end

-- "shelf" (has covers), "nav" (Browse's clickable rows -- any item whose
-- `kind` names a tile icon), or "bar" (banners/notes/empty states).
local function sectionKind(section)
    for _i, item in ipairs(section.items) do
        if item.cover_id and item.cover_type then return "shelf" end
    end
    for _i, item in ipairs(section.items) do
        if item.kind and Cards.TILE_ICONS[item.kind] then return "nav" end
    end
    return "bar"
end

-- Builds one shelf: its title row (with paging chevrons when there are more
-- cards than fit at once) and a row of cards. Returns the block and the
-- height it used, so the caller can budget remaining space; shelf paging
-- state lives in self._shelf_page[section_index], reset on switchItemTable.
function BoardMenu:_renderShelf(section, idx, w, ctx)
    local title_h = px(28)
    local gap = px(6)
    local covers = {}
    for _i, item in ipairs(section.items) do
        if item.cover_id and item.cover_type then table.insert(covers, item) end
    end
    if #covers == 0 then
        local note = section.items[1]
        local body = {}
        local used = 0
        if section.title then
            table.insert(body, UI.text(section.title, { s = 13, b = true, w = w, data = true }))
            used = title_h
        end
        if note and note.text then
            table.insert(body, UI.space(nil, px(6)))
            table.insert(body, UI.text(note.text, { s = 13, col = INK.g4, w = w, lines = 2, data = true }))
            used = used + px(6) + Theme.lh(13) * 2
        end
        return UI.vstack({ w = w }, body), math.max(title_h, used)
    end
    -- Capped at 5 so a very wide screen doesn't ask for an ridiculous row;
    -- each visible card is a real decode+scale of a cover image on first
    -- paint, so this is also most of what bounds how long Home takes to
    -- open with several shelves.
    local visible = math.min(5, math.max(1, math.floor((w + gap) / (CARD_W + gap))))
    local pages = math.max(1, math.ceil(#covers / visible))
    local page = math.max(1, math.min(self._shelf_page[idx] or 1, pages))
    self._shelf_page[idx] = page
    local start = (page - 1) * visible
    -- A shelf's entries are uniformly shaped (all Keep reading, or all one
    -- home list), so the first one's caption shape stands in for the whole
    -- row's card height.
    local _probe_title, probe_sub = Cards.caption(covers[1], ctx)
    local card_h = cardHeight(probe_sub ~= nil)
    local cards = {}
    for i = 1, visible do
        local item = covers[start + i]
        if item then table.insert(cards, Cards.cell(item, ctx, CARD_W, card_h)) end
    end
    local right
    if pages > 1 then
        local left_a = iconButton("chevron-left", page > 1 and { kind = "shelf-page", section = idx, delta = -1 } or nil,
            { size = 15, box = 28, col = page <= 1 and "gc" or nil })
        local right_a = iconButton("chevron-right", page < pages and { kind = "shelf-page", section = idx, delta = 1 } or nil,
            { size = 15, box = 28, col = page >= pages and "gc" or nil })
        right = UI.hstack({ gap = px(2) }, { left_a, right_a })
    end
    local title_row = section.title and UI.spread(w, UI.text(section.title, { s = 13, b = true }), right, title_h) or UI.space(w, 0)
    local card_row = UI.hstack({ w = w, gap = gap, valign = "top" }, cards)
    local block = UI.vstack({ w = w }, { title_row, UI.space(nil, px(4)), card_row })
    return block, title_h + px(4) + card_h
end

-- The Browse grid's rows, one candidate per row of 3 nav tiles (not one
-- block for the whole grid) -- so when a shelf leaves only a little room on
-- a page, whatever whole rows still fit land there instead of the entire
-- grid jumping to the next page and leaving that room empty. See
-- _homeBody's candidates list.
function BoardMenu:_navRowCandidates(section, w)
    local cols = 3
    local gap = px(10)
    local tile_w = math.floor((w - (cols - 1) * gap) / cols)
    local tile_h = TILE_ROW_H
    local items = section.items
    local out = {}
    local idx = 1
    while idx <= #items do
        local cells = {}
        for _c = 1, cols do
            local item = items[idx]
            table.insert(cells, item and Cards.tile(item, tile_w, tile_h) or UI.space(tile_w, tile_h))
            idx = idx + 1
        end
        table.insert(out, { widget = UI.hstack({ w = w, gap = gap }, cells), height = tile_h })
    end
    return out
end

-- Builds every section once (so nothing is ever silently dropped), then
-- greedily packs them into screen-sized pages; self._home_page/
-- _home_page_num track which one is showing, with _homeFooter paging
-- between them exactly like a catalogue page's footer. A shelf itself
-- still pages its own cards independently via its chevrons/swipe -- this
-- only paginates which *sections* are visible at once.
function BoardMenu:_homeBody(w, h)
    local mx = px(MARGIN)
    local body_w = w - 2 * mx
    local ctx = self:_ctx()
    local sections = self:_homeSections()
    local candidates = {}
    for idx, section in ipairs(sections) do
        local kind = sectionKind(section)
        if kind == "bar" then
            for _i, item in ipairs(section.items) do
                table.insert(candidates, { widget = Cards.bar(item, body_w, BAR_H, BAR_ICONS[item.kind]), height = BAR_H })
            end
        elseif kind == "shelf" then
            local block, block_h = self:_renderShelf(section, idx, body_w, ctx)
            if block then table.insert(candidates, { widget = block, height = block_h, shelf_idx = idx }) end
        elseif kind == "nav" then
            for _i, row in ipairs(self:_navRowCandidates(section, body_w)) do
                table.insert(candidates, row)
            end
        end
    end
    local pages, page, page_h = {}, {}, 0
    for _i, c in ipairs(candidates) do
        local need = c.height + (#page > 0 and SECTION_GAP or 0)
        if #page > 0 and page_h + need > h then
            table.insert(pages, page)
            page, page_h, need = {}, 0, c.height
        end
        table.insert(page, c)
        page_h = page_h + need
    end
    table.insert(pages, page)
    self._home_page_num = #pages
    self._home_page = math.max(1, math.min(self._home_page or 1, self._home_page_num))
    self._shelf_bounds = {}
    local rows, used = {}, 0
    for _i, c in ipairs(pages[self._home_page]) do
        table.insert(rows, UI.hstack({ w = w }, { UI.space(mx, 1), c.widget, UI.space(mx, 1) }))
        if c.shelf_idx then
            self._shelf_bounds[c.shelf_idx] = Geom:new{ x = mx, y = px(HOME_HEADER_H) + used, w = body_w, h = c.height }
        end
        used = used + c.height + SECTION_GAP
        table.insert(rows, UI.space(nil, SECTION_GAP))
    end
    return UI.vstack({ w = w, h = h }, rows)
end

function BoardMenu:_homeFooter(w)
    local h = px(FOOTER_H)
    if (self._home_page_num or 1) <= 1 then return UI.space(w, h) end
    local can_prev = (self._home_page or 1) > 1
    local can_next = (self._home_page or 1) < self._home_page_num
    local left = iconButton("chevron-left", can_prev and { kind = "home-page", delta = -1 } or nil, { size = 20, col = not can_prev and "gc" or nil })
    local right = iconButton("chevron-right", can_next and { kind = "home-page", delta = 1 } or nil, { size = 20, col = not can_next and "gc" or nil })
    local label = UI.text(tostring(self._home_page) .. " / " .. tostring(self._home_page_num), { s = 14, col = INK.g4 })
    return UI.hstack({ w = w, h = h, valign = "center" }, {
        UI.flex(0), left, UI.space(px(10), 1), label, UI.space(px(10), 1), right, UI.flex(0),
    })
end

-- ---------------------------------------------------------------- build
function BoardMenu:boardBuild()
    local w, h = self.dimen.w, self.dimen.h
    local mx = px(MARGIN)
    local side = UI.space(mx, 1)
    if self:_isHome() then
        return UI.vstack({ w = w, h = h }, {
            UI.hstack({ w = w }, { side, self:_homeHeader(w - 2 * mx), side }),
            self:_homeBody(w, h - px(HOME_HEADER_H) - px(FOOTER_H)),
            UI.hstack({ w = w }, { side, self:_homeFooter(w - 2 * mx), side }),
        })
    end
    local body_w, body_h = self:_bodyGeometry()
    return UI.vstack({ w = w, h = h }, {
        UI.hstack({ w = w }, { side, self:_header(body_w), side }),
        self:_body(w, body_h),
        UI.hstack({ w = w }, { side, self:_footer(body_w), side }),
    })
end

function BoardMenu:rebuild()
    local widget, hits = UI.collectHits(function() return self:boardBuild() end)
    if self[1] and self[1].free then self[1]:free() end
    self[1] = widget
    self.hits = hits
end

function BoardMenu:refresh()
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

function BoardMenu:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, INK.white)
    self[1]:paintTo(bb, x, y)
end

function BoardMenu:onCloseWidget()
    if self[1] and self[1].free then self[1]:free() end
end

-- -------------------------------------------------------------- gestures
function BoardMenu:hitAt(pos)
    local hits = self.hits or {}
    for index = #hits, 1, -1 do
        local area = hits[index]
        if area.dimen and pos:intersectWith(area.dimen) then return area end
    end
    return nil
end

function BoardMenu:onTapPage(_, ges)
    local area = ges and ges.pos and self:hitAt(ges.pos)
    if area then self:boardRunAction(area.action) end
    return true
end

function BoardMenu:onHoldPage(_, ges)
    local area = ges and ges.pos and self:hitAt(ges.pos)
    if area and area.action and area.action.entry then
        self:boardRunAction({ kind = "hold", entry = area.action.entry })
    end
    return true
end

-- Horizontal swipe: on Home, pages whichever shelf the swipe landed in, or
-- (outside any shelf) pages Home's own sections, same as its footer
-- chevrons; elsewhere, pages the whole screen like the footer's chevrons.
-- West = next, east = previous, matching every chevron pair.
function BoardMenu:onSwipePage(_, ges)
    local delta
    if ges and ges.direction == "west" then delta = 1
    elseif ges and ges.direction == "east" then delta = -1
    else return true end
    if self:_isHome() then
        if ges.pos then
            for idx, rect in pairs(self._shelf_bounds or {}) do
                if ges.pos:intersectWith(rect) then
                    self._shelf_page[idx] = math.max(1, (self._shelf_page[idx] or 1) + delta)
                    self:refresh()
                    return true
                end
            end
        end
        if (self._home_page_num or 1) > 1 then
            self._home_page = math.max(1, math.min(self._home_page_num, (self._home_page or 1) + delta))
            self:refresh()
        end
        return true
    end
    if self.page_num > 1 then self:boardGotoPage(self.page + delta) end
    return true
end

function BoardMenu:onClosePage()
    if self.onReturn then self:onReturn() else self:close() end
    return true
end

function BoardMenu:boardRunAction(action)
    if not action then return end
    if action.kind == "select" then
        self:onMenuSelect(action.entry)
    elseif action.kind == "hold" then
        self:onMenuHold(action.entry)
    elseif action.kind == "page" then
        self:boardGotoPage(self.page + action.delta)
    elseif action.kind == "shelf-page" then
        self._shelf_page[action.section] = math.max(1, (self._shelf_page[action.section] or 1) + action.delta)
        self:refresh()
    elseif action.kind == "home-page" then
        self._home_page = math.max(1, math.min(self._home_page_num or 1, (self._home_page or 1) + action.delta))
        self:refresh()
    elseif action.kind == "back" then
        if self.onReturn then self:onReturn() end
    elseif action.kind == "close" then
        self:close()
    elseif action.kind == "menu" then
        if self.header_menu_action then self.header_menu_action() end
    elseif action.kind == "search" then
        if self.promptSearch then self:promptSearch() end
    elseif action.kind == "settings" then
        self:boardOpenSettings()
    end
end

-- The sliders icon in every header: kouchiyomi's own full settings menu
-- (Server/Reading/Sync/Downloads/...), the same tree Tools > Uchiyomi
-- opens, shown directly so it is reachable from inside the browser too.
function BoardMenu:boardOpenSettings()
    local plugin = self.plugin
    if not (plugin and plugin.menu and plugin.menu.createMainMenu) then return end
    local Menu = require("ui/widget/menu")
    local gettext = plugin.i18n and plugin.i18n._ or function(s) return s end
    local menu
    menu = Menu:new{
        title = gettext("Uchiyomi"),
        item_table = plugin.menu:createMainMenu(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function BoardMenu:boardGotoPage(n)
    n = math.max(1, math.min(self.page_num, n))
    if n == self.page then return end
    self.page = n
    -- Not self:refresh() -- self.updateItems is monkey-patched by
    -- uchi/browser.lua's setViewMode to call _maybeLoadMore() first, which
    -- is what actually fetches the next server page's items (and prefetches
    -- their covers) before this page tries to draw them. Calling refresh()
    -- directly skipped that fetch entirely, leaving later pages blank.
    self:updateItems()
end

function BoardMenu:close()
    UIManager:close(self, "ui")
    if self.close_callback then self.close_callback() end
end

-- ----------------------------------------------------------------- data
function BoardMenu:switchItemTable(title, item_table)
    if title then self.title = title end
    self.item_table = item_table or self.item_table or {}
    self.page = 1
    self._shelf_page = {}
    self._shelf_bounds = {}
    self._home_page = 1
    self:updateItems()
end

function BoardMenu:updateItems(_select_number)
    self:_recalculateDimen()
    self:refresh()
end

function BoardMenu:onMenuSelect(item)
    if item and item.callback then item.callback(item) end
end

function BoardMenu:onMenuHold(_item)
    -- Overridden by uchi/browser.lua's UchiBrowser.
end

return BoardMenu
