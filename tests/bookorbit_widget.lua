--[[
    The widgets for BookOrbit's home screen: what a row holds, what it asks of the server, and that its
    injection neither needs BookOrbit nor gets in BookOrbit's way. Plain Lua 5.1, stubs KOReader:
      lua5.1 tests/bookorbit_widget.lua     (from the plugin folder)
    Drawing it is covered in the emulator, against BookOrbit's real widgets.
--]]
package.path = "./?.lua;" .. package.path
local online, shown = true, {}
local scheduled = {}
package.preload["ui/uimanager"] = function() return {
    scheduleIn = function(_s, _t, fn) table.insert(scheduled, fn) end,
    isWidgetShown = function(_s, w) return shown[w] == true end,
    show = function() end, close = function() end,
} end
package.preload["ui/network/manager"] = function() return {
    isOnline = function() return online end,
    runWhenOnline = function(_s, fn) fn() end,
} end
package.preload["logger"] = function() local n = function() end; return { warn = n, info = n, dbg = n } end
package.preload["uchi/i18n"] = function() return {
    _ = function(s) return s end,
    T = function(t, a, b) return (t:gsub("%%1", tostring(a)):gsub("%%2", tostring(b))) end,
} end
local local_pages = {}
package.preload["uchi/sidecar"] = function() return {
    readLocalProgress = function(path) return local_pages[path] and { page = local_pages[path] } or nil end,
} end
local SyncClass = {}
package.preload["uchi/sync"] = function() return SyncClass end
package.preload["uchi/adult"] = function() return {
    knownSeries = function(p, id) return (p.settings.adult_series_cache or {})[id] end,
} end
local covers = {}
package.preload["uchi/cache"] = function() return {
    existingCoverPath = function(kind, id) return covers[kind .. "_" .. tostring(id)] end,
} end
local local_files = {}
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path) return local_files[path] and "file" or nil end,
} end
local Widget = require("uchi/bookorbit_widget")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local function chapter(n, sid)
    return { id = "b" .. n, seriesId = sid or ("s" .. n), seriesTitle = "Series " .. n, name = "Chapter " .. n,
             metadata = { title = "Chapter " .. n, number = tostring(n), numberSort = n, summary = "long" },
             media = { pagesCount = 20, extra = "x" }, readProgress = { page = 3, completed = false, extra = "x" } }
end

-- What is kept.
local slim = Widget.slim(chapter(5))
check("keeps what opening a chapter needs", slim.id == "b5" and slim.seriesId == "s5" and slim.seriesTitle == "Series 5"
    and slim.media.pagesCount == 20 and slim.metadata.numberSort == 5 and slim.readProgress.page == 3)
check("and not the rest", slim.metadata.summary == nil and slim.media.extra == nil and slim.readProgress.extra == nil)
check("a chapter never opened has no progress", Widget.slim({ id = "x" }).readProgress == nil)

-- A row: order kept, bounded, 18+ out.
local deck = {}
for n = 1, 20 do deck[n] = chapter(n) end
local rail = Widget.rowFrom(deck, true)
check("the row's order is kept", rail[1].id == "b1" and rail[2].id == "b2")
check("bounded", #rail == Widget.KEEP, #rail)
rail = Widget.rowFrom({ chapter(1), chapter(2), chapter(3) }, true, function(sid) return sid == "s2" end)
check("a series known to be 18+ is left out", #rail == 2 and rail[2].id == "b3", #rail)
check("nothing is an empty row", #Widget.rowFrom(nil, true) == 0)
local series = { id = "s5", name = "folder", metadata = { title = "Series 5", summary = "long" } }
local srow = Widget.rowFrom({ series, { id = "s6", name = "Only a name", metadata = { title = "" } } }, false, function(sid) return sid == "s9" end)
check("a series row keeps id and title", srow[1].id == "s5" and srow[1].title == "Series 5" and srow[1].metadata == nil)
check("falling back on its name", srow[2].title == "Only a name", srow[2].title)
check("18+ goes by the series itself on a series row", #Widget.rowFrom({ { id = "s9", name = "x" } }, false, function(sid) return sid == "s9" end) == 0)

-- Every row is a widget of its own, and a placed widget's type never changes.
local seen_field, seen_type = {}, {}
for _i, def in ipairs(Widget.ROWS) do
    check("row " .. def.field .. " is complete", def.type and def.title() and def.desc() and def.empty())
    check("row " .. def.field .. " is unique", not seen_field[def.field] and not seen_type[def.type])
    seen_field[def.field], seen_type[def.type] = true, true
end
check("Keep reading's stored type", Widget.ROWS[1].type == "kouchiyomi_keep_reading" and Widget.ROWS[1].field == "onDeck")
check("the rows the server sends", seen_field.pickUp and seen_field.favorites and seen_field.updated and seen_field.new and seen_field.popular and seen_field.gems)

-- The cards: dismissed, captions, covers, what a tap does.
local chapters_def, series_def = { chapters = true }, {}
local cards = Widget.cards({ Widget.slim(chapter(1)), Widget.slim(chapter(2)) }, chapters_def, { b1 = true }, function(b) return "/c/" .. b.id end)
check("a dismissed chapter stays off", #cards == 1 and cards[1].action.book.id == "b2", #cards)
check("captioned with its series", cards[1].title == "Series 2", cards[1].title)
check("with its cover", cards[1].cover_path == "/c/b2")
check("a chapter opens the chapter", cards[1].action.kind == "kouchiyomi-open")
cards = Widget.cards(srow, series_def)
check("a series is captioned with its title", cards[1].title == "Series 5", cards[1].title)
check("a series opens the series", cards[1].action.kind == "kouchiyomi-series" and cards[1].action.series_id == "s5")
check("no row is no cards", #Widget.cards(nil, chapters_def) == 0 and #Widget.cards({}, series_def) == 0)

-- Where a chapter is: Keep reading's caption.
local at = Widget.slim(chapter(235))
at.readProgress = { page = 8, completed = false }
check("chapter and page", Widget.progressLine(at) == "Ch. 235 · p. 8", Widget.progressLine(at))
at.readProgress = { page = 20, completed = true }
check("a finished chapter has no page to name", Widget.progressLine(at) == "Ch. 235", Widget.progressLine(at))
at.readProgress = nil
check("nor one not started", Widget.progressLine(at) == "Ch. 235", Widget.progressLine(at))
at.readProgress = { page = 8, completed = false }
check("only rows that ask for it say so", Widget.cards({ at }, chapters_def)[1].sub == nil)
check("Keep reading asks", Widget.cards({ at }, Widget.ROWS[1])[1].sub == "Ch. 235 · p. 8")
check("the title stays the series", Widget.cards({ at }, Widget.ROWS[1])[1].title == "Series 235")

-- Which page to open at.
check("where it was left", Widget.resumePage(at) == 8)
check("not behind this device", Widget.resumePage(at, 12) == nil)
check("ahead of this device", Widget.resumePage(at, 3) == 8)
check("level with it, nothing to do", Widget.resumePage(at, 8) == nil)
check("a finished one opens as it would", Widget.resumePage({ readProgress = { page = 20, completed = true } }) == nil)
check("page one is the start anyway", Widget.resumePage({ readProgress = { page = 1 } }) == nil)
check("no progress, no page", Widget.resumePage({}) == nil)

-- New episodes.
local ups = Widget.updatesFrom({
    { series = { id = "s1", metadata = { title = "One" } }, newCount = 3 },
    { series = { id = "s18", metadata = { title = "Adult" } }, newCount = 1 },
    { newCount = 2 },
}, function(sid) return sid == "s18" end)
check("a favorite with new chapters", #ups == 1 and ups[1].title == "One" and ups[1].newCount == 3, #ups)
local up = Widget.cards(ups, Widget.ROWS[2])[1]
check("says how many", up.sub == "+3 new", up.sub)
check("and opens the series", up.action.kind == "kouchiyomi-series" and up.action.series_id == "s1")
check("nothing new is an empty row", #Widget.updatesFrom(nil) == 0)

-- On this device.
local function file(n, sid, o)
    o = o or {}
    return { path = "/dl/" .. sid .. "/" .. n, book_id = sid .. "b" .. n, series_id = sid, series = "S " .. sid, series_index = n,
             finished = o.finished or false, in_progress = o.in_progress or false }
end
local dev = Widget.deviceRow({ file(5, "a"), file(4, "a"), file(3, "a", { finished = true }), file(1, "b", { finished = true }) })
check("a series with unread chapters", #dev == 1 and dev[1].seriesId == "a", #dev)
check("counts what is unread", dev[1].count == 2, dev[1].count)
check("opens the lowest unread", dev[1].path == "/dl/a/4", dev[1].path)
dev = Widget.deviceRow({ file(4, "a"), file(5, "a", { in_progress = true }) })
check("a chapter part-way through comes first", dev[1].path == "/dl/a/5", dev[1].path)
dev = Widget.deviceRow({ file(4, "a"), file(9, "a") }, nil, { a = 9 })
check("a chapter read on another device does not count", dev[1].count == 1 and dev[1].path == "/dl/a/9", dev[1].path)
check("nor does a whole series of them", #Widget.deviceRow({ file(4, "a") }, nil, { a = 9 }) == 0)
check("18+ is left out", #Widget.deviceRow({ file(1, "x") }, function(sid) return sid == "x" end) == 0)
check("a file not of ours is left out", #Widget.deviceRow({ { path = "/x", finished = false } }) == 0)
dev = Widget.deviceRow({ file(1, "old"), file(1, "new") }, nil, nil, { ["/dl/old/1"] = 100, ["/dl/new/1"] = 200 })
check("most recently downloaded first", dev[1].seriesId == "new", dev[1].seriesId)
local ready = Widget.cards(dev, Widget.ROWS[3])[1]
check("says how many are ready", ready.sub == "1 ready", ready.sub)
check("and opens the file itself", ready.action.kind == "kouchiyomi-file" and ready.action.path == "/dl/new/1")

-- A plugin and a board, for the rest.
local function plugin_with(home)
    local p = {
        settings = { home_rows = {} }, saves = 0, asked = {}, thumbs = {},
        saveSettings = function(self) self.saves = self.saves + 1 end,
    }
    p.cache = { cacheThumbnail = function(_c, kind, id)
        table.insert(p.thumbs, id); covers[kind .. "_" .. id] = "/c/" .. id; return "/c/" .. id
    end }
    p.api = { request = function(self, path)
        table.insert(p.asked, path)
        p.fast_during = self.fast
        return home
    end }
    return p
end

-- The request: never adult=1, whatever "show 18+ in listings" is doing to get_home.
local p = plugin_with({ onDeck = { chapter(1), chapter(2) }, gems = { { id = "s50", metadata = { title = "Gem" } } } })
p.api.get_home = function() error("must not use get_home") end
Widget.drawn_rows = {}
local changed = Widget.fetch(p)
check("asks /api/home with no adult=1", p.asked[1] == "/api/home", p.asked[1])
check("on short timeouts", p.fast_during == true)
check("and leaves them as it found them", not p.api.fast)
check("every row is saved", #p.settings.home_rows.onDeck == 2 and #p.settings.home_rows.gems == 1 and #p.settings.home_rows.popular == 0)
check("New episodes is not asked for until it is placed", #p.asked == 1, #p.asked)
check("the answer is dated", Widget.fetched_at > 0)
-- Only rows on a board cost anything.
check("no row drawn: no change to redraw", changed == false)
check("no row drawn: no covers fetched", #p.thumbs == 0, #p.thumbs)
Widget.drawn_rows = { gems = true }
check("a drawn row with a cover to fetch is a change", Widget.fetch(p) == true)
check("only the drawn row's covers come", #p.thumbs == 1 and p.thumbs[1] == "s50", #p.thumbs)
check("the same answer again is no change", Widget.fetch(p) == false)
check("and no more covers", #p.thumbs == 1, #p.thumbs)
Widget.drawn_rows = { onDeck = true, gems = true }
covers["series_s1"], covers["series_s2"] = "/c/s1", "/c/s2"
Widget.fetch(p)
p.api.request = function() return { onDeck = { chapter(2), chapter(1) }, gems = p.settings.home_rows.gems } end
check("a reordered drawn row is a change", Widget.fetch(p) == true)
Widget.drawn_rows = { gems = true }
p.api.request = function() return { onDeck = { chapter(1) }, gems = { { id = "s50", metadata = { title = "Gem" } } } } end
check("a change to a row not on the board is not", Widget.fetch(p) == false)
-- What a card says is part of what a row shows.
Widget.drawn_rows = { onDeck = true }
Widget.fetch(p)
local turned = chapter(1)
turned.readProgress.page = 9
p.api.request = function() return { onDeck = { turned } } end
check("a new page on a card is a change", Widget.fetch(p) == true)

-- New episodes: its own request, and a failure keeps what was saved.
Widget.drawn_rows = { updates = true }
covers["series_s60"] = "/c/s60"
local updates_ok = true
p.api.request = function(_a, path)
    if path == "/api/updates" then return updates_ok and { content = { { series = { id = "s60", name = "Sixty" }, newCount = 2 } } } or nil end
    return { onDeck = {} }
end
check("placed, it is asked for, and a new row is a change", Widget.fetch(p) == true)
check("and saved", p.settings.home_rows.updates[1].newCount == 2)
updates_ok = false
check("a failed request keeps the saved row", Widget.fetch(p) == false and p.settings.home_rows.updates[1].id == "s60")
updates_ok = true

-- On this device: only when placed, no server, and Keep reading says what is behind the reader.
p.sync = { getDownloadedBookInfos = function() return { file(1, "s60"), file(5, "s60") } end }
Widget.drawn_rows = {}
check("not placed, no look at the files", Widget.scan(p) == false and p.settings.home_rows.device == nil)
Widget.drawn_rows = { device = true }
p.settings.home_rows.onDeck = { { seriesId = "s60", metadata = { numberSort = 5 } } }
local was_request = p.api.request
p.api.request = function() error("the device row needs no server") end
online = false
check("placed, a new row is a change", Widget.scan(p) == true)
online = true
p.api.request = was_request
check("what is behind the reader does not count", p.settings.home_rows.device[1].count == 1 and p.settings.home_rows.device[1].path == "/dl/s60/5")
check("the same files again are not a change", Widget.scan(p) == false)
check("a server answer leaves the device row alone", Widget.fetch(p) == false and p.settings.home_rows.device[1].path == "/dl/s60/5")

-- A failed answer keeps the saved rows, and the Wi-Fi step's fast mode is left alone.
local saved = p.settings.home_rows
p.api.request = function() return nil, "timeout" end
Widget.fetched_at = 0
p.api.fast, p.api.fast_dead = true, true
check("a failure changes nothing", Widget.fetch(p) == false and p.settings.home_rows == saved)
check("and is not dated, so it is retried", Widget.fetched_at == 0)
check("the caller's fast mode survives", p.api.fast == true and p.api.fast_dead == true)
p.api.fast, p.api.fast_dead = false, false

-- install: nothing happens without BookOrbit.
check("no BookOrbit, no install", Widget.install(p) == false and Widget.installed == false)
check("but the live plugin is known", Widget.plugin == p)

-- install: with BookOrbit's tables, and BookOrbit's own actions still reach it.
local W, LIBRARY, ran = {}, {}, {}
local Catalog = { boardRun = function(_m, action) table.insert(ran, action.kind) end }
package.loaded["bookorbit_board_widgets"] = { W = W }
package.loaded["bookorbit_board_edit"] = { LIBRARY = LIBRARY }
package.loaded["bookorbit_board_ui"] = {}
package.loaded["bookorbit_board_metrics"] = {}
package.loaded["bookorbit_catalog"] = Catalog
check("installs", Widget.install(p) == true)
local rows = #Widget.ROWS
for _i, def in ipairs(Widget.ROWS) do check("registered: " .. def.field, type(W[def.type]) == "function") end
check("registered: Continue manga", type(W[Widget.CONTINUE.type]) == "function")
check("in small sizes", LIBRARY[#LIBRARY].type == Widget.CONTINUE.type and LIBRARY[#LIBRARY].sizes[1] == "M")
check("offered in the list", #LIBRARY == rows + 1 and LIBRARY[1].type == Widget.TYPE and LIBRARY[1].sizes[1] == "L" and LIBRARY[1].tab == "library")
check("named", LIBRARY[1].name() == "Keep reading")
local run = Catalog.boardRun
local p2 = plugin_with({})
Widget.install(p2)
check("a second instance does not add them twice", #LIBRARY == rows + 1 and Catalog.boardRun == run)
check("and takes over as the live one", Widget.plugin == p2)
Catalog.boardRun({}, { kind = "search" })
check("BookOrbit's actions still reach BookOrbit", ran[1] == "search", ran[1])

-- Tapping: browser, settings, and each way of opening a chapter.
local opened, browsed, sheets, streamed, downloaded = {}, 0, 0, {}, {}
p2.onKouchiyomiBrowser = function() browsed = browsed + 1 end
p2.menu = { showSheet = function() sheets = sheets + 1 end }
p2.stream = { open = function(_s, b) table.insert(streamed, b.id) end }
p2.sync = {
    getBookLocalPath = function(_s, b) return "/dl/" .. b.id .. ".cbz" end,
    downloadBook = function(_s, b, _t, done) table.insert(downloaded, b.id); done("/dl/" .. b.id .. ".cbz") end,
}
local mode = "download"
p2.openModeFor = function() return mode end
local menu = { openDownloadedFile = function(_m, path) table.insert(opened, path) end }
Catalog.boardRun(menu, { kind = "kouchiyomi-browser" })
check("the book icon opens the browser", browsed == 1 and #ran == 1)
Catalog.boardRun(menu, { kind = "kouchiyomi-settings" })
check("the sliders icon opens the settings", sheets == 1 and #ran == 1)
local_files["/dl/b1.cbz"] = true
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b1" } })
check("a chapter on the device just opens", opened[1] == "/dl/b1.cbz" and #downloaded == 0)
local_pages["/dl/b1.cbz"] = 3
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b1", readProgress = { page = 8 } } })
check("at the page the card named", SyncClass.pending_goto_page == 8, SyncClass.pending_goto_page)
local_pages["/dl/b1.cbz"] = 12
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b1", readProgress = { page = 8 } } })
check("unless this device is further on", SyncClass.pending_goto_page == nil, SyncClass.pending_goto_page)
opened = {}
Catalog.boardRun(menu, { kind = "kouchiyomi-file", path = "/dl/x.cbz" })
check("On this device opens the file", opened[1] == "/dl/x.cbz", opened[1])
opened = { "/dl/b1.cbz" }
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b2" } })
check("otherwise it downloads, then opens", downloaded[1] == "b2" and opened[2] == "/dl/b2.cbz")
mode = "stream"
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b3" } })
check("or streams", streamed[1] == "b3" and #downloaded == 1)
local browsers, shown_series = 0, {}
p2.api.get_series = function(_a, id) return id == "s5" and { id = "s5" } or nil, "gone" end
p2.menu.openBrowser = function(_m, _off, ready)
    browsers = browsers + 1
    ready({ showBooksInSeries = function(_b, s) table.insert(shown_series, s.id) end })
end
local notes = {}
p2.notify = function(_p, text) table.insert(notes, text) end
Catalog.boardRun(menu, { kind = "kouchiyomi-series", series_id = "s5" })
check("a series opens in the browser", browsers == 1 and shown_series[1] == "s5")
Catalog.boardRun(menu, { kind = "kouchiyomi-series", series_id = "gone" })
check("a series the server will not give says so", browsers == 1 and #notes == 1, #notes)
check("none of those reached BookOrbit", #ran == 1, #ran)

-- Refreshing: only when stale and online, and only redraws a board that is really up.
local redraws = 0
Widget.noteBoard({})
p2.api.request = function() return { onDeck = { chapter(7) } } end
Widget.fetched_at = os.time()
Widget.refresh()
check("a fresh row is not asked for", p2.saves == 0, p2.saves)
Widget.markStale()
online = false
Widget.refresh()
check("nor anything offline", p2.saves == 0, p2.saves)

-- Redrawing: what is over the board must not lose the answer, and a closed board needs nothing.
local top, editing = false, false
local board = { boardIsTopmost = function() return top end, boardEditing = function() return editing end,
                updateItems = function() redraws = redraws + 1 end }
shown[board] = true
Widget.noteBoard(board)
scheduled = {}
local function run_scheduled()
    local list = scheduled
    scheduled = {}
    for _i, fn in ipairs(list) do fn() end
end
online = true
p2.api.request = function() return { onDeck = { chapter(7) } } end
p2.settings.home_rows = {}
Widget.drawn_rows = { onDeck = true }
covers["series_s7"] = "/c/s7"
Widget.markStale()
Widget.refresh()
check("a change with something over the board waits", redraws == 0 and #scheduled == 1, redraws)
Widget.markStale()
p2.api.request = function() return { onDeck = { chapter(7), chapter(1) } } end
Widget.refresh()
check("and a second answer does not start a second wait", #scheduled == 1, #scheduled)
run_scheduled()
check("still covered, it keeps waiting", redraws == 0 and #scheduled == 1, #scheduled)
editing, top = true, true
run_scheduled()
check("the edit screen counts as covered", redraws == 0 and #scheduled == 1, #scheduled)
editing = false
run_scheduled()
check("back on top, it redraws", redraws == 1 and #scheduled == 0, redraws)
Widget.markStale()
p2.api.request = function() return { onDeck = { chapter(8) } } end
Widget.refresh()
check("with the board on top, at once", redraws == 2, redraws)
shown[board] = nil
Widget.markStale()
p2.api.request = function() return { onDeck = { chapter(9) } } end
Widget.refresh()
check("a closed board is left alone", redraws == 2 and #scheduled == 0, redraws)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
