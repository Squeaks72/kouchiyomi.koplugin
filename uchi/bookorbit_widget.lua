--[[
    A "Keep reading" widget for BookOrbit's home screen (bookorbit.koplugin).

    It lives here, not in BookOrbit, so it survives BookOrbit's own updates: at start kouchiyomi adds it to BookOrbit's
    public widget table and to the list a reader adds widgets from, without changing a file of BookOrbit's. BookOrbit
    then treats it like any of its own: placing, moving, resizing, previews, tile style. On a device without BookOrbit
    the install does nothing. If kouchiyomi goes away a placed tile is left blank; the board itself is unharmed.

    The row is Uchiyomi's Keep reading rail. A board has to draw at once and offline, so the widget only ever reads the
    copy saved in the settings; asking the server happens after the board is up, and redraws it if the answer changed.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("uchi/i18n")._

local Widget = {}

Widget.TYPE = "kouchiyomi_keep_reading"
-- How many series are kept, and how long a saved row counts as current.
Widget.KEEP = 12
Widget.TTL = 120

Widget.fetched_at = 0      -- os.time() of the last answer; 0 = ask at the next chance
Widget.plugin = nil        -- the live plugin instance: one is built per document
Widget.installed = false   -- BookOrbit's tables outlive plugin instances, so they are extended once
-- The board that last drew the widget, to redraw it when newer data arrives. Weak: it must not keep a closed one alive.
local drawn_on = setmetatable({}, { __mode = "v" })

--- What is kept of a book from the rail: enough to draw its card and open it, offline included.
function Widget.slim(book)
    local m, media = book.metadata or {}, book.media or {}
    return {
        id = book.id, name = book.name, seriesId = book.seriesId, seriesTitle = book.seriesTitle,
        media = { pagesCount = media.pagesCount },
        metadata = { title = m.title, number = m.number, numberSort = m.numberSort },
        readProgress = type(book.readProgress) == "table"
            and { page = book.readProgress.page, completed = book.readProgress.completed } or nil,
    }
end

--- The saved row from an /api/home answer, newest first. `is_adult(series_id)` is a second check: the server already
-- leaves 18+ out of the rail for a request without adult=1.
function Widget.railFrom(on_deck, is_adult)
    local rail = {}
    for _i, b in ipairs(on_deck or {}) do
        if #rail >= Widget.KEEP then break end
        if type(b) == "table" and b.id and not (is_adult and is_adult(b.seriesId)) then
            table.insert(rail, Widget.slim(b))
        end
    end
    return rail
end

--- The cards to draw: a chapter dismissed from the browser's Keep reading stays off this row too.
function Widget.cards(rail, dismissed, cover_of)
    local out = {}
    for _i, b in ipairs(type(rail) == "table" and rail or {}) do
        if not (type(dismissed) == "table" and dismissed[b.id]) then
            table.insert(out, {
                book = b,
                title = b.seriesTitle or b.name or _("Manga"),
                cover_path = cover_of and cover_of(b) or nil,
            })
        end
    end
    return out
end

--- Identifies what a row shows, to tell whether a new answer needs a redraw.
function Widget.signature(rail)
    local parts = {}
    for _i, b in ipairs(rail or {}) do table.insert(parts, tostring(b.id)) end
    return table.concat(parts, ",")
end

--- A series' cover, else the chapter's; nil draws BookOrbit's placeholder with the title.
local function cover_of(book)
    local Cache = require("uchi/cache")
    return (book.seriesId and Cache.existingCoverPath("series", book.seriesId))
        or (book.id and Cache.existingCoverPath("book", book.id))
        or nil
end

--- Ask the server for the row, on the API's short timeouts. Returns true when what the widget shows changed.
function Widget.fetch(plugin)
    local api = plugin.api
    if not api then return false end
    -- Not get_home: "show 18+ in listings" must not put 18+ on the home screen.
    local was_fast = api.fast
    api.fast = true
    if not was_fast then api.fast_dead = false end
    local home = api:request("/api/home")
    local changed = false
    if type(home) == "table" and type(home.onDeck) == "table" then
        Widget.fetched_at = os.time()
        local Adult = require("uchi/adult")
        local rail = Widget.railFrom(home.onDeck, function(series_id) return Adult.knownSeries(plugin, series_id) == true end)
        for _i, b in ipairs(rail) do
            if b.seriesId and not cover_of(b) and plugin.cache:cacheThumbnail("series", b.seriesId, nil, true) then changed = true end
        end
        local saved = plugin.settings.keep_reading_rail
        if Widget.signature(rail) ~= Widget.signature(saved) then changed = true end
        plugin.settings.keep_reading_rail = rail
        plugin:saveSettings()
    end
    api.fast = was_fast
    if not was_fast then api.fast_dead = false end
    return changed
end

--- Bring the row up to date if it has gone stale and there is a network, and redraw the board on a change. Only for a
-- board that has drawn the widget: someone who has not placed it pays nothing for its existing.
function Widget.refresh()
    local plugin = Widget.plugin
    if Widget.refreshing or not (plugin and plugin.api and drawn_on[1]) then return end
    if os.time() - Widget.fetched_at < Widget.TTL then return end
    if not require("ui/network/manager"):isOnline() then return end
    Widget.refreshing = true
    local ok, changed = pcall(Widget.fetch, plugin)
    Widget.refreshing = false
    if not ok then
        logger.warn("kouchiyomi: Keep reading widget:", tostring(changed))
        return
    end
    local menu = drawn_on[1]
    if changed and menu and menu.boardIsTopmost and menu:boardIsTopmost() and not menu:boardEditing()
        and (UIManager:isWidgetShown(menu) or (menu.show_parent and UIManager:isWidgetShown(menu.show_parent))) then
        menu:updateItems(nil, true)
    end
end

--- Reading moved the row on: ask again at the next chance.
function Widget.markStale()
    Widget.fetched_at = 0
end

--- Open a chapter from the row the way the browser would: the copy on the device, else download or stream as set.
local function open_chapter(plugin, menu, book)
    local NetworkMgr = require("ui/network/manager")
    local lfs = require("libs/libkoreader-lfs")
    local function open_file(path) menu:openDownloadedFile(path) end
    local function download()
        NetworkMgr:runWhenOnline(function()
            plugin.sync:downloadBook(book, book.seriesTitle, open_file)
        end)
    end
    local function stream()
        NetworkMgr:runWhenOnline(function() plugin.stream:open(book) end)
    end
    local path = plugin.sync:getBookLocalPath(book, book.seriesTitle)
    if path and lfs.attributes(path, "mode") == "file" then return open_file(path) end
    local mode = plugin:openModeFor(book)
    if mode == "download" then return download() end
    if mode == "stream" then return stream() end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = require("uchi/labels").display(book, true),
        buttons = {
            { { text = _("Download & open"), is_enter_default = true, callback = function() UIManager:close(dialog); download() end } },
            { { text = _("Stream"), callback = function() UIManager:close(dialog); stream() end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

--- Handles this widget's taps. True when the action was one of ours.
function Widget.run(menu, action)
    local plugin = Widget.plugin
    if not plugin then return false end
    if action.kind == "kouchiyomi-open" then
        open_chapter(plugin, menu, action.book)
    elseif action.kind == "kouchiyomi-browser" then
        plugin:onKouchiyomiBrowser()
    elseif action.kind == "kouchiyomi-settings" then
        plugin.menu:showSheet()
    else
        return false
    end
    return true
end

--- The tile. Laid out as BookOrbit lays out a shelf: a label row, then as many covers as fit with the series beneath.
local function draw(BoardUI, BoardMetrics, ctx, w, hh, _props, item)
    local INK = BoardMetrics.INK
    local px, lh1 = BoardMetrics.px, BoardMetrics.lh1
    local text, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon
    local plugin = Widget.plugin
    local pad = px(12)
    local iw = w - 2 * pad
    drawn_on[1] = ctx.menu
    -- After this draw, never during it: a board does not wait on the network.
    if os.time() - Widget.fetched_at >= Widget.TTL then UIManager:scheduleIn(1, Widget.refresh) end

    local books = plugin and Widget.cards(plugin.settings.keep_reading_rail, plugin.settings.home_dismissed, cover_of) or {}
    local title = _("Keep reading")
    local right = hstack({ gap = px(14) }, {
        BoardUI.hit(icon("book-open", px(16), { sw = 2.25 }), { kind = "kouchiyomi-browser" }),
        BoardUI.hit(icon("sliders-horizontal", px(16), { sw = 2.25 }), { kind = "kouchiyomi-settings" }),
    })
    local room = iw - right:getSize().w - px(4)
    local size = 13
    local label = text(title, { s = size, b = true })
    while label:getSize().w > room and size > 11 do
        size = size - 1
        label = text(title, { s = size, b = true })
    end
    if label:getSize().w > room then label = text(title, { s = size, b = true, w = math.max(1, room) }) end
    local head = BoardUI.spread(iw, label, right, lh1(13))

    if #books == 0 then
        return vstack({ w = w, h = hh, pad = pad }, {
            head,
            space(nil, px(8)),
            text(_("Chapters you read in Uchiyomi show up here."), { s = 13, col = INK.g4, lines = 3, w = iw }),
            flex(0),
        })
    end
    local title_size = 11
    local cap_h = px(6) + lh1(title_size)
    local cover_h = math.max(1, hh - 2 * pad - lh1(13) - px(10) - cap_h)
    local cover_w = math.min(iw, math.floor(cover_h * 2 / 3 + 0.5))
    cover_h = math.min(cover_h, math.floor(cover_w * 1.5 + 0.5))
    local min_gap = px(12)
    -- A half-width tile holds three covers; one as wide as the board takes as many as fit, leaving real empty space on
    -- the right when there are fewer series than that rather than stretching the gaps between them.
    local geometry = ctx.menu and ctx.menu._board_geometry
    local full_width = item and geometry and item.cw >= geometry.cols
    local max_books = (not full_width and (item and item.cw or 2) <= 2) and 3 or math.huge
    local n = math.min(max_books, math.max(1, math.floor((iw + min_gap) / (cover_w + min_gap))))
    if n < max_books and n < #books and iw - (n * cover_w + (n - 1) * min_gap) > cover_w * 0.45 then
        n = n + 1
        cover_w = math.floor((iw - (n - 1) * min_gap) / n)
        cover_h = math.min(cover_h, math.floor(cover_w * 1.5 + 0.5))
    end
    local gap = n > 1 and math.floor((iw - n * cover_w) / (n - 1)) or 0
    local thin = math.max(1, px(0.75))
    local cards = {}
    for i = 1, math.min(n, #books) do
        local card = books[i]
        table.insert(cards, BoardUI.hit(vstack({ w = cover_w }, {
            BoardUI.cover({ title = card.title }, cover_w, cover_h, { path = card.cover_path, border = thin, border_col = INK.gb }),
            space(nil, px(6)),
            text(card.title, { s = title_size, b = true, w = cover_w, data = true }),
        }), { kind = "kouchiyomi-open", book = card.book }))
    end
    return vstack({ w = w, h = hh, pad = pad, strict_padding = true }, {
        head,
        space(nil, px(10)),
        hstack({ gap = gap, valign = "top" }, cards),
        flex(0),
    })
end

--- Add the widget to BookOrbit. Returns false when BookOrbit is not there, or not a version with these tables.
function Widget.install(plugin)
    Widget.plugin = plugin
    if Widget.installed then return true end
    local function try(name)
        local ok, mod = pcall(require, name)
        return ok and type(mod) == "table" and mod or nil
    end
    local BoardWidgets, BoardEdit = try("bookorbit_board_widgets"), try("bookorbit_board_edit")
    local BoardUI, BoardMetrics = try("bookorbit_board_ui"), try("bookorbit_board_metrics")
    local Catalog = try("bookorbit_catalog")
    if not (BoardWidgets and type(BoardWidgets.W) == "table" and BoardEdit and type(BoardEdit.LIBRARY) == "table"
        and BoardUI and BoardMetrics and Catalog and Catalog.boardRun) then
        return false
    end
    BoardWidgets.W[Widget.TYPE] = function(ctx, w, hh, props, item)
        return draw(BoardUI, BoardMetrics, ctx, w, hh, props, item)
    end
    table.insert(BoardEdit.LIBRARY, {
        type = Widget.TYPE,
        name = function() return _("Keep reading") end,
        desc = function() return _("Your Keep reading row from Uchiyomi, via kouchiyomi") end,
        sizes = { "L", "XL" }, tab = "library", new = true,
    })
    local board_run = Catalog.boardRun
    Catalog.boardRun = function(menu, action, tile)
        if Widget.run(menu, action) then return end
        return board_run(menu, action, tile)
    end
    Widget.installed = true
    return true
end

return Widget
