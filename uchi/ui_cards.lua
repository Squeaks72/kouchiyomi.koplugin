--[[
    Series/chapter cards and nav tiles for the BookOrbit-styled browser
    (uchi/ui_board_menu.lua), drawn with BookOrbit's primitives
    (uchi/ui_theme.lua). Takes the exact same item_table entries
    uchi/browser.lua already builds for the stock list_menu.lua/grid_menu.lua
    renderers -- { text, callback, cover_id, cover_type, series, book,
    hold_callback, is_header, select_enabled, kind } -- so none of
    browser.lua's data/pagination/navigation logic has to change, only how
    an entry is painted.

    Only usable when uchi/ui_theme's Theme.available is true.
--]]

local Theme = require("uchi/ui_theme")
local UI = Theme.UI
local INK = Theme.INK
local px = Theme.px

local Cache = require("uchi/cache")
local Labels = require("uchi/labels")
local lfs = require("libs/libkoreader-lfs")

local Cards = {}

-- Cards.cell's caption sizing, shared with uchi/ui_board_menu.lua's
-- cardHeight() -- it needs a shelf card's exact height before building it,
-- so these stay in one place instead of two copies of the same numbers.
Cards.CAP_TITLE_S = 12
Cards.CAP_SUB_S = 10
Cards.CAP_GAP = px(2)
Cards.COVER_GAP = px(4)

--- The cached cover file for an entry, or nil (no cover expected, or not
-- downloaded yet -- BoardUI.cover draws its own placeholder either way).
local function coverPath(entry)
    if not (entry.cover_id and entry.cover_type) then return nil end
    local path = Cache.coverPath(entry.cover_type, entry.cover_id)
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end
Cards.coverPath = coverPath

-- Mirrors the badge logic in uchi/list_menu.lua and uchi/grid_menu.lua:
-- selected (bulk-select), downloaded, and read-progress ("New"/"Done"/"n/total").
local function badgesOf(entry, ctx)
    local out = {}
    if ctx.selected_books and entry.cover_id and ctx.selected_books[entry.cover_id] then
        out.selected = true
    end
    local book = entry.book
    if type(book) == "table" then
        if ctx.plugin and ctx.plugin.sync and book.id and ctx.plugin.sync:isBookDownloaded(book) then
            out.downloaded = true
        end
        local rp = book.readProgress
        if type(rp) ~= "table" then
            out.progress = ctx._("New")
        elseif rp.completed then
            out.progress = ctx._("Done")
        else
            local page = rp.page or 0
            local total = (book.media and tonumber(book.media.pagesCount)) or 0
            out.progress = total > 0 and (tostring(page) .. "/" .. tostring(total)) or (tostring(page) .. "p")
        end
    end
    return out
end

-- A small bordered white pill, the same shape as the stock badges but drawn
-- with BoardUI so it shares the ink palette and density step.
local function pill(str, size)
    local h = px(size or 18)
    local t = UI.text(str, { s = size and math.floor(size * 0.55) or 10, b = true, col = INK.black })
    local w = math.max(h, t:getSize().w + px(8))
    local b = math.max(1, px(1))
    return UI.box({ w = w, h = h, border = b, border_col = INK.black, bg = INK.white, radius = px(3) },
        UI.hstack({ w = w - 2 * b, h = h - 2 * b }, { UI.flex(0), t, UI.flex(0) }))
end

--- A cover image with its badges overlaid, sized exactly w x h.
function Cards.coverWithBadges(entry, ctx, w, h)
    local path = coverPath(entry)
    local b = badgesOf(entry, ctx)
    local cover = UI.cover(entry.book or entry.series or { title = entry.text }, w, h, {
        path = path, border = math.max(1, px(1)), border_col = INK.gb,
    })
    local layers = { { widget = cover, x = 0, y = 0 } }
    local gap = px(4)
    if b.selected then
        local check = UI.circle(px(20), { bg = INK.black }, UI.icon("check", px(13), { col = "white", sw = 3 }))
        table.insert(layers, { widget = check, x = gap, y = gap })
    end
    if b.downloaded then
        local dl = pill("\u{2193}", 20)
        table.insert(layers, { widget = dl, x = w - dl:getSize().w - gap, y = gap })
    end
    if b.progress then
        local pr = pill(b.progress, 18)
        table.insert(layers, { widget = pr, x = w - pr:getSize().w - gap, y = h - pr:getSize().h - gap })
    end
    return UI.overlay(w, h, layers)
end

-- "[ ] Title" / "[✓] Title" for bulk-select rows without a cover;
-- "▸ HEADER" for section headers; otherwise the entry's own text.
local function rawTitle(entry, ctx)
    local str = entry.text or entry.title or ctx._("Unknown")
    if entry.is_header then return "\u{25B8} " .. tostring(str):upper() end
    if entry.cover_type == "book" and not entry.cover_id then
        local book_id = entry.book and entry.book.id
        local checked = book_id and ctx.selected_books and ctx.selected_books[book_id]
        str = (checked and "[\u{2713}] " or "[ ] ") .. str
    end
    return str
end

-- The chapter's subtitle + authors, or a series' book-count summary --
-- mirrors uchi/list_menu.lua's subtitle logic exactly.
local function dataSubtitle(entry, ctx)
    local book = entry.book
    if type(book) == "table" then
        local extra = Labels.subtitle(book, book.seriesTitle)
        local author
        if type(book.metadata) == "table" and type(book.metadata.authors) == "table" and #book.metadata.authors > 0 then
            local names = {}
            for _i, a in ipairs(book.metadata.authors) do table.insert(names, a.name) end
            author = table.concat(names, ", ")
        end
        local parts = {}
        if extra then table.insert(parts, extra) end
        if author and author ~= "" then table.insert(parts, ctx._("By:") .. " " .. author) end
        if #parts > 0 then return table.concat(parts, "  \u{2022}  ") end
        return nil
    end
    local series = entry.series
    if type(series) == "table" then
        local count = series.booksCount or 0
        local unread = series.booksUnreadCount or 0
        local in_progress = series.booksInProgressCount or 0
        local parts = { ctx._("Books:") .. " " .. tostring(count) }
        if unread > 0 then table.insert(parts, ctx._("Unread:") .. " " .. tostring(unread)) end
        if in_progress > 0 then table.insert(parts, ctx._("In Progress:") .. " " .. tostring(in_progress)) end
        if unread == 0 and in_progress == 0 and count > 0 then table.insert(parts, ctx._("Completed")) end
        return table.concat(parts, "  \u{2022}  ")
    end
    return nil
end

-- browser.lua already composes a rich single-line label ("One Piece · Ch.
-- 944  [page 16 of 22]", "Dandadan  [3 unread]"); split it into a bold
-- headline and a muted caption instead of asking browser.lua for new
-- fields. Falls back to the series/chapter subtitle above when there is no
-- trailing "[...]" to split on.
local function caption(entry, ctx)
    local title = rawTitle(entry, ctx)
    if entry.is_header then return title, nil end
    local head, bracket = title:match("^(.-)%s*%[(.-)%]%s*$")
    if head and head ~= "" then return head, bracket end
    -- Set by uchi/browser.lua's keep_reading_item: that shelf's progress is
    -- already on the cover's own badge, so it never gets a second line --
    -- not "whenever there happens to be nothing to show", which would make
    -- the card height this shelf picks (see ui_board_menu.lua's
    -- _renderShelf, sized from entry #1) unreliable for its other cards.
    if entry.no_caption_sub then return title, nil end
    return title, dataSubtitle(entry, ctx)
end
Cards.caption = caption

local function selectAction(entry, body)
    if entry.is_header or entry.select_enabled == false then return body end
    return UI.hit(body, { kind = "select", entry = entry })
end

--- A list row: cover (when the entry has one) beside a title/caption, sized
-- exactly w x h. ctx: { plugin, selected_books, _ } (see ui_board_menu.lua).
function Cards.row(entry, ctx, w, h)
    local pad = px(12)
    local iw, ih = w - 2 * pad, math.max(1, h - 2 * pad)
    local cover, cover_w
    if entry.cover_id and entry.cover_type then
        cover_w = math.floor(ih * 2 / 3 + 0.5)
        cover = Cards.coverWithBadges(entry, ctx, cover_w, ih)
    end
    local text_w = math.max(px(10), iw - (cover and (cover_w + px(10)) or 0))
    local title, sub = caption(entry, ctx)
    local title_widget = UI.text(title, { s = entry.is_header and 13 or 16, b = not entry.is_header, w = text_w, data = true })
    local col_items = { title_widget }
    if sub then
        table.insert(col_items, UI.space(nil, px(3)))
        table.insert(col_items, UI.text(sub, { s = 12, col = INK.g4, w = text_w, lines = 2, data = true }))
    end
    local column = UI.vstack({ w = text_w }, col_items)
    local items = {}
    if cover then
        table.insert(items, cover)
        table.insert(items, UI.space(px(10), 1))
    end
    table.insert(items, column)
    table.insert(items, UI.flex(0))
    local row = UI.hstack({ w = iw, h = ih, valign = "center" }, items)
    local body = UI.vstack({ w = w, h = h, pad = pad }, { row })
    return selectAction(entry, body)
end

--- A grid card: cover above a bold title and a muted caption below it,
-- sized exactly w x h. Used both for catalogue grid pages and home shelves.
function Cards.cell(entry, ctx, w, h)
    local pad = px(6)
    local iw, ih = w - 2 * pad, math.max(1, h - 2 * pad)
    local title, sub = caption(entry, ctx)
    local cap_h = Theme.lh1(Cards.CAP_TITLE_S) + (sub and (Cards.CAP_GAP + Theme.lh1(Cards.CAP_SUB_S)) or 0)
    local items = {}
    if entry.cover_id and entry.cover_type then
        local cover_h = math.max(px(20), ih - cap_h - Cards.COVER_GAP)
        local cover_w = math.min(iw, math.floor(cover_h * 2 / 3 + 0.5))
        local cover = Cards.coverWithBadges(entry, ctx, cover_w, cover_h)
        table.insert(items, UI.flex(0))
        table.insert(items, UI.hstack({ w = iw }, { UI.flex(0), cover, UI.flex(0) }))
        table.insert(items, UI.space(nil, Cards.COVER_GAP))
    else
        table.insert(items, UI.flex(0))
    end
    table.insert(items, UI.text(title, { s = Cards.CAP_TITLE_S, b = true, w = iw, align = "center", lines = 1, data = true }))
    if sub then
        table.insert(items, UI.space(nil, Cards.CAP_GAP))
        table.insert(items, UI.text(sub, { s = Cards.CAP_SUB_S, col = INK.g4, w = iw, align = "center", lines = 1, data = true }))
    end
    table.insert(items, UI.flex(0))
    local body = UI.vstack({ w = w, h = h, pad = pad }, items)
    return selectAction(entry, body)
end

-- Icons for the Home screen's "Browse" tiles, keyed by the `kind` tag
-- uchi/browser.lua attaches to each nav row (see getHomeItemTable).
Cards.TILE_ICONS = {
    updates = "refresh-cw",
    favorites = "book-heart",
    bookmarks = "bookmark",
    recent = "clock",
    ["all-series"] = "layers-2",
    libraries = "library-big",
    search = "search",
    offline = "download",
    refresh = "refresh-cw",
    ["manage-lists"] = "list-checks",
}

--- A square-ish nav tile: an icon over a label, sized exactly w x h. Used
-- for the Home screen's "Browse" grid (no cover, just an action).
function Cards.tile(entry, w, h)
    local pad = px(8)
    local iw = w - 2 * pad
    local icon_name = Cards.TILE_ICONS[entry.kind] or "chevron-right"
    local body = UI.vstack({ w = w, h = h, pad = pad, align = "center" }, {
        UI.flex(0),
        UI.icon(icon_name, px(26), { sw = 2 }),
        UI.space(nil, px(8)),
        UI.text(entry.text or "", { s = 13, b = true, w = iw, align = "center", lines = 2 }),
        UI.flex(0),
    })
    local framed = UI.box({ w = w, h = h, border = math.max(1, px(1)), border_col = INK.g8, radius = px(10) }, body)
    return selectAction(entry, framed)
end

--- A full-width tappable notice bar (the pending-sync banner, the browse-
-- scope banner, the offline reconnect row): an icon and the entry's text.
function Cards.bar(entry, w, h, icon_name)
    local pad = px(12)
    local iw = w - 2 * pad - px(22) - px(10)
    local body = UI.hstack({ w = w - 2 * pad, h = h - 2 * pad, gap = px(10), valign = "center" }, {
        UI.icon(icon_name or "info", px(18), { sw = 2.25 }),
        UI.text(entry.text or "", { s = 13, w = iw, lines = 2, data = true }),
        UI.flex(0),
    })
    local framed = UI.box({ w = w, h = h, bg = INK.ge, radius = px(10) }, UI.vstack({ w = w, h = h, pad = pad }, { body }))
    return selectAction(entry, framed)
end

return Cards
