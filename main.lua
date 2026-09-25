--[[
    kouchiyomi: KOReader client for Uchiyomi.

    Browse your Uchiyomi library, download or stream chapters, and keep
    reading progress and page bookmarks in sync in both directions.

    Derived in part from kokomga (KOReader Komga client, MIT, Jim Davis).
--]]

if not unpack then unpack = table.unpack end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local logger = require("logger")

local API = require("uchi/api")
local Cache = require("uchi/cache")
local Sync = require("uchi/sync")
local Bookmarks = require("uchi/bookmarks")
local Stream = require("uchi/stream")
local SettingsMenu = require("uchi/menu")
local Updater = require("uchi/updater")
local i18n = require("uchi/i18n")

local Plugin = WidgetContainer:extend{
    name = "kouchiyomi",
    is_active = false,
    settings = nil,
    api = nil,
}

--[[
    Height/width at which a page stops being a page and becomes a strip.

    Measured across this library rather than guessed: manga sources (Weeb Central, MangaDex, MangaHub,
    TCB Scans and the hentai ones) run 1.40-1.50 with a single page at 1.99, while the webtoon sources
    (Toonily, Manhwa18.cc) sit at a median of ~20 and reach 45. Anything between 2 and 13 is nobody's
    house style, so the threshold sits in that gap with room on both sides.
--]]
local LONG_STRIP_RATIO = 2.5

local DEFAULT_SETTINGS = {
    server_url = "",
    username = "",
    api_token = "",
    opds_token = "",
    show_adult = false,

    open_mode = "download",          -- download | stream | ask
    offer_stream = false,
    auto_advance = true,             -- end of chapter: open the next one without asking when it is at hand
    prev_chapter_on_first_page = true, -- turning back from page 1 opens the previous chapter's last page
    read_ahead = 1,                  -- chapters to download in the background after opening one
    delete_read_on_advance = true,   -- drop a finished chapter's file once Uchiyomi has it as read
    -- ...but not the moment you turn the last page. A chapter you just read is
    -- the one you are most likely to want back: turning back from page 1 opens
    -- it, and a catch-up jump can land in it. It is kept this many days first
    -- (0 = straight away, the pre-0.7 behaviour).
    keep_read_chapters_days = 7,
    -- ...and however long ago they were read, the last few chapters finished in
    -- a series stay put. The grace period bounds how LONG a finished chapter
    -- survives; this bounds how MANY, which is the half that keeps a series
    -- you are working through from thinning out behind you (0 = off).
    keep_newest_chapters = 3,
    footer_sync_indicator = true,
    -- rtl | ltr | auto | off. Manga reads right-to-left, so that is the default: the tap zone on the
    -- RIGHT turns FORWARD. "auto" follows the series' own readingDirection, which sounds better than it
    -- is -- Uchiyomi's BFF hardcodes WEBTOON for every owned series (lib/ownedCatalog.ts seriesDto), so
    -- "auto" reads left-to-right on everything, which is what sent this setting to RTL by default.
    reading_direction = "rtl",
    -- Per-document defaults seeded into a chapter's sidecar as it downloads. "leave" means KOReader's own
    -- default stands. Only the ones worth having an opinion about for manga are here: panel zoom is
    -- already on for .cbz (readerhighlight initializeExtSettings) and page crop already defaults to auto
    -- (DKOPTREADER_CONFIG_TRIM_PAGE = 1), so neither needed a knob until you want them OFF.
    -- View mode is the exception that ships with an opinion: KOReader opens a comic in continuous
    -- scroll (koptoptions page_scroll default 1), which is a webtoon's reading, not a manga's. "auto"
    -- decides per series from the shape of the pages -- see LONG_STRIP_RATIO.
    chapter_view_mode = "auto",      -- auto | page | continuous | leave  (kopt_page_scroll)
    long_strip_series = {},          -- series id -> true/false, learned from the pages themselves
    chapter_page_crop = "leave",     -- auto | none | leave         (kopt_trim_page)
    chapter_dithering = "leave",     -- on | off | leave            (kopt_hw_dithering)
    chapter_ui_mirror = "leave",     -- match | off | leave         (invert_ui_layout)

    sync_progress = true,
    sync_bookmarks = true,
    sync_forward = "silent",         -- prompt | silent | disable
    sync_backward = "prompt",
    -- Uchiyomi is on a LATER CHAPTER of the series than the one being opened
    -- (read on the phone, say). Asking is the default: jumping chapters closes
    -- the document that was just deliberately opened, which is too big a move
    -- to make without a word.
    sync_series_catchup = "prompt",  -- prompt | silent | disable
    push_interval = 5,
    reconcile_on_connect = true,

    download_dir = "",
    download_to_subfolder = true,
    max_download_gb = 0,

    cache_covers = true,
    never_update_covers = false,
    show_covers = true,
    view_mode = "list",
    list_rows = 5,

    update_repo = "Squeaks72/kouchiyomi.koplugin",
    update_ref = "main",
    github_token = "",
    update_auto_check = true,
    update_last_check = 0,
    grid_columns = 3,
    grid_rows = 3,

    library_metadata_cache = {},
    matched_books_cache = {},
    downloaded_books = {},
    offline_progress_buffer = {},
    offline_bookmark_ops = {},
    bookmark_snapshots = {},
    next_chapter_cache = {},
    prev_chapter_cache = {},
    pending_cleanup = {},
}

function Plugin:init()
    self.i18n = i18n
    self:loadSettings()
    self:initAPI()
    self.cache = Cache:new(self)
    self.sync = Sync:new(self)
    self.bookmarks = Bookmarks:new(self)
    self.stream = Stream:new(self)
    self.menu = SettingsMenu:new(self)
    self.updater = Updater:new(self)
    self.ui.menu:registerToMainMenu(self)
    self:registerActions()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isOnline() then self.updater:maybeAutoCheck() end
    logger.info("kouchiyomi: initialised")
end

function Plugin:loadSettings()
    local path = DataStorage:getSettingsDir() .. "/kouchiyomi.lua"
    self.settings_file = LuaSettings:open(path)
    self.settings = {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        local saved = self.settings_file:readSetting(k)
        if saved ~= nil then self.settings[k] = saved else self.settings[k] = v end
    end

    -- Up to v0.2.0 this was `auto_reading_direction`, a checkbox meaning "follow the series". Following
    -- the series is what read every manga left-to-right, so an install that had it on lands on the new
    -- RTL default; one that had deliberately turned it off still has KOReader left alone.
    if self.settings_file:readSetting("reading_direction") == nil then
        local legacy = self.settings_file:readSetting("auto_reading_direction")
        self.settings.reading_direction = (legacy == false) and "off" or "rtl"
    end
    -- A function, not a table: what a chapter should be seeded with depends on which series it belongs
    -- to, and uchi/sidecar is the only place that knows that at download time.
    require("uchi/sidecar").doc_defaults = function(book)
        return self:docDefaults(book and book.seriesId)
    end
end

--[[
    What `inverse_reading_order` an Uchiyomi chapter should open with: true = right-to-left, false =
    left-to-right, nil = whatever KOReader would have done.

    `dir` is the series' readingDirection when we have one, and only "auto" consults it.
--]]
function Plugin:wantInverseReadingOrder(dir)
    local mode = self.settings and self.settings.reading_direction or "rtl"
    if mode == "rtl" then return true end
    if mode == "ltr" then return false end
    if mode == "auto" then
        if dir == "RIGHT_TO_LEFT" then return true end
        if dir == "LEFT_TO_RIGHT" then return false end
        return nil          -- WEBTOON, or no metadata at all: not our call to make
    end
    return nil              -- "off"
end

--[[
    Whether this document's pages are long strips (a webtoon) rather than pages (manga), by measuring
    them. Returns nil when the document cannot say.

    Three pages, not one: a cover or a credits page is often a normal page in an otherwise long-strip
    chapter -- the sampling of this library turned up a 1.79 among Manhwa18.cc's ~20s -- so the middle
    value decides and a single odd page cannot swing it.
--]]
local function measureLongStrip(doc)
    if not (doc and doc.getNativePageDimensions and doc.getPageCount) then return nil end
    local ok, count = pcall(doc.getPageCount, doc)
    if not ok or not count or count < 1 then return nil end
    local ratios = {}
    for _i, pageno in ipairs({ 1, math.ceil(count / 2), count }) do
        local got, dim = pcall(doc.getNativePageDimensions, doc, pageno)
        if got and dim and dim.w and dim.h and dim.w > 0 then
            table.insert(ratios, dim.h / dim.w)
        end
    end
    if #ratios == 0 then return nil end
    table.sort(ratios)
    return ratios[math.ceil(#ratios / 2)] >= LONG_STRIP_RATIO
end

-- Exposed for tests/settings.lua: the threshold and the median-of-three are the parts that would go
-- wrong quietly, reading a whole library in the wrong mode without erroring once.
Plugin._measureLongStrip = measureLongStrip

--[[
    Whether the reader's own furniture -- the progress bar, and the layout mirroring KOReader applies
    inside the reader -- should be flipped to match right-to-left reading. nil = leave KOReader alone.

    "match" follows the page turning direction, so it says nothing when the direction is itself being
    left alone or when "auto" has no series metadata to go on.
--]]
function Plugin:wantInvertUILayout(dir)
    local mode = self.settings and self.settings.chapter_ui_mirror or "leave"
    if mode == "match" then return self:wantInverseReadingOrder(dir) end
    if mode == "off" then return false end
    return nil
end

--[[
    The doc settings a freshly downloaded chapter should start life with, as KOReader's own sidecar keys.

    Seeded at download time (uchi/sidecar) rather than applied after opening, because KOReader reads all
    of these in ReaderView/ReaderZooming onReadSettings -- a chapter that arrives with them set is right
    on the first paint, with no toggle, no re-render and no notification. A chapter already on the device
    has its own values from the last time it was closed, so only reading direction (which this plugin
    enforces on open) reaches back to those.
--]]
function Plugin:docDefaults(series_id)
    local s = self.settings or {}
    local t = {}

    local rtl = self:wantInverseReadingOrder()
    if rtl ~= nil then t.inverse_reading_order = rtl end

    -- KOReader opens a fresh comic in continuous (scroll) view: koptoptions' page_scroll defaults to 1.
    -- That is right for a webtoon's long strips and wrong for manga pages, which want one page per turn.
    --
    -- "auto" can only seed a series it has already seen: the shape of the pages is not knowable until a
    -- chapter is open. The first chapter of a series therefore opens on KOReader's default and is
    -- corrected in the open hook, which records the answer; every chapter downloaded after that arrives
    -- already right.
    local view = s.chapter_view_mode
    if view == "auto" then
        local long = series_id and (s.long_strip_series or {})[series_id]
        if long ~= nil then t.kopt_page_scroll = long and 1 or 0 end
    elseif view == "page" then t.kopt_page_scroll = 0
    elseif view == "continuous" then t.kopt_page_scroll = 1 end

    -- trim_page: 3 = none, 1 = auto (koptoptions L99-110). Auto is already the global default; "none" is
    -- here for full-bleed colour pages, where cropping eats art that reaches the edge.
    if s.chapter_page_crop == "auto" then t.kopt_trim_page = 1
    elseif s.chapter_page_crop == "none" then t.kopt_trim_page = 3 end

    -- Hardware dithering: the Libra 2 (Mk7) can do it, and scan gradients band badly without it.
    if s.chapter_dithering == "on" then t.kopt_hw_dithering = 1
    elseif s.chapter_dithering == "off" then t.kopt_hw_dithering = 0 end

    local mirror = self:wantInvertUILayout()
    if mirror ~= nil then t.invert_ui_layout = mirror end

    return t
end

function Plugin:saveSettings()
    if not self.settings_file then return end
    for k, v in pairs(self.settings) do self.settings_file:saveSetting(k, v) end
    self.settings_file:flush()
end

function Plugin:initAPI()
    local s = self.settings
    if s.server_url ~= "" and s.api_token ~= "" then
        self.api = API:new(s.server_url, {
            api_token = s.api_token,
            username = s.username,
            opds_token = s.opds_token,
            show_adult = s.show_adult,
        })
    else
        self.api = nil
    end
end

function Plugin:registerActions()
    Dispatcher:registerAction("kouchiyomi_browser", {
        category = "none", event = "KouchiyomiBrowser", title = i18n._("Uchiyomi browser"), general = true,
    })
    Dispatcher:registerAction("kouchiyomi_sync", {
        category = "none", event = "KouchiyomiSync", title = i18n._("Uchiyomi: sync this chapter"), reader = true,
    })
end

function Plugin:onKouchiyomiBrowser()
    self.menu:openBrowser(false)
    return true
end

function Plugin:onKouchiyomiSync()
    if self.ui and self.ui.document then
        self.sync:pullProgress(self.ui, true)
        self.bookmarks:syncOpenDocument(self.ui, true)
    end
    return true
end

--- Plain-text state dump for Tools > Uchiyomi > Diagnostics.
function Plugin:diagnosticsText()
    local NetworkMgr = require("ui/network/manager")
    local meta_ok, meta = pcall(dofile, self.path .. "/_meta.lua")
    local lines = {
        "kouchiyomi " .. tostring(meta_ok and meta and meta.version or "?"),
        "Server: " .. ((self.settings.server_url ~= "" and self.settings.server_url) or "not set")
            .. (self.api and "" or " (no API token)"),
        "Online: " .. tostring(NetworkMgr:isOnline()),
        "Download folder: " .. tostring(self:getDownloadDir() or "?"),
    }
    local ui = self.ui
    local file = ui and ui.document and ui.document.file
    if file then
        local id = self.sync:getOrMatchBook(file)
        table.insert(lines, "")
        table.insert(lines, "Open file: " .. file)
        table.insert(lines, "Linked to Uchiyomi book: " .. tostring(id or "NOT LINKED"))
        table.insert(lines, "Inside download folder: " .. tostring(self.sync:isUnderDownloadDir(file)))
        if self.autolink_failure then table.insert(lines, "Auto-link: " .. self.autolink_failure) end
        table.insert(lines, "End-of-chapter hook installed: " .. tostring(ui.status ~= nil and ui.status._kouchiyomi_hooked == true))
        local paging = ui.paging or ui.rolling
        table.insert(lines, "Start-of-chapter hook installed: " .. tostring(paging ~= nil and paging._kouchiyomi_prev_hooked == true)
            .. (self.last_start_of_chapter and ("  (last: " .. self.last_start_of_chapter .. ")") or ""))
        if ui.status and ui.status.orig_onEndOfBook ~= nil then
            table.insert(lines, "ANOTHER plugin also hooks end of book (kokomga?) -- ours now runs first")
        end
        pcall(function()
            local PluginLoader = require("pluginloader")
            local names = {}
            for name in pairs(PluginLoader.loaded_plugins or {}) do
                if name:lower():find("komga") or name:lower():find("uchi") then table.insert(names, name) end
            end
            table.sort(names)
            table.insert(lines, "Related plugins loaded: " .. table.concat(names, ", "))
        end)
        table.insert(lines, "Last end-of-chapter outcome: " .. tostring(self.last_end_of_chapter or "none yet in this chapter"))
        table.insert(lines, "Last series catch-up outcome: " .. tostring(self.last_catchup or "not asked in this chapter"))
        local page = ui.view and ui.view.state and ui.view.state.page
        local total = ui.document.getPageCount and ui.document:getPageCount()
        table.insert(lines, "Page: " .. tostring(page) .. " / " .. tostring(total))
    else
        table.insert(lines, "")
        table.insert(lines, "No document open.")
    end
    local n = 0
    for _ in pairs(self.settings.matched_books_cache or {}) do n = n + 1 end
    table.insert(lines, "")
    table.insert(lines, "Linked files known: " .. n)
    table.insert(lines, "Pending offline progress: " .. self.sync:countOfflineBuffer())
    table.insert(lines, "Pending offline bookmarks: " .. self.bookmarks:countOffline())
    table.insert(lines, "Background downloads running: " .. self.sync:backgroundJobCount())
    local pc = 0
    for _ in pairs(self.settings.pending_cleanup or {}) do pc = pc + 1 end
    table.insert(lines, "Finished chapters awaiting cleanup: " .. pc)
    local keep = tonumber(self.settings.keep_read_chapters_days) or 0
    local newest = tonumber(self.settings.keep_newest_chapters) or 0
    table.insert(lines, "Read ahead: " .. tostring(self.settings.read_ahead)
        .. "  Delete when read: " .. tostring(self.settings.delete_read_on_advance ~= false)
        .. (keep > 0 and (" after " .. keep .. "d") or " straight away")
        .. (newest > 0 and ("  Always keep last read: " .. newest .. "/series") or "")
        .. "  Auto-advance: " .. tostring(self.settings.auto_advance ~= false))
    local text = table.concat(lines, "\n")
    logger.info("kouchiyomi diagnostics:\n" .. text)
    return text
end

function Plugin:notify(message, kind)
    if kind == "error" then logger.warn("kouchiyomi:", message) else logger.info("kouchiyomi:", message) end
    UIManager:show(InfoMessage:new{ text = "[Uchiyomi] " .. message, timeout = kind == "error" and 5 or 3 })
end

function Plugin:getDownloadDir()
    if self.settings.download_dir and self.settings.download_dir ~= "" then
        return self.settings.download_dir
    end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and home ~= "" then
        local dir = home .. "/Uchiyomi"
        pcall(function() require("util").makePath(dir .. "/") end)
        return dir
    end
    self:notify(i18n._("Set a home folder in KOReader (or a download folder in the plugin settings) first."), "error")
    return nil
end

function Plugin:addToMainMenu(menu_items)
    menu_items.kouchiyomi = {
        text = "Uchiyomi",
        sorting_hint = "search",
        keep_menu_open = true,
        sub_item_table_func = function() return self.menu:createMainMenu() end,
    }
end

-- ---------------------------------------------------------------------------
-- Reader lifecycle
-- ---------------------------------------------------------------------------

function Plugin:onReaderReady()
    local ui = self.ui
    local filepath = ui and ui.document and ui.document.file
    local _ = i18n._
    local T = i18n.T
    self.is_active = true
    self.current_book_id = filepath and self.sync:getOrMatchBook(filepath) or nil
    self.last_pushed_page = ui and ui.view and ui.view.state and ui.view.state.page or 1
    self.last_end_of_chapter = nil
    self.last_start_of_chapter = nil
    local NetworkMgr = require("ui/network/manager")

    -- A chapter that reached the device some other way (syncthing, USB) is
    -- not linked yet; try to bind it by folder and file name.
    if not self.current_book_id and filepath and self.api and self.sync:isUnderDownloadDir(filepath) and NetworkMgr:isOnline() then
        local ok, id, book_or_err = pcall(self.sync.autoLinkFile, self.sync, filepath)
        if ok and id then
            self.current_book_id = id
            self:notify(T(_("Linked to Uchiyomi: %1"), Sync.book_title(book_or_err)), "info")
        else
            self.autolink_failure = ok and tostring(book_or_err) or ("error: " .. tostring(id))
            logger.warn("kouchiyomi: auto-link failed for", filepath, self.autolink_failure)
        end
    end

    -- End-of-book hook. We wrap whatever handler is on the status module at
    -- this moment, which may already be another plugin's wrapper (kokomga
    -- uses the very same trick and loads before us alphabetically); ours
    -- runs first and only defers to it when we decline. Every way this can
    -- decline is recorded (Tools > Uchiyomi > Diagnostics).
    if ui.status and not ui.status._kouchiyomi_hooked then
        ui.status._kouchiyomi_hooked = true
        local previous = ui.status.onEndOfBook
        ui.status._kouchiyomi_previous_onEndOfBook = previous
        ui.status.onEndOfBook = function(this, ...)
            local args = { ... }
            local show_native = function()
                if previous then previous(this, unpack(args)) end
            end
            if self:_handleEndOfBook(ui, show_native) then
                -- handled: the event stops here and onEndOfBook below never
                -- runs, so leave no marker behind for the next event
                self._eob_fell_through = nil
                return true
            end
            -- Falling through: the next handler (another plugin's or
            -- KOReader's own) runs; onEndOfBook below must not run again.
            self._eob_fell_through = true
            if previous then return previous(this, ...) end
        end
    end

    -- Back past the first page opens the previous chapter (see below).
    self:_installPrevChapterHook(ui)

    -- Something asked to open this document at a given page: a bookmark tapped
    -- in the browser, a turn back into the previous chapter (pending_goto_last:
    -- the last page, whose number is only knowable here), or a catch-up jump to
    -- where Uchiyomi left off. Claimed before anything can return early, so a
    -- request never leaks into the document opened after this one -- and on the
    -- class, because the instance that made it is gone by the time we run.
    local goto_page = self.pending_goto_page or Sync.pending_goto_page
    self.pending_goto_page = nil
    Sync.pending_goto_page = nil
    if Sync.pending_goto_last then
        Sync.pending_goto_last = nil
        local last = ui.document and ui.document.getPageCount and ui.document:getPageCount()
        if last and last > 0 then goto_page = last end
    end
    if goto_page then
        UIManager:nextTick(function()
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("GotoPage", goto_page))
        end)
    end

    if not self.current_book_id then return end

    -- Reading direction. Chapters downloaded from here are seeded at download time (uchi/sidecar), so
    -- this is the path that catches everything already on the device -- and the one that turns RTL back
    -- off if the setting changes. `onToggleReadingOrder(want)` is a no-op when it already matches, so a
    -- chapter that opened right the first time never shows the "RTL page turning." toast.
    pcall(function()
        local Sidecar = require("uchi/sidecar")
        local ds = Sidecar.openDocSettings(filepath, false)
        local dir = ds and ds:readSetting("uchiyomi_reading_direction")
        if not dir then
            local cm = Sidecar.loadCustomMetadata(filepath)
            dir = cm and cm.uchiyomi_reading_direction
        end
        local want = self:wantInverseReadingOrder(dir)
        if want ~= nil and ui.view then
            ui.view:onToggleReadingOrder(want)
            if ui.doc_settings then ui.doc_settings:saveSetting("inverse_reading_order", want) end
        end

        -- Same reach-back as the direction, and the same shape of call: onToggleUILayoutMiroring takes
        -- an explicit boolean and does nothing when it already matches. (The upstream method name is
        -- misspelled with one r -- readerview.lua L1003 -- so this is not a typo to fix.)
        local mirror = self:wantInvertUILayout(dir)
        if mirror ~= nil and ui.view and ui.view.onToggleUILayoutMiroring then
            ui.view:onToggleUILayoutMiroring(mirror)
            if ui.doc_settings then ui.doc_settings:saveSetting("invert_ui_layout", mirror) end
        end

        -- View mode reaches back into chapters downloaded before the setting existed, because it has a
        -- clean event to do it with. The other seeded defaults (crop, dithering) need the document
        -- re-rendered, so they only apply to chapters downloaded from here on.
        local scroll = self.settings.chapter_view_mode
        local want_scroll
        if scroll == "auto" then
            want_scroll = measureLongStrip(ui.document)
            if want_scroll ~= nil then
                -- Remembered per series so the rest of its chapters can be seeded at download time
                -- instead of each one being measured and flipped on its first open.
                local sid = ds and ds:readSetting("uchiyomi_series_id")
                if sid and (self.settings.long_strip_series or {})[sid] ~= want_scroll then
                    self.settings.long_strip_series = self.settings.long_strip_series or {}
                    self.settings.long_strip_series[sid] = want_scroll
                    self:saveSettings()
                    require("uchi/sidecar").doc_defaults = function(book)
                        return self:docDefaults(book and book.seriesId)
                    end
                end
            end
        elseif scroll == "page" or scroll == "continuous" then
            want_scroll = scroll == "continuous"
        end
        if want_scroll ~= nil and ui.view then
            if ui.view.page_scroll ~= want_scroll then
                local Event = require("ui/event")
                ui:handleEvent(Event:new("SetScrollMode", want_scroll))
                -- onSetScrollMode does not persist it; without this the next open reverts.
                if ui.doc_settings then ui.doc_settings:saveSetting("kopt_page_scroll", want_scroll and 1 or 0) end
            end
        end
    end)

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isOnline() then
        if next(self.settings.offline_progress_buffer or {}) then self.sync:flushOfflineProgress(false) end
        self.bookmarks:flushOffline()
        -- Not when we were told where to open: that page IS the answer, and
        -- asking the server again would only argue with it.
        if not goto_page then self.sync:syncOnOpen(ui) end
        self.bookmarks:syncOpenDocument(ui, false)
        -- The chapter we just moved on from may go now that Uchiyomi has it.
        pcall(self.sync.processCleanup, self.sync)
    end
    self:_installFooterIndicator(ui)
    -- Read ahead once the first page is on screen: remember the next chapter
    -- (for when Wi-Fi is gone later) and fetch the next N in the background.
    UIManager:scheduleIn(4, function()
        if not self.is_active or not self.current_book_id then return end
        if not NetworkMgr:isOnline() then return end
        local ok, err = pcall(self.sync.readAhead, self.sync, self.current_book_id, self.settings.read_ahead)
        if not ok then logger.warn("kouchiyomi: read-ahead failed:", tostring(err)) end
    end)
end

--- "⇅3" (changes waiting to sync) and "↓1" (background downloads) in
-- KOReader's footer, only while something is pending.
function Plugin:_installFooterIndicator(ui)
    if self.settings.footer_sync_indicator == false then return end
    local footer = ui and ui.footer
    if not footer or not footer.addAdditionalFooterContent or self._footer_fn then return end
    self._footer_fn = function()
        local parts = {}
        local n = self.sync:countOfflineBuffer() + self.bookmarks:countOffline()
        if n > 0 then table.insert(parts, "\u{21C5}" .. n) end
        local jobs = self.sync:backgroundJobCount()
        if jobs > 0 then table.insert(parts, "\u{2193}" .. jobs) end
        return table.concat(parts, " ")
    end
    pcall(footer.addAdditionalFooterContent, footer, self._footer_fn)
end

function Plugin:_removeFooterIndicator()
    local footer = self.ui and self.ui.footer
    if self._footer_fn and footer and footer.removeAdditionalFooterContent then
        pcall(footer.removeAdditionalFooterContent, footer, self._footer_fn)
    end
    self._footer_fn = nil
end

--[[
    Where the reader is, precisely enough to tell "the page turned" from "the
    turn had nowhere to go". A backward turn at the very start of a document
    changes nothing at all, which is how the start of a chapter is recognised:
    KOReader raises EndOfBook at the end but has no event for the other end --
    ReaderPaging:onGotoPageRel simply leaves the view where it is.
--]]
local function position_key(module)
    local view = module.view
    if not view then return nil end
    if module.current_pos ~= nil then       -- ReaderRolling (epub and friends)
        return table.concat({ "r", tostring(module.current_pos), tostring(module.current_page) }, ":")
    end
    if view.page_scroll and view.page_states then
        local first = view.page_states[1]
        if not first then return nil end
        return table.concat({ "s", tostring(first.page),
            tostring(first.visible_area and first.visible_area.y), tostring(#view.page_states) }, ":")
    end
    local va = view.visible_area
    return table.concat({ "p", tostring(module.current_page),
        tostring(va and va.x), tostring(va and va.y) }, ":")
end

--[[
    Every backward page turn -- the swipe, the tap zone and the page keys alike
    -- reaches the paging module through onGotoViewRel(-1), so that one call is
    wrapped: if it moved nothing, the reader was on the first page and asked to
    go further back, which is our cue to open the previous chapter.

    Deliberately not KOReader's "go back" gesture or a new gesture of our own:
    the ask is for the page turn itself to carry on across the chapter break,
    the way it does at the other end.
--]]
function Plugin:_installPrevChapterHook(ui)
    local module = ui and (ui.paging or ui.rolling)
    if not module or module._kouchiyomi_prev_hooked then return end
    module._kouchiyomi_prev_hooked = true
    local orig = module.onGotoViewRel
    if type(orig) ~= "function" then return end
    module.onGotoViewRel = function(this, diff, no_page_turn, ...)
        -- no_page_turn = true is ReaderSearch asking "would this turn a page?";
        -- it is not a reader going anywhere. (When a key event calls this, the
        -- second argument is the key object, hence the explicit == true.)
        local backwards = type(diff) == "number" and diff < 0 and no_page_turn ~= true
        local before = backwards and position_key(this) or nil
        local ret = orig(this, diff, no_page_turn, ...)
        if before and before == position_key(this) then
            self:_handleStartOfBook(ui)
        end
        return ret
    end
end

--- The start-of-chapter decision, the mirror of _handleEndOfBook: hand over to
-- the previous chapter when this is a linked Uchiyomi chapter and the setting
-- is on, and otherwise leave the turn as the no-op it already was.
function Plugin:_handleStartOfBook(ui)
    if self.settings.prev_chapter_on_first_page == false then return end
    if not self.is_active or not self.current_book_id then
        self.last_start_of_chapter = self.is_active and "not a Uchiyomi chapter" or "plugin inactive"
        return
    end
    if self._prev_chapter_busy then return end
    self._prev_chapter_busy = true
    -- Released on the next tick, not at the end of this call: a download or a
    -- wait for one returns straight away and must not wedge the hook shut.
    UIManager:nextTick(function() self._prev_chapter_busy = false end)
    local ok, handled, reason = pcall(self.sync.openPreviousChapter, self.sync, ui)
    if not ok then
        self.last_start_of_chapter = "error: " .. tostring(handled)
        logger.warn("kouchiyomi: previous-chapter handler failed:", tostring(handled))
        self:notify(i18n.T(i18n._("Could not open the previous chapter: %1"), tostring(handled)), "error")
    elseif handled then
        self.last_start_of_chapter = "handled"
    else
        self.last_start_of_chapter = "declined: " .. tostring(reason)
    end
end

--- The end-of-chapter decision. Returns true when we took over (our dialog
-- or auto-advance), false to let KOReader's end-of-document action run.
function Plugin:_handleEndOfBook(ui, show_native)
    local _ = i18n._
    local T = i18n.T
    if self.is_active and self.current_book_id then
        local ok, handled, reason = pcall(self.sync.promptNextChapter, self.sync, ui, show_native)
        if ok and handled then
            self.last_end_of_chapter = "handled"
            return true
        end
        if not ok then
            self.last_end_of_chapter = "error: " .. tostring(handled)
            logger.warn("kouchiyomi: end-of-chapter handler failed:", tostring(handled))
            self:notify(T(_("End-of-chapter handling failed: %1"), tostring(handled)), "error")
        else
            self.last_end_of_chapter = "declined: " .. tostring(reason)
        end
        return false
    elseif self.is_active and self.api and self.sync:isUnderDownloadDir(ui.document and ui.document.file) then
        self.last_end_of_chapter = "not linked"
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = _("This chapter is not linked to Uchiyomi, so it cannot be marked read there or followed by the next chapter.")
                .. (self.autolink_failure and ("\n(" .. self.autolink_failure .. ")") or ""),
            buttons = {
                { { text = _("Link it now..."), is_enter_default = true,
                    callback = function() UIManager:close(dialog); self.sync:matchCurrentBook() end } },
                { { text = _("Default action"), callback = function() UIManager:close(dialog); show_native() end },
                  { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
            },
        }
        UIManager:show(dialog)
        return true
    end
    self.last_end_of_chapter = self.is_active and "not a Uchiyomi chapter" or "plugin inactive"
    return false
end

--- Second line of defence: the EndOfBook event also reaches us as a reader
-- module, after the status module. If our wrapper above never ran (another
-- plugin replaced the handler after us, or a KOReader change), handle it
-- here and take KOReader's own dialog down from under ours.
function Plugin:onEndOfBook()
    if self._eob_fell_through ~= nil then
        -- our wrapper ran for this event (it either handled it, in which case
        -- the event would not have reached us, or deliberately fell through)
        self._eob_fell_through = nil
        return
    end
    if not self.is_active then return end
    self.last_end_of_chapter = "wrapper bypassed; handled by fallback"
    logger.warn("kouchiyomi: end-of-book wrapper was bypassed, using the fallback path")
    local top = UIManager:getTopmostVisibleWidget()
    local native = top and top.name == "end_document" and top or nil
    local handled = self:_handleEndOfBook(self.ui, function() end)
    if handled and native then UIManager:close(native) end
    return handled or nil
end

function Plugin:_push()
    if not self.is_active or not self.current_book_id or not self.ui or not self.ui.document then return end
    self.sync:pushProgressForDocument(self.ui)
end

function Plugin:onPageUpdate(page)
    if not self.current_book_id or type(page) ~= "number" then return end
    local interval = tonumber(self.settings.push_interval) or 5
    if self.last_pushed_page and math.abs(page - self.last_pushed_page) < interval then return end
    self.last_pushed_page = page
    self:_push()
end

function Plugin:onCloseDocument()
    self:_push()
    self:_removeFooterIndicator()
    if self.current_book_id and self.ui then
        pcall(function() self.bookmarks:syncOpenDocument(self.ui, false) end)
    end
    self.is_active = false
    self.current_book_id = nil
end

function Plugin:onSuspend()
    self:_push()
end

function Plugin:onAnnotationsModified(items)
    if not self.current_book_id or not self.ui then return end
    pcall(function() self.bookmarks:onAnnotationsModified(self.ui, items) end)
end

function Plugin:onNetworkConnected()
    if self.updater then self.updater:maybeAutoCheck() end
    if not self.api then return end
    UIManager:scheduleIn(2, function()
        if next(self.settings.offline_progress_buffer or {}) then self.sync:flushOfflineProgress(false) end
        self.bookmarks:flushOffline()
        if self.is_active and self.current_book_id and self.ui and self.ui.document then
            self.sync:pullProgress(self.ui, false)
            self.bookmarks:syncOpenDocument(self.ui, false)
        end
        if self.settings.reconcile_on_connect ~= false then
            self.sync:reconcileDownloaded(false)
        end
        pcall(self.sync.processCleanup, self.sync)
        if self.is_active and self.current_book_id then
            pcall(self.sync.readAhead, self.sync, self.current_book_id, self.settings.read_ahead)
        end
    end)
end

return Plugin
