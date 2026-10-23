--[[
    The Uchiyomi icon in KOReader's top menu bar, and the sheet it opens.

    In a chapter it answers "where am I, and where can I go from here?": back to this series' page or to the
    library it is in, to the chapter before, to the next one (marking this one read); favourite the series, put it in
    a list, flip page turning, and everything else the series hold menu in the browser has. Outside a chapter (the
    file browser, a book that is not from Uchiyomi) it is the way into the browser: home, favourites, new chapters,
    bookmarks, libraries, search, downloads.

    The sheet is the same row tree the settings use, so it is drawn by uchi/ui_settings_page (BookOrbit's look) when
    BookOrbit is installed and by KOReader's own touch menu when it is not. Nothing is fetched to OPEN it: the series
    is looked up (briefly, with short timeouts) only when the device is online, and a miss just leaves its rows out.
--]]

local UIManager = require("ui/uimanager")

local ReaderMenu = {}

local SERIES_TTL = 5 * 60
local LIBRARIES_TTL = 10 * 60
-- On the module: a new plugin instance is made for every document that opens.
local series_cache = {}
local libraries_cache = nil

-- ------------------------------------------------------------------ icon
local function absolute(path)
    if path:sub(1, 1) == "/" then return path end
    local cwd = require("libs/libkoreader-lfs").currentdir()
    return cwd and (cwd .. "/" .. path) or path
end

--- KOReader's tab bar looks an icon up by NAME under its icon folders. Enough "../" climbs from any of them to
-- the filesystem root, so the SVG that ships in assets/ is found by its absolute path without copying it.
function ReaderMenu.iconName(plugin_path)
    if not plugin_path then return "appbar.menu" end
    local path = absolute(plugin_path .. "/assets/kouchiyomi.tab.svg")
    return string.rep("../", 32) .. path:gsub("^/+", ""):gsub("%.svg$", "")
end

function ReaderMenu.enabled(plugin)
    return plugin.settings.menu_bar_icon ~= false
end

-- ------------------------------------------------------------- context
local function online()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr:isConnected() and true or false
end

--- Run `fn` with short timeouts and without leaving the connector in "fast" mode.
local function quickly(plugin, fn)
    local api = plugin.api
    if not api then return nil end
    local was_fast, was_dead = api.fast, api.fast_dead
    api.fast, api.fast_dead = true, false
    local ok, a, b = pcall(fn, api)
    api.fast, api.fast_dead = was_fast, was_dead
    if ok then return a, b end
    return nil
end

function ReaderMenu.series(plugin, series_id)
    if not series_id or not plugin.api or not online() then return series_cache[series_id] and series_cache[series_id].series end
    local hit = series_cache[series_id]
    if hit and os.time() - hit.at < SERIES_TTL then return hit.series end
    local series = quickly(plugin, function(api) return api:get_series(series_id) end)
    if type(series) == "table" and series.id then
        series_cache[series_id] = { series = series, at = os.time() }
        return series
    end
    return hit and hit.series or nil
end

function ReaderMenu.libraryName(plugin, library_id)
    if not library_id or not plugin.api then return nil end
    if not libraries_cache or os.time() - libraries_cache.at > LIBRARIES_TTL then
        if not online() then return libraries_cache and libraries_cache.names[tostring(library_id)] end
        local res = quickly(plugin, function(api) return api:get_libraries() end)
        local list = type(res) == "table" and (res.content or res) or nil
        if type(list) == "table" then
            local names = {}
            for _i, lib in ipairs(list) do
                if type(lib) == "table" and lib.id then names[tostring(lib.id)] = lib.name or tostring(lib.id) end
            end
            libraries_cache = { at = os.time(), names = names }
        end
    end
    return libraries_cache and libraries_cache.names[tostring(library_id)] or nil
end

--- What the open document is, as far as Uchiyomi is concerned: nil unless it is one of its chapters.
function ReaderMenu.chapterContext(plugin)
    local ui = plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.file) then return nil end
    local book_id = plugin.current_book_id or plugin.sync:getOrMatchBook(doc.file)
    if not book_id then return nil end
    local info = plugin.sync:getOfflineBookInfo(doc.file)
    local series_id = plugin.sync:getSeriesIdForDoc(doc.file)
    local label
    if info.series_index then label = "Ch. " .. tostring(info.series_index):gsub("%.0+$", "") end
    return {
        book_id = book_id,
        series_id = series_id,
        series_title = info.series,
        chapter = label or info.title,
        chapter_title = info.title,
    }
end

-- --------------------------------------------------------------- opening
--- Show the browser, then hand it to `on_ready` (to land on a series, a library, ...). Opened over whatever is on
-- screen, the way Tools > Uchiyomi opens it: backing out of the browser returns to the chapter.
function ReaderMenu.openBrowser(plugin, on_ready)
    if not plugin.api then
        plugin:notify(plugin.i18n._("Uchiyomi is not set up yet: Tools > Uchiyomi > Server."), "error")
        return
    end
    plugin.menu:openBrowser(false, on_ready)
end

function ReaderMenu.openSeries(plugin, series)
    ReaderMenu.openBrowser(plugin, function(browser) browser:showBooksInSeries(series) end)
end

function ReaderMenu.openLibrary(plugin, series)
    ReaderMenu.openBrowser(plugin, function(browser)
        local lib = { id = series.libraryId, name = ReaderMenu.libraryName(plugin, series.libraryId) }
        browser:showSeriesInLibrary(lib)
    end)
end

-- ------------------------------------------------------------------ rows
local function row(text, callback, o)
    local item = { text = text, callback = callback }
    for k, v in pairs(o or {}) do item[k] = v end
    return item
end

local function header(text) return { text = text, is_header = true, enabled = false } end

local function browseRows(plugin)
    local _ = plugin.i18n._
    local function go(fn) return function() ReaderMenu.openBrowser(plugin, fn) end end
    return {
        row(_("Uchiyomi home"), go(nil)),
        row(_("New chapters (favourites)"), go(function(b) b:showUpdates() end)),
        row(_("Favourites"), go(function(b) b:showFavorites() end)),
        row(_("Bookmarks"), go(function(b) b:showBookmarks() end)),
        row(_("Libraries"), go(function(b) b:showLibraries() end)),
        row(_("Search..."), go(function(b) b:promptSearch() end)),
        row(_("Downloaded chapters (offline)"), function() plugin.menu:openBrowser(true) end),
    }
end

local function settingsRow(plugin)
    local _ = plugin.i18n._
    return row(_("Settings"), function()
        UIManager:nextTick(function() require("uchi/settings_sheet").open(plugin) end)
    end)
end

--- Page turning direction of the open chapter, as a switch. Manga is read right to left; a chapter that opened
-- the wrong way round is one tap away from right.
local function pageTurningRow(plugin)
    local _ = plugin.i18n._
    local ui = plugin.ui
    if not (ui and ui.view and ui.view.onToggleReadingOrder) then return nil end
    return row(_("Right-to-left page turning"), function(tm)
        local want = not ui.view.inverse_reading_order
        ui.view:onToggleReadingOrder(want)
        if ui.doc_settings then ui.doc_settings:saveSetting("inverse_reading_order", want) end
        if tm and tm.updateItems then tm:updateItems() end
    end, { checked_func = function() return ui.view.inverse_reading_order == true end, keep_menu_open = true })
end

--- Rows for the chapter that is open. Returns title, subtitle, items.
function ReaderMenu.chapterItems(plugin, ctx)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local SA = require("uchi/series_actions")
    local ui = plugin.ui
    local series = ReaderMenu.series(plugin, ctx.series_id)
    local items = {}

    if series then
        items[#items + 1] = header(_("Go to"))
        items[#items + 1] = row(_("Series page"), function() ReaderMenu.openSeries(plugin, series) end)
        local lib = ReaderMenu.libraryName(plugin, series.libraryId)
        if series.libraryId then
            items[#items + 1] = row(_("Library"), function() ReaderMenu.openLibrary(plugin, series) end,
                { text_func = lib and function() return _("Library") .. ": " .. lib end or nil })
        end
        items[#items + 1] = row(_("Browse Uchiyomi"), nil, { sub_item_table = browseRows(plugin) })
    else
        items[#items + 1] = header(_("Go to"))
        items[#items + 1] = row(_("Browse Uchiyomi"), nil, { sub_item_table = browseRows(plugin) })
    end

    items[#items + 1] = header(_("This chapter"))
    items[#items + 1] = row(_("Previous chapter"), function()
        local ok, why = plugin.sync:openPreviousChapter(ui)
        if ok == false then plugin:notify(T(_("No previous chapter: %1"), tostring(why or "?")), "info") end
    end)
    items[#items + 1] = row(_("Mark read and go to next chapter"), function()
        local ok, why = plugin.sync:promptNextChapter(ui, nil)
        if ok == false then plugin:notify(T(_("Could not go on: %1"), tostring(why or "?")), "error") end
    end)
    local turning = pageTurningRow(plugin)
    if turning then items[#items + 1] = turning end
    items[#items + 1] = row(_("Rotate screen"), function()
        UIManager:sendEvent(require("ui/event"):new("KouchiyomiToggleRotation"))
    end)
    items[#items + 1] = row(_("Sync progress now"), function()
        plugin:onKouchiyomiSync()
    end)

    if series then
        items[#items + 1] = header(_("Series"))
        items[#items + 1] = row(nil, function(tm)
            SA.toggle_favorite(plugin, series, nil)
            if tm and tm.updateItems then tm:updateItems() end
        end, {
            text_func = function() return SA.is_favorite(series) and _("Remove from favourites") or _("Add to favourites") end,
            keep_menu_open = true,
        })
        items[#items + 1] = row(_("Add to list..."), function()
            UIManager:nextTick(function() SA.add_to_list(plugin, series, nil) end)
        end)
        items[#items + 1] = row(_("More series actions..."), function()
            UIManager:nextTick(function() ReaderMenu.showSeriesActions(plugin, series) end)
        end)
    end

    items[#items].separator = true
    items[#items + 1] = settingsRow(plugin)

    local title = series and SA.title(series) or ctx.series_title or ctx.chapter_title or "Uchiyomi"
    return title, ctx.chapter, items
end

--- Rows for anywhere else.
function ReaderMenu.homeItems(plugin)
    local _ = plugin.i18n._
    local items = {}
    for _i, r in ipairs(browseRows(plugin)) do items[#items + 1] = r end
    items[#items].separator = true
    items[#items + 1] = settingsRow(plugin)
    return "Uchiyomi", nil, items
end

--- The series hold menu, as a dialog (the browser's, with the hooks a reader can honour).
function ReaderMenu.showSeriesActions(plugin, series)
    local SA = require("uchi/series_actions")
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local hooks = {
        open_series = function(s) ReaderMenu.openSeries(plugin, s) end,
        open_library = function(s) ReaderMenu.openLibrary(plugin, s) end,
        changed = function() series_cache[series.id] = nil end,
    }
    local buttons = SA.rows(plugin, series, hooks, function() UIManager:close(dialog) end)
    table.insert(buttons, { { text = plugin.i18n._("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = SA.title(series), buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

-- ------------------------------------------------------------------ open
--- What tapping the tab does.
function ReaderMenu.open(plugin)
    local ctx = ReaderMenu.chapterContext(plugin)
    local title, sub, items
    if ctx then title, sub, items = ReaderMenu.chapterItems(plugin, ctx) else title, sub, items = ReaderMenu.homeItems(plugin) end
    return require("uchi/settings_sheet").openItems(plugin, { title = title, sub = sub, items = items, name = "kouchiyomi_menu" })
end

--- The tab's callback: close KOReader's menu first so the sheet is painted over the page, not over the menu.
function ReaderMenu.onTab(plugin)
    local menu = plugin.ui and plugin.ui.menu
    if menu then
        if menu.onCloseFileManagerMenu then menu:onCloseFileManagerMenu()
        elseif menu.onCloseReaderMenu then menu:onCloseReaderMenu() end
    end
    UIManager:tickAfterNext(function()
        local ok, err = pcall(ReaderMenu.open, plugin)
        if not ok then
            require("logger").warn("kouchiyomi: menu sheet failed:", tostring(err))
            plugin:notify(plugin.i18n._("Could not open the Uchiyomi menu."), "error")
        end
    end)
end

--- Drop what was looked up (a series just changed).
function ReaderMenu.forget()
    series_cache = {}
    libraries_cache = nil
end

return ReaderMenu
