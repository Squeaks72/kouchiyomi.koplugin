--[[
    The Keep reading widget for BookOrbit's home screen: what the row holds, what it asks of the server, and that its
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
package.preload["uchi/i18n"] = function() return { _ = function(s) return s end } end
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

-- The row: order kept, bounded, 18+ out.
local deck = {}
for n = 1, 20 do deck[n] = chapter(n) end
local rail = Widget.railFrom(deck)
check("the rail's order is kept", rail[1].id == "b1" and rail[2].id == "b2")
check("bounded", #rail == Widget.KEEP, #rail)
rail = Widget.railFrom({ chapter(1), chapter(2), chapter(3) }, function(sid) return sid == "s2" end)
check("a series known to be 18+ is left out", #rail == 2 and rail[2].id == "b3", #rail)
check("nothing on deck is an empty row", #Widget.railFrom(nil) == 0)

-- The cards: dismissed, captions, covers.
local cards = Widget.cards({ Widget.slim(chapter(1)), Widget.slim(chapter(2)) }, { b1 = true }, function(b) return "/c/" .. b.id end)
check("a dismissed chapter stays off", #cards == 1 and cards[1].book.id == "b2", #cards)
check("captioned with its series", cards[1].title == "Series 2", cards[1].title)
check("with its cover", cards[1].cover_path == "/c/b2")
check("no row is no cards", #Widget.cards(nil) == 0 and #Widget.cards({}, nil) == 0)

-- A plugin and a board, for the rest.
local function plugin_with(home)
    local p = {
        settings = { keep_reading_rail = {} }, saves = 0, asked = {},
        saveSettings = function(self) self.saves = self.saves + 1 end,
        cache = { cacheThumbnail = function(_c, kind, id) covers[kind .. "_" .. id] = "/c/" .. id; return "/c/" .. id end },
    }
    p.api = { request = function(self, path)
        table.insert(p.asked, path)
        p.fast_during = self.fast
        return home
    end }
    return p
end

-- The request: never adult=1, whatever "show 18+ in listings" is doing to get_home.
local p = plugin_with({ onDeck = { chapter(1), chapter(2) } })
p.api.get_home = function() error("must not use get_home") end
local changed = Widget.fetch(p)
check("asks /api/home with no adult=1", p.asked[1] == "/api/home", p.asked[1])
check("on short timeouts", p.fast_during == true)
check("and leaves them as it found them", not p.api.fast)
check("the row is saved", #p.settings.keep_reading_rail == 2 and p.saves == 1)
check("a new row is a change", changed == true)
check("missing covers are fetched", covers["series_s1"] == "/c/s1")
check("the answer is dated", Widget.fetched_at > 0)
check("the same row again is not", Widget.fetch(p) == false)
covers["series_s9"] = nil
p.api.request = function() return { onDeck = { chapter(2), chapter(1) } } end
check("a reordered row is a change", Widget.fetch(p) == true)

-- A failed answer keeps the saved row, and the Wi-Fi step's fast mode is left alone.
local saved = p.settings.keep_reading_rail
p.api.request = function() return nil, "timeout" end
Widget.fetched_at = 0
p.api.fast, p.api.fast_dead = true, true
check("a failure changes nothing", Widget.fetch(p) == false and p.settings.keep_reading_rail == saved)
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
check("registered as a widget", type(W[Widget.TYPE]) == "function")
check("offered in the list", #LIBRARY == 1 and LIBRARY[1].type == Widget.TYPE and LIBRARY[1].sizes[1] == "L" and LIBRARY[1].tab == "library")
check("named", LIBRARY[1].name() == "Keep reading")
local run = Catalog.boardRun
local p2 = plugin_with({})
Widget.install(p2)
check("a second instance does not add it twice", #LIBRARY == 1 and Catalog.boardRun == run)
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
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b2" } })
check("otherwise it downloads, then opens", downloaded[1] == "b2" and opened[2] == "/dl/b2.cbz")
mode = "stream"
Catalog.boardRun(menu, { kind = "kouchiyomi-open", book = { id = "b3" } })
check("or streams", streamed[1] == "b3" and #downloaded == 1)
check("none of those reached BookOrbit", #ran == 1, #ran)

-- Refreshing: only when stale and online, and only redraws a board that is really up.
local redraws = 0
local board = { boardIsTopmost = function() return true end, boardEditing = function() return false end,
                updateItems = function() redraws = redraws + 1 end }
p2.api.request = function() return { onDeck = { chapter(7) } } end
Widget.fetched_at = os.time()
Widget.refresh()
check("a fresh row is not asked for", p2.saves == 0, p2.saves)
Widget.markStale()
online = false
Widget.refresh()
check("nor anything offline", p2.saves == 0, p2.saves)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
