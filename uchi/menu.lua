--[[
    Settings menu (Tools > kouchiyomi) and the server setup dialogs.
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")

local Menu = {}

function Menu:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

local function cycle_label(_, value, labels)
    return labels[value] or labels.__default
end

--- The settings tree as a sheet of its own (see uchi/settings_sheet); `open_index` opens that row's submenu.
function Menu:showSheet(open_index)
    return require("uchi/settings_sheet").open(self.plugin, open_index)
end

function Menu:createMainMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local items = {}
    if p.updater then p.updater:maybeAutoCheck() end

    table.insert(items, {
        text = _("Uchiyomi browser"),
        callback = function()
            local NetworkMgr = require("ui/network/manager")
            if not NetworkMgr:isOnline() then
                p:notify(_("Offline: showing downloaded chapters."), "info")
                self:openBrowser(true)
                return
            end
            if not (p.api and p.api:isConfigured()) then
                self:promptSetup(function() self:openBrowser(false) end)
            else
                self:openBrowser(false)
            end
        end,
    })

    if p.ui and p.ui.document and p.ui.document.file then
        local linked = p.sync:getOrMatchBook(p.ui.document.file) ~= nil
        table.insert(items, {
            text = _("Sync this chapter now"),
            enabled_func = function() return linked end,
            callback = function()
                p.sync:pullProgress(p.ui, true)
                p.bookmarks:syncOpenDocument(p.ui, true)
            end,
        })
        table.insert(items, {
            text = _("Jump to where Uchiyomi left off"),
            help_text = _("Opens the chapter, and the page, you last read in this series on another device."),
            enabled_func = function() return linked end,
            callback = function() p.sync:promptSeriesCatchUp(p.ui, true) end,
        })
        table.insert(items, {
            text = linked and _("Unlink current book") or _("Link current book to Uchiyomi"),
            callback = function()
                if linked then p.sync:unlinkCurrentBook() else p.sync:matchCurrentBook() end
            end,
        })
    end

    table.insert(items, {
        text_func = function()
            local n = p.sync:countOfflineBuffer() + p.bookmarks:countOffline()
            if n == 0 then return _("Sync offline changes") end
            return T(_("Sync offline changes (%1 pending)"), n)
        end,
        enabled_func = function() return (p.sync:countOfflineBuffer() + p.bookmarks:countOffline()) > 0 end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            p.sync:flushOfflineProgress(true)
            p.bookmarks:flushOffline()
            if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
        end,
    })

    table.insert(items, {
        text = _("Pull Uchiyomi state into downloaded chapters"),
        help_text = _("Copies reading progress and bookmarks from Uchiyomi into every downloaded chapter that is not currently open."),
        keep_menu_open = true,
        callback = function()
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function() p.sync:reconcileDownloaded(true) end)
        end,
    })

    table.insert(items, { text = _("Server"), separator = true, keep_menu_open = true, sub_item_table_func = function() return self:serverMenu() end })
    table.insert(items, { text = _("Reading"), keep_menu_open = true, sub_item_table_func = function() return self:readingMenu() end })
    table.insert(items, { text = _("Sync"), keep_menu_open = true, sub_item_table_func = function() return self:syncMenu() end })
    table.insert(items, { text = _("Downloads"), keep_menu_open = true, sub_item_table_func = function() return self:downloadsMenu() end })
    table.insert(items, { text = _("Home screen lists"), keep_menu_open = true, sub_item_table_func = function() return self:homeListsMenu() end })
    table.insert(items, {
        text_func = function()
            local id = p.settings.browse_scope
            return T(_("Only browse series in a list: %1"), (id and id ~= "") and (p.settings.browse_scope_name or id) or _("no limit"))
        end,
        help_text = _("Trims what the browser loads: All series, Recently updated, a library's series and search show only the series in the list you pick -- Favourites or any of your Uchiyomi lists -- instead of everything the server holds. Favourites, bookmarks, new chapters and the home screen are unchanged. A line at the top of the browser turns the limit off for the session."),
        keep_menu_open = true,
        sub_item_table_func = function() return self:browseScopeMenu() end,
    })
    table.insert(items, { text = _("Layout"), keep_menu_open = true, sub_item_table_func = function() return self:layoutMenu() end })
    table.insert(items, { text = _("Plugin update"), keep_menu_open = true, sub_item_table_func = function() return self:updateMenu() end })
    table.insert(items, {
        text = _("Diagnostics"),
        keep_menu_open = true,
        callback = function()
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{ title = _("Uchiyomi diagnostics"), text = p:diagnosticsText() })
        end,
    })
    -- A caller that hands these rows to a plain ui/widget/menu.Menu (BookOrbit's home screen does) would otherwise
    -- tap a submenu row and get nothing: that widget ignores `sub_item_table_func`, and falls back to `callback`.
    -- TouchMenu looks at `sub_item_table_func` first and never reaches it, so for Tools > Uchiyomi this is inert.
    for index, item in ipairs(items) do
        if item.sub_item_table_func and not item.callback then
            item.callback = function() require("uchi/settings_sheet").open(p, index) end
        end
    end
    return items
end

function Menu:serverMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    return {
        {
            text_func = function()
                local u = p.settings.server_url
                return (u and u ~= "") and T(_("Server: %1"), u) or _("Server: not set")
            end,
            keep_menu_open = true,
            callback = function(tm) self:promptSetup(function() if tm then tm:updateItems() end end) end,
        },
        {
            text_func = function()
                return (p.settings.api_token and p.settings.api_token ~= "") and _("API token: set") or _("API token: missing")
            end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("API token (uy_...)"), "api_token", false, tm) end,
        },
        {
            text_func = function()
                return (p.settings.opds_token and p.settings.opds_token ~= "") and _("OPDS token: set") or _("OPDS token: not set")
            end,
            help_text = _("With an OPDS token a chapter downloads as one file, which is fast. Without it the chapter is fetched page by page and assembled on the device, which is slower."),
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("OPDS token"), "opds_token", false, tm) end,
        },
        {
            text_func = function() return T(_("Username: %1"), p.settings.username or "") end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Username"), "username", false, tm) end,
        },
        {
            text = _("Let me open 18+ libraries"),
            help_text = _("Unless 'Show 18+ in search and lists' is on, 18+ series are never listed on the home screen, in updates, favourites, history, bookmarks or a plain search -- the plugin simply does not ask the server to include them. This is about the one place it asks regardless: opening a library marked 18+ from the Libraries list. With it off, those libraries list nothing at all."),
            checked_func = function() return p.settings.show_adult == true end,
            keep_menu_open = true,
            callback = function()
                p.settings.show_adult = not p.settings.show_adult
                p:saveSettings()
                p:initAPI()
            end,
        },
        {
            text = _("Show 18+ in search and lists"),
            help_text = _("Like Uchiyomi's own Show 18+ switch: with it on, search, the home rails, updates, favourites, history, collections and bookmarks include 18+ series. Off by default, and then none of those ever list one. It does not change how 18+ chapters are read: they stream or download like any other chapter, per your open mode, and stay off the sleep screen."),
            checked_func = function() return p.settings.show_adult_listings == true end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.show_adult_listings = not p.settings.show_adult_listings
                p:saveSettings()
                p:initAPI()
                if tm then tm:updateItems() end
            end,
        },
        {
            text = _("Keep 18+ off the sleep screen"),
            help_text = _("KOReader paints the sleep screen before a plugin is told the device is suspending, so this cannot be done at the time -- while an 18+ chapter is on screen, the sleep screen is held at a plain covered panel and released when the chapter closes. It matters most if your sleep screen is set to 'disable', which on e-ink leaves the page you were reading on the panel for as long as the device sleeps."),
            checked_func = function() return p.settings.guard_sleep_screen ~= false end,
            keep_menu_open = true,
            callback = function()
                p.settings.guard_sleep_screen = not (p.settings.guard_sleep_screen ~= false)
                p:saveSettings()
                if p.settings.guard_sleep_screen == false then
                    pcall(function() require("uchi/sleepscreen").disarm(p) end)
                end
            end,
        },
        {
            text = _("Also clear 18+ books from KOReader's statistics"),
            help_text = _("KOReader keeps a row per document ever opened -- title, author, series and every reading session -- and it outlives the file, so 18+ chapters read before 0.10.0 are still listed under Statistics. The 'Remove downloaded 18+ chapters' sweep clears them: by file identity for what it deletes, and by series name for what an earlier version deleted long ago. The database is copied to statistics.sqlite3.kouchiyomi-bkp first, once, because this lowers real reading totals and streaks and cannot be undone."),
            checked_func = function() return p.settings.purge_adult_stats ~= false end,
            keep_menu_open = true,
            callback = function()
                p.settings.purge_adult_stats = not (p.settings.purge_adult_stats ~= false)
                p:saveSettings()
            end,
        },
        {
            text = _("Remove downloaded 18+ chapters now"),
            help_text = _("Deletes the files, their sidecars, their KOReader history entries and the series folder they sat in, and (unless turned off above) their rows in KOReader's statistics. Progress and bookmarks live on Uchiyomi, so nothing is lost but the local copy."),
            keep_menu_open = true,
            callback = function() p.sync:sweepAdultDownloads(true) end,
        },
        {
            text = _("Test connection"),
            keep_menu_open = true,
            callback = function()
                if not (p.api and p.api:isConfigured()) then p:notify(_("Not configured."), "error"); return end
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(function()
                    local ok, me = p.api:ping()
                    if ok then
                        p:notify(T(_("Connected as %1"), (type(me) == "table" and me.username) or "?"), "info")
                    else
                        p:notify(T(_("Connection failed: %1"), tostring(me)), "error")
                    end
                end)
            end,
        },
    }
end

function Menu:readingMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    -- Step one setting along a ladder of presets. A hand-edited value that is
    -- not on the ladder steps up to the next rung above it.
    local function cycle(key, steps, tm)
        local cur = tonumber(p.settings[key]) or 0
        local nxt = steps[1]
        for i, v in ipairs(steps) do
            if v == cur then nxt = steps[i % #steps + 1]; break end
            if v > cur then nxt = v; break end
        end
        p.settings[key] = nxt
        p:saveSettings()
        if tm then tm:updateItems() end
    end
    -- Not `pick` below: that one also reseeds uchi/sidecar's download-time
    -- defaults, which this setting has nothing to do with.
    local function rot_item(value, label)
        return {
            text = label,
            checked_func = function() return (p.settings.spread_rotation or "follow") == value end,
            radio = true,
            keep_menu_open = true,
            callback = function() p.settings.spread_rotation = value; p:saveSettings() end,
        }
    end
    local function mode_item(value, label)
        return {
            text = label,
            checked_func = function() return (p.settings.open_mode or "download") == value end,
            radio = true,
            keep_menu_open = true,
            callback = function() p.settings.open_mode = value; p:saveSettings() end,
        }
    end
    local function adult_mode_item(value, label)
        return {
            text = label,
            checked_func = function() return (p.settings.adult_open_mode or "same") == value end,
            radio = true,
            keep_menu_open = true,
            callback = function() p.settings.adult_open_mode = value; p:saveSettings() end,
        }
    end
    -- Every radio row here writes one plugin setting and then hands uchi/sidecar the new seed table, so
    -- the next download already carries it.
    local function pick(key, value, label, default)
        return {
            text = label,
            checked_func = function() return (p.settings[key] or default) == value end,
            radio = true,
            keep_menu_open = true,
            callback = function()
                p.settings[key] = value
                p:saveSettings()
                require("uchi/sidecar").doc_defaults = p:docDefaults()
            end,
        }
    end
    local function dir_item(value, label) return pick("reading_direction", value, label, "rtl") end
    return {
        { text = _("When tapping a chapter:"), enabled = false },
        mode_item("download", _("Download, then open (recommended)")),
        mode_item("stream", _("Stream from the server")),
        mode_item("ask", _("Ask every time")),
        { text = _("18+ chapters:"), enabled = false },
        adult_mode_item("same", _("Same as above")),
        adult_mode_item("download", _("Always download")),
        adult_mode_item("stream", _("Always stream (nothing kept on the device)")),
        adult_mode_item("ask", _("Ask every time")),
        {
            text = _("Also offer streaming at the end of a chapter"),
            checked_func = function() return p.settings.offer_stream == true end,
            keep_menu_open = true,
            separator = true,
            callback = function() p.settings.offer_stream = not p.settings.offer_stream; p:saveSettings() end,
        },
        { text = _("Page turning:"), enabled = false },
        dir_item("rtl", _("Right to left (manga)")),
        dir_item("ltr", _("Left to right")),
        -- Honest label: the server says WEBTOON for every owned series, so this reads left-to-right on
        -- everything until that changes upstream.
        dir_item("auto", _("Follow the series (webtoon on most)")),
        dir_item("off", _("Leave KOReader alone")),
        { text = _("Progress bar and interface:"), enabled = false },
        pick("chapter_ui_mirror", "match", _("Mirror to match page turning"), "leave"),
        pick("chapter_ui_mirror", "off", _("Never mirror"), "leave"),
        pick("chapter_ui_mirror", "leave", _("Leave KOReader alone"), "leave"),
        {
            text = _("Tap zones"),
            help_text = _("Which side of the screen a tap turns the page forward on, for each reading style, and how much of the screen turns forward. Applies to downloaded chapters and to streaming."),
            keep_menu_open = true,
            custom_page = "tapzones",
            sub_item_table_func = function() return self:tapZonesMenu() end,
        },
        {
            text = _("New chapters"),
            separator = true,
            -- These are written into a chapter's sidecar as it downloads, which is the only moment
            -- KOReader will read them without the document being re-rendered. Chapters already on the
            -- device keep whatever they were last closed with.
            sub_item_table = {
                { text = _("View mode:"), enabled = false },
                pick("chapter_view_mode", "auto", _("Match the page shape"), "auto"),
                pick("chapter_view_mode", "page", _("One page per turn"), "auto"),
                pick("chapter_view_mode", "continuous", _("Continuous scroll (webtoons)"), "auto"),
                pick("chapter_view_mode", "leave", _("Leave KOReader alone"), "auto"),
                { text = _("Page crop:"), enabled = false, separator = false },
                pick("chapter_page_crop", "auto", _("Auto (trim scan margins)"), "leave"),
                pick("chapter_page_crop", "none", _("None (keep full-bleed art)"), "leave"),
                pick("chapter_page_crop", "leave", _("Leave KOReader alone"), "leave"),
                { text = _("Hardware dithering:"), enabled = false, separator = false },
                pick("chapter_dithering", "on", _("On (smoother scan gradients)"), "leave"),
                pick("chapter_dithering", "off", _("Off"), "leave"),
                pick("chapter_dithering", "leave", _("Leave KOReader alone"), "leave"),
            },
        },
        {
            text = _("Open the next chapter without asking"),
            help_text = _("At the end of a chapter, the next one opens straight away when it is on the device, is downloaded first when it is only on the server, or is streamed when streaming is your open mode. The dialog still appears when offline without the chapter, on the last chapter, or when the server fails."),
            checked_func = function() return p.settings.auto_advance ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.auto_advance = not (p.settings.auto_advance ~= false); p:saveSettings() end,
        },
        {
            text = _("Turn back from page 1 to the previous chapter"),
            help_text = _("Turning back on the first page of a chapter opens the previous one at its last page, the way turning forward on the last page opens the next one. It is downloaded first when it is only on the server."),
            checked_func = function() return p.settings.prev_chapter_on_first_page ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.prev_chapter_on_first_page = not (p.settings.prev_chapter_on_first_page ~= false); p:saveSettings() end,
        },
        {
            text_func = function()
                local n = tonumber(p.settings.read_ahead) or 1
                if n <= 0 then return _("Read ahead: off") end
                return T(_("Read ahead: %1 chapter(s)"), n)
            end,
            help_text = _("After a chapter opens, the following chapters are downloaded quietly so the end-of-chapter prompt can open them at once. Counts against the storage cap."),
            keep_menu_open = true,
            callback = function(tm)
                p.settings.read_ahead = ((tonumber(p.settings.read_ahead) or 1) + 1) % 4
                p:saveSettings()
                if tm then tm:updateItems() end
            end,
        },
        {
            text = _("Turn the screen for double-page spreads"),
            help_text = _("A spread is scanned as one wide image and lands as two postage stamps on an upright screen. With this on, a page wider than it is tall turns the screen to landscape, and the next single page turns it back -- no need to reach for the device. Turning it by hand always wins: that orientation becomes the one a spread comes back to. Page mode only; a webtoon read as one long strip is left alone. Gestures can be bound to 'Uchiyomi: portrait / landscape' and 'Uchiyomi: rotate for wide pages on/off'."),
            checked_func = function() return p.settings.auto_rotate_wide_pages ~= false end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.auto_rotate_wide_pages = not (p.settings.auto_rotate_wide_pages ~= false)
                p:saveSettings()
                if tm then tm:updateItems() end
            end,
        },
        {
            text = _("Two pages side by side in landscape"),
            help_text = _("Turn the device on its side and the page you are on is shown with the next page beside it, like an open book -- for reading double pages even when the source did not scan them as one. Right-to-left series put the page you are on on the right. A page turn moves past both; turning back from a pair lands two pages earlier, and a spread that is already wide always has the screen to itself. Works for downloaded and streamed chapters; a screen turned by 'Turn the screen for double-page spreads' stays single, since the next single page turns it back. Page mode only."),
            checked_func = function() return p.settings.dual_page_landscape ~= false end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.dual_page_landscape = not (p.settings.dual_page_landscape ~= false)
                p:saveSettings()
                -- Repaint what is on screen with the new setting.
                pcall(function() require("uchi/dualpage").refresh(p) end)
                if tm then tm:updateItems() end
            end,
        },
        {
            text = _("One home-screen entry per series"),
            help_text = _("KOReader's history lists every chapter you open as its own book, so a home screen built from it (SimpleUI's Currently reading, Recent books and Cover deck) fills up with chapters of one manga. With this on, only the chapter you read last stays in the history for each series. Chapter files, reading positions and bookmarks are not touched -- the older chapters just stop being listed. Applies when a chapter is closed; KOReader's own History view is tidied the same way."),
            checked_func = function() return p.settings.one_history_entry_per_series ~= false end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.one_history_entry_per_series = not (p.settings.one_history_entry_per_series ~= false)
                p:saveSettings()
                pcall(require("uchi/history").collapse, p)
                if tm then tm:updateItems() end
            end,
        },
        {
            text = _("Join spreads a source cut in two"),
            help_text = _("Some sources serve a double-page spread as two ordinary pages. Uchiyomi finds them by checking that the picture runs across the seam, and with this on the two pages become one wide image, which the screen then turns for. Streamed chapters show the pair as one screen; downloaded ones are assembled page by page, so progress counts a joined pair as one page and can be off by a page against the web reader in a chapter that has one."),
            checked_func = function() return p.settings.join_split_spreads ~= false end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.join_split_spreads = not (p.settings.join_split_spreads ~= false)
                p:saveSettings()
                if tm then tm:updateItems() end
            end,
        },
        {
            text_func = function()
                local labels = { follow = _("as KOReader does"), cw = _("clockwise"), ccw = _("counter-clockwise") }
                -- Unrecognised reads as "follow", the same as the rule itself does.
                return T(_("Which way it turns: %1"), labels[p.settings.spread_rotation or "follow"] or labels.follow)
            end,
            help_text = _("Which of the two landscapes puts the page-turn buttons under your thumb depends on which edge you hold the device by, so this is yours to pick -- try both on the next spread. 'As KOReader does' keeps which way up the device is being held, the same rule its own Toggle orientation uses. Turning back to portrait always returns to the upright you came from, whichever direction is set."),
            enabled_func = function() return p.settings.auto_rotate_wide_pages ~= false end,
            sub_item_table = {
                { text = _("Turning to landscape:"), enabled = false },
                rot_item("follow", _("As KOReader does (keeps which way up)")),
                rot_item("cw", _("Always clockwise")),
                rot_item("ccw", _("Always counter-clockwise")),
            },
        },
        {
            text = _("Delete chapters once marked read"),
            help_text = _("When you move on to the next chapter, the finished file is removed after the server confirms it is read. Progress and bookmarks stay on Uchiyomi, so the chapter can always be downloaded again."),
            checked_func = function() return p.settings.delete_read_on_advance ~= false end,
            keep_menu_open = true,
            callback = function(tm)
                p.settings.delete_read_on_advance = not (p.settings.delete_read_on_advance ~= false)
                p:saveSettings()
                if tm then tm:updateItems() end
            end,
        },
        {
            text_func = function()
                local d = tonumber(p.settings.keep_read_chapters_days) or 0
                if d <= 0 then return _("Grace period before it goes: none, delete it straight away") end
                return T(_("Grace period before it goes: %1 day(s)"), d)
            end,
            help_text = _("A chapter you have just read is the one you are most likely to want back -- turning back from the first page opens it, and catching up with Uchiyomi can land in it. The clock restarts if you open the chapter again. Downloads over the storage cap are still evicted oldest-first."),
            enabled_func = function() return p.settings.delete_read_on_advance ~= false end,
            keep_menu_open = true,
            callback = function(tm) cycle("keep_read_chapters_days", { 0, 1, 3, 7, 14, 30 }, tm) end,
        },
        {
            text_func = function()
                local n = tonumber(p.settings.keep_newest_chapters) or 0
                if n <= 0 then return _("Always keep the last chapters read: off") end
                return T(_("Always keep the last %1 chapter(s) read in a series"), n)
            end,
            help_text = _("However long ago they were read, the last few chapters you finished in a series stay on the device, so there is always something behind you to turn back into. Finishing another chapter releases the oldest one. Chapters waiting ahead of you from the read-ahead do not count against it, and one series cannot spend another's. The grace period bounds how long a finished chapter survives; this bounds how many."),
            enabled_func = function() return p.settings.delete_read_on_advance ~= false end,
            keep_menu_open = true,
            callback = function(tm) cycle("keep_newest_chapters", { 0, 1, 2, 3, 5, 10 }, tm) end,
        },
    }
end

function Menu:syncMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local labels = { prompt = _("ask"), silent = _("jump silently"), disable = _("ignore") }
    local order = { "silent", "prompt", "disable" }
    local function cycle(key, choices)
        choices = choices or order
        local cur = p.settings[key] or "prompt"
        local nxt = choices[1]
        for i, v in ipairs(choices) do
            if v == cur then nxt = choices[i % #choices + 1]; break end
        end
        p.settings[key] = nxt
        p:saveSettings()
    end
    return {
        {
            text = _("Sync reading progress with Uchiyomi"),
            checked_func = function() return p.settings.sync_progress ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.sync_progress = not (p.settings.sync_progress ~= false); p:saveSettings() end,
        },
        {
            text = _("Sync bookmarks both ways"),
            checked_func = function() return p.settings.sync_bookmarks ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.sync_bookmarks = not (p.settings.sync_bookmarks ~= false); p:saveSettings() end,
        },
        {
            text_func = function() return T(_("When Uchiyomi is further ahead: %1"), labels[p.settings.sync_forward or "silent"]) end,
            keep_menu_open = true,
            callback = function(tm) cycle("sync_forward"); if tm then tm:updateItems() end end,
        },
        {
            text_func = function() return T(_("When Uchiyomi is behind: %1"), labels[p.settings.sync_backward == "silent" and "silent" or "disable"]) end,
            keep_menu_open = true,
            callback = function(tm) if p.settings.sync_backward ~= "silent" then p.settings.sync_backward = "disable" end; cycle("sync_backward", { "disable", "silent" }); if tm then tm:updateItems() end end,
        },
        {
            text_func = function() return T(_("When Uchiyomi is on a later chapter: %1"), labels[p.settings.sync_series_catchup or "prompt"]) end,
            help_text = _("Opening a chapter you have already read past elsewhere offers to jump to the chapter, and the page, Uchiyomi left off on."),
            keep_menu_open = true,
            callback = function(tm) cycle("sync_series_catchup"); if tm then tm:updateItems() end end,
        },
        {
            text_func = function() return T(_("Push progress every %1 pages"), p.settings.push_interval or 5) end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Pages between progress pushes"), "push_interval", true, tm) end,
        },
        {
            text = _("Reconcile downloads when Wi-Fi connects"),
            help_text = _("Checks the chapters on the device against Uchiyomi when Wi-Fi comes on. It is slow, so it runs at most once every 6 hours."),
            checked_func = function() return p.settings.reconcile_on_connect == true end,
            keep_menu_open = true,
            callback = function() p.settings.reconcile_on_connect = not (p.settings.reconcile_on_connect == true); p:saveSettings() end,
        },
        {
            text = _("Sync count in the reader footer"),
            help_text = _("Shows the number of pending sync and download items in the reader footer."),
            checked_func = function() return p.settings.footer_sync_indicator ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.footer_sync_indicator = not (p.settings.footer_sync_indicator ~= false); p:saveSettings() end,
        },
    }
end

function Menu:downloadsMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    return {
        {
            text_func = function()
                local d = p.settings.download_dir
                return (d and d ~= "") and T(_("Download folder: %1"), d) or _("Download folder: <home>/Uchiyomi")
            end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Download folder (blank = <home>/Uchiyomi)"), "download_dir", false, tm) end,
        },
        {
            text = _("Series subfolders"),
            checked_func = function() return p.settings.download_to_subfolder ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.download_to_subfolder = not (p.settings.download_to_subfolder ~= false); p:saveSettings() end,
        },
        {
            text_func = function()
                local gb = tonumber(p.settings.max_download_gb) or 0
                if gb <= 0 then return _("Storage cap: unlimited") end
                return T(_("Storage cap: %1 GB"), gb)
            end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Storage cap in GB (0 = unlimited)"), "max_download_gb", true, tm) end,
        },
        {
            text_func = function()
                local bytes, count = p.sync:getManagedDownloadsSize()
                return T(_("Downloaded: %1 GB (%2 chapters)"), string.format("%.2f", bytes / 1024 ^ 3), count)
            end,
            keep_menu_open = true,
            callback = function(tm) if tm then tm:updateItems() end end,
        },
    }
end

--- Which of the user's Uchiyomi lists the browser's home screen shows (next unread chapter of each series).
function Menu:homeListsMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local names = p.settings.home_list_names
    if type(names) ~= "table" then names = {}; p.settings.home_list_names = names end
    names.favorites = names.favorites or _("Favourites")

    local available = { "favorites" }
    local NetworkMgr = require("ui/network/manager")
    if p.api and NetworkMgr:isOnline() then
        local res = p.api:get_collections()
        if type(res) == "table" then
            for _i, c in ipairs(res.content or res) do
                if c.id then names[c.id] = c.name or names[c.id] or c.id; table.insert(available, c.id) end
            end
        end
    else
        for id in pairs(names) do if id ~= "favorites" then table.insert(available, id) end end
        table.sort(available, function(a, b) return tostring(names[a]) < tostring(names[b]) end)
    end

    local function selected(id)
        for i, v in ipairs(p.settings.home_lists or {}) do if v == id then return i end end
    end
    local items = {}
    for _i, id in ipairs(available) do
        table.insert(items, {
            text = names[id] or id,
            checked_func = function() return selected(id) ~= nil end,
            keep_menu_open = true,
            callback = function()
                p.settings.home_lists = p.settings.home_lists or {}
                local at = selected(id)
                if at then table.remove(p.settings.home_lists, at) else table.insert(p.settings.home_lists, id) end
                p._home_cache = nil
                p:saveSettings()
            end,
        })
    end
    table.insert(items, {
        text_func = function() return T(_("Series shown per list: %1"), p.settings.home_list_limit or 8) end,
        separator = true,
        keep_menu_open = true,
        callback = function(tm)
            p._home_cache = nil
            self:promptInput(_("Series shown per list"), "home_list_limit", true, tm)
        end,
    })
    table.insert(items, 1, {
        text = _("Shown on the Uchiyomi home screen, in the order ticked:"),
        enabled_func = function() return false end,
    })
    return items
end

--- Tap zones: the side the next page is on for each reading style, and the width of that zone (uchi/tapzones).
function Menu:tapZonesMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local function changed()
        p:saveSettings()
        require("uchi/tapzones").refresh(p)
    end
    local function side_rows(key, title, natural)
        local rows = { { text = title, enabled = false } }
        local function row(value, label)
            rows[#rows + 1] = {
                text = label,
                radio = true,
                checked_func = function() return (p.settings[key] or "auto") == value end,
                keep_menu_open = true,
                callback = function() p.settings[key] = value; changed() end,
            }
        end
        row("auto", T(_("Natural: the %1 (like KOReader)"), natural))
        row("left", _("Left"))
        row("right", _("Right"))
        return rows
    end
    local items = {}
    for _i, r in ipairs(side_rows("tap_next_side_rtl", _("Right-to-left chapters: side of the next page"), _("left"))) do items[#items + 1] = r end
    for _i, r in ipairs(side_rows("tap_next_side_ltr", _("Left-to-right chapters: side of the next page"), _("right"))) do items[#items + 1] = r end
    items[#items + 1] = { text = _("Next-page zone width:"), enabled = false }
    items[#items + 1] = {
        text = _("Default (KOReader's sizes)"),
        radio = true,
        checked_func = function() return tonumber(p.settings.tap_next_width) == nil end,
        keep_menu_open = true,
        callback = function() p.settings.tap_next_width = nil; changed() end,
    }
    for _i, w in ipairs(require("uchi/tapzones").WIDTHS) do
        items[#items + 1] = {
            text = T(_("%1% of the screen"), math.floor(w * 100 + 0.5)),
            radio = true,
            checked_func = function() return tonumber(p.settings.tap_next_width) == w end,
            keep_menu_open = true,
            callback = function() p.settings.tap_next_width = w; changed() end,
        }
    end
    return items
end

--- Which list the browser's catalogue views are limited to (one, or none).
function Menu:browseScopeMenu()
    local _ = self.plugin.i18n._
    local p = self.plugin
    local names = p.settings.home_list_names
    if type(names) ~= "table" then names = {}; p.settings.home_list_names = names end
    names.favorites = names.favorites or _("Favourites")
    local available = { "favorites" }
    local NetworkMgr = require("ui/network/manager")
    if p.api and NetworkMgr:isOnline() then
        local res = p.api:get_collections()
        if type(res) == "table" then
            for _i, c in ipairs(res.content or res) do
                if c.id then names[c.id] = c.name or names[c.id] or c.id; table.insert(available, c.id) end
            end
        end
    else
        for id in pairs(names) do if id ~= "favorites" then table.insert(available, id) end end
    end
    local function choose(id)
        p.settings.browse_scope = id
        p.settings.browse_scope_name = id and (names[id] or id) or nil
        p._scope_off, p._scope_cache = nil, nil
        p:saveSettings()
    end
    local items = { {
        text = _("No limit (every series)"),
        checked_func = function() return not (p.settings.browse_scope and p.settings.browse_scope ~= "") end,
        keep_menu_open = true,
        callback = function(tm) choose(nil); if tm then tm:updateItems() end end,
    } }
    for _i, id in ipairs(available) do
        table.insert(items, {
            text = names[id] or id,
            checked_func = function() return p.settings.browse_scope == id end,
            keep_menu_open = true,
            callback = function(tm) choose(id); if tm then tm:updateItems() end end,
        })
    end
    return items
end

function Menu:layoutMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    return {
        {
            text = _("Uchiyomi icon in the top menu bar"),
            help_text = _("Adds an Uchiyomi icon to the row of tabs at the top of KOReader's menu, in the reader and in the file browser. In a chapter it opens a sheet: back to the series page or its library, the previous or next chapter, favourite, add to a list, and the rest of the series actions. Elsewhere it opens the browser's sections. Takes effect the next time the menu is opened."),
            checked_func = function() return p.settings.menu_bar_icon ~= false end,
            keep_menu_open = true,
            callback = function()
                p.settings.menu_bar_icon = not (p.settings.menu_bar_icon ~= false)
                p:saveSettings()
                require("uchi/menu_pin").refresh(p.settings.menu_bar_icon)
                -- The menu rebuilds from the rewritten order the next time it opens.
                if p.ui and p.ui.menu then p.ui.menu.tab_item_table = nil end
            end,
        },
        {
            text = _("BookOrbit-style settings"),
            help_text = _("When the BookOrbit plugin is installed, these settings are drawn in its style: grouped cards, switches and radio dots. Off (or without BookOrbit) they use KOReader's own touch menu. Takes effect the next time settings are opened."),
            enabled_func = function() return require("uchi/ui_theme").available end,
            checked_func = function() return p.settings.bookorbit_settings_style ~= false end,
            keep_menu_open = true,
            callback = function()
                p.settings.bookorbit_settings_style = not (p.settings.bookorbit_settings_style ~= false)
                p:saveSettings()
            end,
        },
        {
            text_func = function() return p.settings.view_mode == "grid" and _("Default view: grid") or _("Default view: list") end,
            keep_menu_open = true,
            callback = function(tm) p.settings.view_mode = p.settings.view_mode == "grid" and "list" or "grid"; p:saveSettings(); if tm then tm:updateItems() end end,
        },
        { text_func = function() return T(_("List rows: %1"), p.settings.list_rows or 5) end, keep_menu_open = true,
          callback = function(tm) self:promptInput(_("List rows"), "list_rows", true, tm) end },
        { text_func = function() return T(_("Grid columns: %1"), p.settings.grid_columns or 3) end, keep_menu_open = true,
          callback = function(tm) self:promptInput(_("Grid columns"), "grid_columns", true, tm) end },
        { text_func = function() return T(_("Grid rows: %1"), p.settings.grid_rows or 3) end, keep_menu_open = true,
          callback = function(tm) self:promptInput(_("Grid rows"), "grid_rows", true, tm) end },
        {
            text = _("Show covers"),
            checked_func = function() return p.settings.show_covers ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.show_covers = not (p.settings.show_covers ~= false); p:saveSettings() end,
        },
        {
            text = _("Clear cover cache"),
            keep_menu_open = true,
            callback = function() p.cache:clear(); p:notify(_("Cover cache cleared."), "info") end,
        },
    }
end

function Menu:updateMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    return {
        {
            text_func = function()
                local seen = p.settings.update_latest_seen
                local cur = p.updater:localVersion()
                if seen and p.updater.isNewer(seen, cur) then return T(_("Installed %1 - %2 available"), cur, seen) end
                return T(_("Installed version: %1"), cur)
            end,
            enabled = false,
        },
        {
            text = _("Check for updates now"),
            keep_menu_open = true,
            callback = function(tm)
                p.updater:promptUpdate(true)
                if tm and tm.updateItems then tm:updateItems() end
            end,
        },
        {
            text = _("Re-install latest from GitHub"),
            help_text = _("Downloads the tracked branch even if the version number has not changed."),
            keep_menu_open = true,
            callback = function()
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(function() p.updater:install() end)
            end,
        },
        {
            text = _("Check automatically (once a day)"),
            checked_func = function() return p.settings.update_auto_check ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.update_auto_check = not (p.settings.update_auto_check ~= false); p:saveSettings() end,
        },
        {
            text_func = function() return (p.settings.github_token ~= "" ) and _("GitHub token: set") or _("GitHub token: none") end,
            help_text = _("A GitHub token is needed to update the plugin while its repository is private."),
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("GitHub token (fine-grained, Contents: read)"), "github_token", false, tm) end,
        },
        {
            text_func = function() return T(_("Repository: %1 @ %2"), p.settings.update_repo or "", p.settings.update_ref or "main") end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Repository (owner/name)"), "update_repo", false, tm) end,
        },
    }
end

function Menu:openBrowser(offline, on_ready)
    local Browser = require("uchi/browser")
    local msg
    if not offline then
        local InfoMessage = require("ui/widget/infomessage")
        msg = InfoMessage:new{ text = self.plugin.i18n._("Loading Uchiyomi...") }
        UIManager:show(msg)
        UIManager:forceRePaint()
    end
    local browser = Browser:new{ plugin = self.plugin }
    if msg then UIManager:close(msg) end
    UIManager:show(browser)
    if offline then browser:showOfflineLibrary() end
    -- Somewhere other than the home screen (the menu bar sheet opens a series or a library straight away).
    if on_ready then on_ready(browser) end
end

function Menu:promptInput(title, key, is_number, touchmenu_instance)
    local _ = self.plugin.i18n._
    local p = self.plugin
    local input
    input = InputDialog:new{
        title = title,
        input = tostring(p.settings[key] or ""),
        input_type = is_number and "number" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = input:getInputText()
                if is_number then
                    value = tonumber(value)
                    if not value then p:notify(_("Invalid number"), "error"); return end
                else
                    value = require("util").trim(value)
                end
                p.settings[key] = value
                p:saveSettings()
                if key == "server_url" or key == "api_token" or key == "opds_token" or key == "username" then p:initAPI() end
                UIManager:close(input)
                if touchmenu_instance and touchmenu_instance.updateItems then touchmenu_instance:updateItems() end
            end },
        } },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

--- First-run setup: server URL + username + password. Logs in, mints an API
-- token and (with consent) an OPDS token, and stores everything.
function Menu:promptSetup(on_success)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Connect to Uchiyomi"),
        description = _("Your password is used once to create a long-lived API token; it is not stored."),
        fields = {
            { text = p.settings.server_url or "https://", hint = _("Server URL, e.g. https://uchiyomi.example.com") },
            { text = p.settings.username or "", hint = _("Username") },
            { hint = _("Password"), text_type = "password" },
            { hint = _("2FA code (only if enabled on the account)"), input_type = "number" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local url, username, password, totp = unpack(dialog:getFields())
                local util = require("util")
                url = util.trim(url or ""):gsub("/+$", "")
                username = util.trim(username or "")
                if url == "" or not url:match("^https?://") then p:notify(_("Enter the server URL including http:// or https://"), "error"); return end
                if username == "" or not password or password == "" then p:notify(_("Username and password are required"), "error"); return end
                UIManager:close(dialog)
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(function()
                    UIManager:scheduleIn(0.2, function() self:_doSetup(url, username, password, totp, on_success) end)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Menu:_doSetup(url, username, password, totp, on_success)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local API = require("uchi/api")
    local api = API:new(url, { show_adult = p.settings.show_adult })
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Signing in...") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, err = api:login(username, password, totp)
    if not ok then
        UIManager:close(msg)
        p:notify(T(_("Sign-in failed: %1"), tostring(err)), "error")
        return
    end
    local Device = require("device")
    local name = "KOReader kouchiyomi (" .. (Device.model or "device") .. ")"
    local token, terr = api:create_api_token(name, p.settings.show_adult)
    UIManager:close(msg)
    if not token then
        p:notify(T(_("Could not create an API token: %1"), tostring(terr)), "error")
        return
    end
    p.settings.server_url = url
    p.settings.username = username
    p.settings.api_token = token
    p:saveSettings()
    p:initAPI()
    logger.info("kouchiyomi: API token created")

    -- OPDS token: needed for whole-file CBZ downloads. Creating one rotates
    -- any existing token, so ask first when one exists.
    local status = api:get_opds_token_status()
    local function finish(opds)
        if opds then
            p.settings.opds_token = opds
            p:saveSettings()
            p:initAPI()
        end
        p:notify(_("Connected to Uchiyomi."), "info")
        if on_success then on_success() end
    end
    if type(status) == "table" and status.exists then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Your account already has an OPDS token (used by other OPDS readers). Create a new one for fast CBZ downloads here? This invalidates the old one. If you decline, chapters are downloaded page by page instead."),
            ok_text = _("Create new token"),
            cancel_text = _("Skip"),
            ok_callback = function()
                local opds = api:create_opds_token()
                finish(opds)
            end,
            cancel_callback = function() finish(nil) end,
        })
    else
        local opds = api:create_opds_token()
        finish(opds)
    end
end

return Menu
