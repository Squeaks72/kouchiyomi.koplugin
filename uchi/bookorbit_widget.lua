--[[
    Widgets for BookOrbit's home screen (bookorbit.koplugin): the rows of Uchiyomi's home (Keep reading and the rest), New
    episodes, the unread chapters on this device, and a compact tile for the one manga being read.

    They live here, not in BookOrbit, so they survive BookOrbit's own updates: at start kouchiyomi adds them to BookOrbit's
    public widget table and to the list a reader adds widgets from, without changing a file of BookOrbit's. BookOrbit
    then treats them like any of its own: placing, moving, resizing, previews, tile style. On a device without BookOrbit
    the install does nothing. If kouchiyomi goes away a placed tile is left blank; the board itself is unharmed.

    A board has to draw at once and offline, so a widget only ever reads the copy saved in the settings; asking the
    server happens after the board is up, and redraws it if the answer changed. One /api/home answer holds every row.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local i18n = require("uchi/i18n")
local Labels = require("uchi/labels")
local _, T = i18n._, i18n.T

local Widget = {}

Widget.TYPE = "kouchiyomi_keep_reading"
-- How many of a row are kept, and how long a saved answer counts as current.
Widget.KEEP = 12
Widget.TTL = 120

-- The rows. `field` is the row's name, and its key in the /api/home answer unless it says otherwise: `source = "updates"`
-- is /api/updates, `source = "device"` is worked out here from the files on the device. `chapters` says it lists chapters
-- rather than series, `progress` that each card says how far along it is. Named as Uchiyomi's own Home names them. A
-- widget's type is stored in the board, so a row's must never change.
Widget.ROWS = {
    { field = "onDeck", chapters = true, progress = true, type = Widget.TYPE, title = function() return _("Keep reading") end,
      desc = function() return _("Your Keep reading row from Uchiyomi, via kouchiyomi") end,
      empty = function() return _("Chapters you read in Uchiyomi show up here.") end },
    { field = "updates", source = "updates", type = "kouchiyomi_new_episodes", title = function() return _("New episodes") end,
      desc = function() return _("Your favorites with new chapters, from Uchiyomi") end,
      empty = function() return _("New chapters of your favorites show up here.") end },
    { field = "device", source = "device", type = "kouchiyomi_on_device", title = function() return _("On this device") end,
      desc = function() return _("Series with unread chapters already downloaded") end,
      empty = function() return _("Unread chapters you have downloaded show up here.") end },
    { field = "pickUp", chapters = true, type = "kouchiyomi_pick_up", title = function() return _("Pick back up") end,
      desc = function() return _("Manga you put down a while ago, from Uchiyomi") end,
      empty = function() return _("Manga you put down a while ago show up here.") end },
    { field = "favorites", type = "kouchiyomi_favorites", title = function() return _("Your favorites") end,
      desc = function() return _("Your favorite series from Uchiyomi") end,
      empty = function() return _("Series you favorite in Uchiyomi show up here.") end },
    { field = "updated", type = "kouchiyomi_updated", title = function() return _("Recently updated") end,
      desc = function() return _("Series with new chapters, from Uchiyomi") end,
      empty = function() return _("Series with new chapters show up here.") end },
    { field = "new", type = "kouchiyomi_new", title = function() return _("Recently added") end,
      desc = function() return _("The newest series in Uchiyomi") end,
      empty = function() return _("New series in Uchiyomi show up here.") end },
    { field = "popular", type = "kouchiyomi_popular", title = function() return _("Most popular") end,
      desc = function() return _("The most popular series in your Uchiyomi library") end,
      empty = function() return _("The most popular series in your library show up here.") end },
    { field = "gems", type = "kouchiyomi_gems", title = function() return _("Hidden gems") end,
      desc = function() return _("Well-rated series you have not read, from Uchiyomi") end,
      empty = function() return _("Hidden gems in your library show up here.") end },
}

-- The compact tile: the first of Keep reading, so no row of its own.
Widget.CONTINUE = { field = "onDeck", type = "kouchiyomi_continue", title = function() return _("Continue manga") end,
    desc = function() return _("The manga you are on, and how far") end,
    empty = function() return _("The manga you are reading shows up here.") end }

Widget.fetched_at = 0      -- os.time() of the last answer; 0 = ask at the next chance
Widget.scanned_at = 0      -- the same for the look at this device's own files, which needs no network
Widget.plugin = nil        -- the live plugin instance: one is built per document
Widget.installed = false   -- BookOrbit's tables outlive plugin instances, so they are extended once
Widget.drawn_rows = {}     -- rows some board has drawn: only those get covers fetched or redraw it
-- The board that last drew a widget, to redraw it when newer data arrives. Weak: it must not keep a closed one alive.
local drawn_on = setmetatable({}, { __mode = "v" })

--- What is kept of a chapter: enough to draw its card and open it, offline included.
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

--- What is kept of a series: opening one reads it fresh from the server.
function Widget.slimSeries(series)
    local title = series.metadata and series.metadata.title
    return { id = series.id, seriesId = series.id, title = (title ~= "" and title) or series.name }
end

--- New episodes from an /api/updates answer, in the server's order: newest chapter first.
function Widget.updatesFrom(content, leave_out)
    local row = {}
    for _i, u in ipairs(type(content) == "table" and content or {}) do
        if #row >= Widget.KEEP then break end
        local series = type(u) == "table" and u.series
        if type(series) == "table" and series.id and not (leave_out and leave_out(series.id, series)) then
            local entry = Widget.slimSeries(series)
            entry.newCount = tonumber(u.newCount)
            table.insert(row, entry)
        end
    end
    return row
end

--- On this device, from the local info of each downloaded chapter (Sync:getDownloadedBookInfos): per series, how many are
-- unread and which to open, the one part-way through, else the lowest. `reached[series_id]` is the chapter Keep reading
-- has got to, so chapters read on another device do not count. Most recently downloaded series first.
function Widget.deviceRow(infos, leave_out, reached, downloaded)
    local groups, order = {}, {}
    for _i, info in ipairs(infos or {}) do
        local series_id = info.series_id
        local passed = series_id and reached and reached[series_id] and info.series_index and info.series_index < reached[series_id]
        if series_id and not info.finished and not passed and not (leave_out and leave_out(series_id)) then
            local g = groups[series_id]
            if not g then
                g = { series_id = series_id, title = info.series, count = 0, newest = 0 }
                groups[series_id] = g
                table.insert(order, g)
            end
            g.count = g.count + 1
            g.newest = math.max(g.newest, tonumber(downloaded and downloaded[info.path]) or 0)
            local best = g.next
            local index, best_index = info.series_index or math.huge, best and (best.series_index or math.huge)
            if not best or (info.in_progress and not best.in_progress)
                or (info.in_progress == best.in_progress and index < best_index) then
                g.next = info
            end
        end
    end
    table.sort(order, function(a, b)
        if a.newest ~= b.newest then return a.newest > b.newest end
        return tostring(a.series_id) < tostring(b.series_id)
    end)
    local row = {}
    for i = 1, math.min(#order, Widget.KEEP) do
        local g = order[i]
        table.insert(row, { id = g.next.book_id, seriesId = g.series_id, title = g.title, path = g.next.path, count = g.count })
    end
    return row
end

--- Where a chapter is: "Ch. 235 · p. 8", or just the chapter when it is not started or the page says nothing.
function Widget.progressLine(book)
    local label = Labels.chapter(book)
    local rp = book.readProgress
    local page = type(rp) == "table" and not rp.completed and tonumber(rp.page) or 0
    if page < 1 then return label end
    return T(_("%1 · p. %2"), label, page)
end

--- The page to open a chapter at: where it was left, unless this device has already read further.
function Widget.resumePage(book, local_page)
    local rp = book.readProgress
    local page = type(rp) == "table" and not rp.completed and tonumber(rp.page) or 0
    if page <= 1 or (tonumber(local_page) or 0) >= page then return nil end
    return page
end

--- A saved row from its part of an /api/home answer, in the server's order. `leave_out(series_id, entry)` drops hidden
-- libraries, and is a second check on 18+: the server already leaves that out of a request without adult=1.
function Widget.rowFrom(list, chapters, leave_out)
    local row = {}
    for _i, b in ipairs(type(list) == "table" and list or {}) do
        if #row >= Widget.KEEP then break end
        if type(b) == "table" and b.id then
            local series_id = chapters and b.seriesId or b.id
            if not (leave_out and leave_out(series_id, b)) then
                table.insert(row, chapters and Widget.slim(b) or Widget.slimSeries(b))
            end
        end
    end
    return row
end

--- 18+ or in a hidden library: not for a row.
local function left_out_of(plugin)
    local Adult, Hidden = require("uchi/adult"), require("uchi/hidden")
    return function(series_id, dto)
        return Adult.knownSeries(plugin, series_id) == true or Hidden.isSeries(plugin, series_id, dto)
    end
end

--- The cards to draw: a chapter dismissed from the browser's Keep reading stays off here too.
function Widget.cards(saved, def, dismissed, cover_of)
    local out = {}
    for _i, b in ipairs(type(saved) == "table" and saved or {}) do
        if not (type(dismissed) == "table" and dismissed[b.id]) then
            local action, sub
            if def.chapters then
                action = { kind = "kouchiyomi-open", book = b }
                sub = def.progress and Widget.progressLine(b) or nil
            elseif def.source == "device" then
                action = { kind = "kouchiyomi-file", path = b.path }
                sub = T(_("%1 ready"), b.count)
            else
                action = { kind = "kouchiyomi-series", series_id = b.id }
                sub = b.newCount and T(_("+%1 new"), b.newCount) or nil
            end
            table.insert(out, {
                title = (def.chapters and (b.seriesTitle or b.name) or b.title) or _("Manga"),
                sub = sub,
                cover_path = cover_of and cover_of(b) or nil,
                action = action,
            })
        end
    end
    return out
end

--- Identifies what a row shows, to tell whether a new answer needs a redraw: its cards, and what each says.
function Widget.signature(row)
    local parts = {}
    for _i, b in ipairs(row or {}) do
        local rp = type(b.readProgress) == "table" and b.readProgress
        table.insert(parts, table.concat({ tostring(b.id), tostring(rp and rp.page), tostring(b.newCount), tostring(b.count) }, ":"))
    end
    return table.concat(parts, ",")
end

--- A series' cover, else the chapter's; nil draws BookOrbit's placeholder with the title.
local function cover_of(entry)
    local Cache = require("uchi/cache")
    return (entry.seriesId and Cache.existingCoverPath("series", entry.seriesId))
        or (entry.id and entry.seriesId ~= entry.id and Cache.existingCoverPath("book", entry.id))
        or nil
end

--- Fetch the covers a row is missing. True when any arrived.
local function fetch_covers(plugin, row)
    if not plugin.api or not require("ui/network/manager"):isOnline() then return false end
    local any = false
    for _i, entry in ipairs(row or {}) do
        if entry.seriesId and not cover_of(entry) and plugin.cache:cacheThumbnail("series", entry.seriesId, nil, true) then
            any = true
        end
    end
    return any
end

--- Ask the server for the rows, on the API's short timeouts. Returns true when something a board has drawn changed.
function Widget.fetch(plugin)
    local api = plugin.api
    if not api then return false end
    -- Not get_home: "show 18+ in listings" must not put 18+ on the home screen.
    local was_fast = api.fast
    api.fast = true
    if not was_fast then api.fast_dead = false end
    require("uchi/hidden").refresh(plugin)
    local home = api:request("/api/home")
    local changed = false
    if type(home) == "table" then
        Widget.fetched_at = os.time()
        local leave_out = left_out_of(plugin)
        local saved, rows = plugin.settings.home_rows or {}, {}
        for _i, def in ipairs(Widget.ROWS) do
            local row
            if def.source == "updates" then
                -- A request of its own, so only when placed. A failure keeps what was saved.
                local updates = Widget.drawn_rows[def.field] and api:request("/api/updates")
                row = type(updates) == "table" and Widget.updatesFrom(updates.content, leave_out) or saved[def.field]
            elseif def.source == "device" then
                row = saved[def.field]
            else
                row = Widget.rowFrom(home[def.field], def.chapters, leave_out)
            end
            rows[def.field] = row
            if Widget.drawn_rows[def.field] and def.source ~= "device" then
                if Widget.signature(row) ~= Widget.signature(saved[def.field]) then changed = true end
                changed = fetch_covers(plugin, row) or changed
            end
        end
        plugin.settings.home_rows = rows
        plugin:saveSettings()
    end
    api.fast = was_fast
    if not was_fast then api.fast_dead = false end
    return changed
end

--- Look at this device's own files, only when On this device is placed. Returns true when the row changed.
function Widget.scan(plugin)
    if not Widget.drawn_rows.device then return false end
    Widget.scanned_at = os.time()
    local saved = plugin.settings.home_rows or {}
    local reached = {}
    for _i, b in ipairs(saved.onDeck or {}) do
        if b.seriesId and b.metadata then reached[b.seriesId] = tonumber(b.metadata.numberSort) end
    end
    local row = Widget.deviceRow(plugin.sync:getDownloadedBookInfos(), left_out_of(plugin), reached, plugin.settings.downloaded_books)
    local changed = Widget.signature(row) ~= Widget.signature(saved.device)
    saved.device = row
    plugin.settings.home_rows = saved
    if changed then plugin:saveSettings() end
    return fetch_covers(plugin, row) or changed
end

--- Remember the board a widget was just drawn on.
function Widget.noteBoard(menu)
    drawn_on[1] = menu
end

--- Redraw the board that showed a widget. Something may be over it just now (a toast, a dialog, the edit screen), and the
-- answer must not be lost to that, so this waits for the board to be back on top; a board that has closed needs nothing.
function Widget.redraw(tries)
    local menu = drawn_on[1]
    if not (menu and menu.boardIsTopmost)
        or not (UIManager:isWidgetShown(menu) or (menu.show_parent and UIManager:isWidgetShown(menu.show_parent))) then
        Widget.redraw_waiting = false
        return
    end
    if menu:boardIsTopmost() and not menu:boardEditing() then
        Widget.redraw_waiting = false
        menu:updateItems(nil, true)
    elseif (tries or 0) > 0 then
        UIManager:scheduleIn(2, function() Widget.redraw(tries - 1) end)
    else
        Widget.redraw_waiting = false
    end
end

--- Bring the rows up to date if they have gone stale and there is a network, and redraw the board on a change. Only for
-- a board that has drawn one of them: someone who has not placed one pays nothing for its existing.
function Widget.refresh()
    local plugin = Widget.plugin
    if Widget.refreshing or not (plugin and drawn_on[1]) then return end
    local fetch = plugin.api and os.time() - Widget.fetched_at >= Widget.TTL and require("ui/network/manager"):isOnline()
    local scan = Widget.drawn_rows.device and os.time() - Widget.scanned_at >= Widget.TTL
    if not (fetch or scan) then return end
    Widget.refreshing = true
    local ok, changed = pcall(function()
        local fetched = fetch and Widget.fetch(plugin) or false
        -- After the fetch: Keep reading's new answer says which chapters are behind the reader.
        local scanned = scan and Widget.scan(plugin) or false
        return fetched or scanned
    end)
    Widget.refreshing = false
    if not ok then
        logger.warn("kouchiyomi: BookOrbit widgets:", tostring(changed))
        return
    end
    if changed and not Widget.redraw_waiting then
        Widget.redraw_waiting = true
        Widget.redraw(30)
    end
end

--- Reading moved the row on: ask again at the next chance.
function Widget.markStale()
    Widget.fetched_at, Widget.scanned_at = 0, 0
end

--- What is hidden changed: ask again at the next chance, and redraw the board from the rows as they now stand.
function Widget.hiddenChanged()
    Widget.markStale()
    if drawn_on[1] and not Widget.redraw_waiting then
        Widget.redraw_waiting = true
        Widget.redraw(30)
    end
end

--- Open a chapter from the row the way the browser would: the copy on the device, else download or stream as set.
local function open_chapter(plugin, menu, book)
    local NetworkMgr = require("ui/network/manager")
    local lfs = require("libs/libkoreader-lfs")
    -- On the class: opening the file builds a new plugin instance, and this is what the card promised.
    local function open_file(path, page)
        require("uchi/sync").pending_goto_page = page
        menu:openDownloadedFile(path)
    end
    local function download()
        NetworkMgr:runWhenOnline(function()
            plugin.sync:downloadBook(book, book.seriesTitle, function(path) open_file(path, Widget.resumePage(book)) end)
        end)
    end
    local function stream()
        NetworkMgr:runWhenOnline(function() plugin.stream:open(book, Widget.resumePage(book)) end)
    end
    local path = plugin.sync:getBookLocalPath(book, book.seriesTitle)
    if path and lfs.attributes(path, "mode") == "file" then
        local prog = require("uchi/sidecar").readLocalProgress(path)
        return open_file(path, Widget.resumePage(book, prog and prog.page))
    end
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

--- Open a series in the Uchiyomi browser, read fresh from the server.
local function open_series(plugin, series_id)
    require("ui/network/manager"):runWhenOnline(function()
        local series, err = plugin.api:get_series(series_id)
        if type(series) ~= "table" then
            plugin:notify(_("Could not load that series: ") .. tostring(err), "error")
            return
        end
        plugin.menu:openBrowser(false, function(browser) browser:showBooksInSeries(series) end)
    end)
end

--- Handles these widgets' taps. True when the action was one of ours.
function Widget.run(menu, action)
    local plugin = Widget.plugin
    if not plugin then return false end
    if action.kind == "kouchiyomi-open" then
        open_chapter(plugin, menu, action.book)
    elseif action.kind == "kouchiyomi-series" then
        open_series(plugin, action.series_id)
    elseif action.kind == "kouchiyomi-file" then
        menu:openDownloadedFile(action.path)
    elseif action.kind == "kouchiyomi-browser" then
        plugin:onKouchiyomiBrowser()
    elseif action.kind == "kouchiyomi-settings" then
        plugin.menu:showSheet()
    else
        return false
    end
    return true
end

--- A real tile on a board, not a preview in the add-a-widget sheet (those have no index): only those count as placed.
local function note_drawn(def, ctx, item)
    if not (item and item.index) then return end
    Widget.noteBoard(ctx.menu)
    -- A row just placed may have nothing fetched for it yet, its covers above all.
    if not Widget.drawn_rows[def.field] then
        Widget.drawn_rows[def.field] = true
        Widget.markStale()
    end
    -- After this draw, never during it: a board does not wait on the network.
    local now = os.time()
    if now - Widget.fetched_at >= Widget.TTL or (Widget.drawn_rows.device and now - Widget.scanned_at >= Widget.TTL) then
        UIManager:scheduleIn(1, Widget.refresh)
    end
end

--- The tile. Laid out as BookOrbit lays out a shelf: a label row, then as many covers as fit with the series beneath.
local function draw(def, BoardUI, BoardMetrics, ctx, w, hh, _props, item)
    local INK = BoardMetrics.INK
    local px, lh1 = BoardMetrics.px, BoardMetrics.lh1
    local text, vstack, hstack, flex, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space, BoardUI.icon
    local plugin = Widget.plugin
    local pad = px(12)
    local iw = w - 2 * pad
    note_drawn(def, ctx, item)

    local saved = plugin and plugin.settings.home_rows
    local books = plugin and saved and Widget.cards(saved[def.field], def, plugin.settings.home_dismissed, cover_of) or {}
    local title = def.title()
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
            text(def.empty(), { s = 13, col = INK.g4, lines = 3, w = iw }),
            flex(0),
        })
    end
    local title_size = 11
    local sub_size = 10
    local has_sub = false
    for _i, card in ipairs(books) do has_sub = has_sub or card.sub ~= nil end
    local cap_h = px(6) + lh1(title_size) + (has_sub and px(2) + lh1(sub_size) or 0)
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
            card.sub and space(nil, px(2)) or false,
            card.sub and text(card.sub, { s = sub_size, col = INK.g4, w = cover_w, data = true }) or false,
        }), card.action))
    end
    return vstack({ w = w, h = hh, pad = pad, strict_padding = true }, {
        head,
        space(nil, px(10)),
        hstack({ gap = gap, valign = "top" }, cards),
        flex(0),
    })
end

--- Continue manga: one chapter, with how far along it is. Beside its cover when the tile has room, without it when not.
local function draw_continue(def, BoardUI, BoardMetrics, ctx, w, hh, _props, item)
    local INK = BoardMetrics.INK
    local px, lh1 = BoardMetrics.px, BoardMetrics.lh1
    local text, vstack, hstack, flex, space = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.flex, BoardUI.space
    local plugin = Widget.plugin
    local pad = px(12)
    local iw = w - 2 * pad
    note_drawn(def, ctx, item)
    local saved = plugin and plugin.settings.home_rows
    local card = plugin and saved and Widget.cards(saved.onDeck, Widget.ROWS[1], plugin.settings.home_dismissed, cover_of)[1]
    local title = text(def.title(), { s = 13, b = true, w = iw })
    if not card then
        return vstack({ w = w, h = hh, pad = pad }, {
            title,
            space(nil, px(8)),
            text(def.empty(), { s = 13, col = INK.g4, lines = 3, w = iw }),
            flex(0),
        })
    end
    local book = card.action.book
    local total = book.media and tonumber(book.media.pagesCount) or 0
    local rp = book.readProgress
    local page = type(rp) == "table" and tonumber(rp.page) or 0
    -- A chapter newly added can have no page count yet: no bar rather than a wrong one.
    local bar_shown = total > 0 and page > 0
    local cover_h = hh - 2 * pad
    local cover_w = math.floor(cover_h * 2 / 3 + 0.5)
    local with_cover = iw - cover_w - px(10) >= px(110)
    local tw = with_cover and iw - cover_w - px(10) or iw
    local details = vstack({ w = tw }, {
        text(card.title, { s = 14, b = true, w = tw, data = true }),
        space(nil, px(4)),
        text(card.sub or Labels.chapter(book), { s = 12, col = INK.g4, w = tw, data = true }),
        bar_shown and space(nil, px(8)) or false,
        bar_shown and BoardUI.bar(tw, px(4), math.floor(page * 100 / total + 0.5), { track = INK.gc }) or false,
    })
    local body
    if with_cover then
        local thin = math.max(1, px(0.75))
        body = hstack({ w = iw, h = cover_h, gap = px(10) }, {
            BoardUI.cover({ title = card.title }, cover_w, cover_h, { path = card.cover_path, border = thin, border_col = INK.gb }),
            details,
        })
    else
        body = vstack({ w = iw }, { title, space(nil, px(6)), details })
    end
    return BoardUI.hit(vstack({ w = w, h = hh, pad = pad, strict_padding = true }, { body, flex(0) }), card.action)
end

--- Add the widgets to BookOrbit. Returns false when BookOrbit is not there, or not a version with these tables.
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
    for _i, def in ipairs(Widget.ROWS) do
        BoardWidgets.W[def.type] = function(ctx, w, hh, props, item)
            return draw(def, BoardUI, BoardMetrics, ctx, w, hh, props, item)
        end
        table.insert(BoardEdit.LIBRARY, {
            type = def.type, name = def.title, desc = def.desc,
            sizes = { "L", "XL" }, tab = "library", new = true,
        })
    end
    local cont = Widget.CONTINUE
    BoardWidgets.W[cont.type] = function(ctx, w, hh, props, item)
        return draw_continue(cont, BoardUI, BoardMetrics, ctx, w, hh, props, item)
    end
    table.insert(BoardEdit.LIBRARY, {
        type = cont.type, name = cont.title, desc = cont.desc,
        sizes = { "M", "S", "W" }, tab = "library", new = true,
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
