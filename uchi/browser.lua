--[[
    Uchiyomi library browser: a full-screen Menu with list/grid rendering,
    lazy server pagination and a navigation stack. Derived from kokomga's
    browser (MIT, Jim Davis) and reworked for Uchiyomi's API.
--]]

local Menu = require("ui/widget/menu")
local UchiListMenu = require("uchi/list_menu")
local UchiGridMenu = require("uchi/grid_menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Labels = require("uchi/labels")
local Scope = require("uchi/scope")
local SeriesActions = require("uchi/series_actions")

-- When BookOrbit (bookorbit.koplugin) is installed, the browser is drawn
-- with its primitives instead of these two stock Menu subclasses -- see
-- uchi/ui_theme.lua and uchi/ui_board_menu.lua. Nothing about the data,
-- pagination or navigation below this point changes either way; only which
-- class renders a page of item_table entries does.
local Theme = require("uchi/ui_theme")
local BoardMenu = Theme.available and require("uchi/ui_board_menu") or nil

local _base_list_recalc = BoardMenu and BoardMenu._recalculateDimen or UchiListMenu._recalculateDimen
local _base_list_update = BoardMenu and BoardMenu.updateItems or UchiListMenu.updateItems
local _base_grid_recalc = BoardMenu and BoardMenu._recalculateDimen or UchiGridMenu._recalculateDimen
local _base_grid_update = BoardMenu and BoardMenu.updateItems or UchiGridMenu.updateItems

local function hideWidget(w)
    if not w then return end
    w.ignore = true
    if not w._orig_paintTo then
        w._orig_paintTo = w.paintTo
        w.paintTo = function() end
        w._orig_handleEvent = w.handleEvent
        w.handleEvent = function() return false end
    end
end

local function showWidget(w)
    if not w then return end
    w.ignore = false
    if w._orig_paintTo then
        w.paintTo = w._orig_paintTo
        w._orig_paintTo = nil
        w.handleEvent = w._orig_handleEvent
        w._orig_handleEvent = nil
    end
end

local function series_title(series)
    return (series.metadata and series.metadata.title ~= "" and series.metadata.title) or series.name or "?"
end

-- The title-bar "..." menu's rows: switch grid/list, and -- inside a series
-- -- filter chapters / series actions. Shared by both the stock title-bar
-- button below and the board header's own "..." icon, so there is exactly
-- one copy of this logic regardless of which one is drawing the chrome.
local function buildActionsMenuButtons(browser, opts)
    local _ = browser.plugin.i18n._
    local buttons = {}
    local covers_on = browser.plugin.settings.show_covers ~= false
    -- The board renderer always grids covered entries (see
    -- uchi/ui_board_menu.lua's _gridMode), so this toggle would do nothing
    -- visible there; only the stock renderer still needs it.
    if covers_on and not BoardMenu then
        table.insert(buttons, { {
            text = browser.view_mode == "grid" and _("Switch to list view") or _("Switch to grid view"),
            align = "left",
            callback = function()
                if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                browser:setViewMode(browser.view_mode == "grid" and "list" or "grid")
            end,
        } })
    end
    if opts and opts.is_series then
        table.insert(buttons, { {
            text = _("Filter chapters..."),
            align = "left",
            callback = function()
                if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                browser:showFilterDialog(opts.series, opts.read_status)
            end,
        } })
        table.insert(buttons, { {
            text = _("Series actions..."),
            align = "left",
            callback = function()
                if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                browser:onSeriesHold({ series = opts.series, cover_id = opts.series.id })
            end,
        } })
    end
    return buttons
end

local function toggleTitleButtons(browser, opts)
    local is_home = (#browser.paths == 0)
    if BoardMenu then
        browser.header_show_menu = not is_home
        browser.header_menu_action = (not is_home) and function()
            local ButtonDialog = require("ui/widget/buttondialog")
            browser.menu_dialog = ButtonDialog:new{
                buttons = buildActionsMenuButtons(browser, opts),
                shrink_unneeded_width = true,
            }
            UIManager:show(browser.menu_dialog)
        end or nil
        return
    end
    local title_bar = browser.title_bar
    if not title_bar then return end
    if is_home then
        if title_bar.menu_btn then hideWidget(title_bar.menu_btn) end
    else
        if not title_bar.menu_btn then
            local Button = require("ui/widget/button")
            local Screen = require("device").screen
            title_bar.menu_btn = Button:new{
                icon = "appbar.menu",
                bordersize = 0,
                show_parent = title_bar,
                callback = function() end,
            }
            title_bar.menu_btn.overlap_align = "left"
            title_bar.menu_btn.overlap_offset = { Screen:scaleBySize(10), 0 }
            title_bar.menu_btn:getSize()
            table.insert(title_bar, title_bar.menu_btn)
        end
        showWidget(title_bar.menu_btn)
        title_bar.menu_btn.callback = function()
            local ButtonDialog = require("ui/widget/buttondialog")
            browser.menu_dialog = ButtonDialog:new{
                buttons = buildActionsMenuButtons(browser, opts),
                shrink_unneeded_width = true,
                anchor = function() return title_bar.menu_btn.dimen end,
            }
            UIManager:show(browser.menu_dialog)
        end
    end
    hideWidget(title_bar.left_button)
    browser.onLeftButtonTap = function() end
    UIManager:setDirty(title_bar, "ui")
end

local BrowserBase = BoardMenu or UchiListMenu

local UchiBrowser = BrowserBase:extend{
    is_interactive = true,
    is_fullscreen = true,
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    plugin = nil,
    paths = nil,
    _pagination = nil,
}

function UchiBrowser:init()
    self.paths = {}
    self._pagination = nil
    self.catalog_title = "Uchiyomi"
    self.title = "Uchiyomi"
    -- Fetching the home rails is several sequential server requests (one per
    -- home list, plus on-deck); a bare blocking call here looked like a
    -- hang. This doesn't make it faster, but it stops it looking frozen.
    local InfoMessage = require("ui/widget/infomessage")
    local loading = InfoMessage:new{ text = self.plugin.i18n._("Loading Uchiyomi...") }
    UIManager:show(loading)
    UIManager:forceRePaint()
    self.item_table = self:getHomeItemTable()
    UIManager:close(loading)
    self.title_bar_left_icon = "search"
    self.onLeftButtonTap = function() end
    self.close_callback = function()
        self:onCloseWidget()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:afterWifiAction()
    end
    if BoardMenu then
        BoardMenu.init(self)
    else
        Menu.init(self)
    end
    if self.title_bar and self.title_bar.left_button then hideWidget(self.title_bar.left_button) end
    self:autoSetViewMode(self.item_table)
end

-- ---------------------------------------------------------------------------
-- Rendering / pagination plumbing
-- ---------------------------------------------------------------------------

function UchiBrowser:getPageSize(has_covers)
    if not has_covers then return math.max(6, self.plugin.settings.list_rows or 5) end
    -- The board renderer always grids covered entries regardless of the
    -- saved view_mode (see uchi/ui_board_menu.lua's _gridMode), so it must
    -- always fetch a grid's worth of them too, or a "list" preference would
    -- leave most of the grid empty.
    local mode = self.plugin.settings.view_mode or "list"
    if BoardMenu or mode == "grid" then
        return (self.plugin.settings.grid_columns or 3) * (self.plugin.settings.grid_rows or 3)
    end
    return self.plugin.settings.list_rows or 5
end

function UchiBrowser:autoSetViewMode(item_table)
    if self.plugin.settings.show_covers == false then
        self:setViewMode("list", false)
        return
    end
    local has_covers = false
    if item_table then
        for i = 1, math.min(#item_table, 5) do
            if item_table[i].cover_id or item_table[i].cover_type then has_covers = true; break end
        end
    end
    if #self.paths == 0 or not has_covers then
        self:setViewMode("list", false)
    else
        self:setViewMode(self.plugin.settings.view_mode or "list", false)
    end
end

function UchiBrowser:setViewMode(mode, save_preference)
    if self.plugin.settings.show_covers == false then
        mode = "list"
        save_preference = false
    end
    self.view_mode = mode
    if save_preference ~= false then
        self.plugin.settings.view_mode = mode
        self.plugin:saveSettings()
    end
    if mode == "grid" then
        self._recalculateDimen = function(s)
            _base_grid_recalc(s)
            if s._pagination then s.page_num = s._pagination.total_pages end
        end
        self.updateItems = function(s, select_number)
            s:_maybeLoadMore()
            _base_grid_update(s, select_number)
        end
        self.columns = self.plugin.settings.grid_columns or UchiGridMenu.columns
        self.grid_rows = self.plugin.settings.grid_rows or 3
    else
        self._recalculateDimen = function(s)
            _base_list_recalc(s)
            if s._pagination then s.page_num = s._pagination.total_pages end
        end
        self.updateItems = function(s, select_number)
            s:_maybeLoadMore()
            _base_list_update(s, select_number)
        end
        self.columns = nil
        self.grid_rows = nil
    end
    if self._pagination then
        local p = self._pagination
        local new_size = self:getPageSize(p.has_covers)
        if new_size ~= p.page_size then
            local total_elements = p.total_elements or (p.total_pages * p.page_size)
            p.page_size = new_size
            p.total_pages = math.max(1, math.ceil(total_elements / new_size))
            p.server_page = 0
            local new_items = p.loader(0, new_size) or {}
            for i = #self.item_table, 1, -1 do self.item_table[i] = nil end
            for _i, item in ipairs(new_items) do table.insert(self.item_table, item) end
            if #self.item_table == 0 then
                table.insert(self.item_table, { text = self.plugin.i18n._("Nothing found") })
                p.total_pages = 1
            end
        end
    end
    self.page = 1
    if self.item_table then self:updateItems() end
end

function UchiBrowser:_maybeLoadMore()
    local p = self._pagination
    if not p or not p.loader then return end
    if p.server_page + 1 >= p.total_pages then return end
    if self.page * p.page_size > #self.item_table then
        p.server_page = p.server_page + 1
        local new_items = p.loader(p.server_page, p.page_size)
        for _i, item in ipairs(new_items or {}) do table.insert(self.item_table, item) end
    end
end

function UchiBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        self.catalog_title = path.title
        self._pagination = nil
        self:autoSetViewMode(path.item_table)
        self._pagination = path.opts and path.opts._pagination or nil
        self:switchItemTable(path.title, path.item_table)
        toggleTitleButtons(self, path.opts)
    else
        self:init()
        self:switchItemTable(self.catalog_title, self.item_table)
        toggleTitleButtons(self, nil)
    end
    return true
end

function UchiBrowser:onHoldReturn()
    self:init()
    self:switchItemTable(self.catalog_title, self.item_table)
    toggleTitleButtons(self, nil)
    return true
end

function UchiBrowser:pushCatalog(title, item_table, opts)
    opts = opts or {}
    table.insert(self.paths, { title = title, item_table = item_table, opts = opts })
    self.catalog_title = title
    self._pagination = nil
    self:autoSetViewMode(item_table)
    self._pagination = opts._pagination or nil
    self:switchItemTable(title, item_table)
    toggleTitleButtons(self, opts)
end

--- Generic paginated catalog. args = { title, fetch_func(page,size), item_builder(entry), cover_type, empty_text, push_opts }
function UchiBrowser:_loadCatalog(args)
    local _ = self.plugin.i18n._
    local covers_on = self.plugin.settings.show_covers ~= false
    local effective_cover_type = covers_on and args.cover_type or nil
    local function finalize(item)
        if item and not covers_on then item.cover_id = nil end
        return item
    end
    local page_size = self:getPageSize(effective_cover_type ~= nil)
    local response, err = args.fetch_func(0, page_size)
    if response == nil then
        self.plugin:notify(_("Uchiyomi did not answer: ") .. tostring(err), "error")
        return
    end
    local content, total_pages, total_elements
    if type(response) == "table" then
        content = response.content or response
        total_pages = response.totalPages or 1
        total_elements = response.totalElements
    end
    if effective_cover_type and type(content) == "table" then
        local cover_items = {}
        for _i, e in ipairs(content) do table.insert(cover_items, args.cover_source and args.cover_source(e) or e) end
        self.plugin.cache:prefetchCovers(cover_items, effective_cover_type)
    end
    local item_table = {}
    for _i, entry in ipairs(content or {}) do
        local item = finalize(args.item_builder(entry))
        if item then table.insert(item_table, item) end
    end
    if #item_table == 0 then
        table.insert(item_table, { text = args.empty_text or _("Nothing found") })
        total_pages = 1
    end
    local push_opts = args.push_opts or {}
    if total_pages and total_pages > 1 then
        push_opts._pagination = {
            loader = function(server_page, size)
                local resp = args.fetch_func(server_page, size)
                local new_content = (type(resp) == "table" and (resp.content or resp)) or {}
                if effective_cover_type then
                    local cover_items = {}
                    for _i, e in ipairs(new_content) do table.insert(cover_items, args.cover_source and args.cover_source(e) or e) end
                    self.plugin.cache:prefetchCovers(cover_items, effective_cover_type)
                end
                local items = {}
                for _i, entry in ipairs(new_content) do
                    local item = finalize(args.item_builder(entry))
                    if item then table.insert(items, item) end
                end
                return items
            end,
            server_page = 0,
            total_pages = total_pages,
            total_elements = total_elements or (total_pages * page_size),
            has_covers = effective_cover_type ~= nil,
            page_size = page_size,
        }
    end
    self:pushCatalog(args.title or "", item_table, push_opts)
end

-- ---------------------------------------------------------------------------
-- Home
-- ---------------------------------------------------------------------------

local function series_item(self, series)
    return {
        text = series_title(series),
        callback = function() self:showBooksInSeries(series) end,
        cover_id = series.id,
        cover_type = "series",
        series = series,
    }
end

local function book_item(self, book, with_series)
    return {
        text = Labels.display(book, with_series),
        callback = function() self:onBookSelect(book) end,
        cover_id = self.plugin.settings.show_covers ~= false and book.id or nil,
        cover_type = "book",
        book = book,
    }
end

-- No bracketed page-progress label here (unlike the other home rails
-- below): the board renderer's cover badge already shows it ("16/22"), and
-- the stock list renderer's badge shows the same "page/total" -- a text
-- line repeating it would just be clutter either way. no_caption_sub tells
-- the board renderer's caption-splitting (uchi/ui_cards.lua) not to fall
-- back to a chapter subtitle/author line here either, so every card in
-- this shelf stays reliably one line, not just whichever happen to lack one.
local function keep_reading_item(self, b)
    local item = book_item(self, b, true)
    item.no_caption_sub = true
    return item
end

--- Home data: Uchiyomi's "Keep reading" rail. Cached for ten minutes so returning from a sub-view does
-- not hit the server again. (The "New in favourites" block was dropped in 0.12.2: it cost ~10 requests.)
function UchiBrowser:_homeData(force)
    local p = self.plugin
    local cache = p._home_cache
    if not force and cache and os.time() - cache.ts < 600 then return cache end
    local data = { ts = os.time(), on_deck = {}, lists = {} }
    local home = p.api:get_home()
    if type(home) == "table" and type(home.onDeck) == "table" then
        data.on_deck = home.onDeck
    else
        local hist = self:_keepReadingFromHistory()
        if type(hist) == "table" then data.on_deck = hist.content or {} end
    end
    local limit = tonumber(p.settings.home_list_limit) or 8
    for _i, id in ipairs(p.settings.home_lists or {}) do
        local col = p.api:get_collection(id)
        if type(col) == "table" then
            local entry = { id = id, name = col.name or (p.settings.home_list_names or {})[id] or id, books = {} }
            if col.name then
                p.settings.home_list_names = p.settings.home_list_names or {}
                p.settings.home_list_names[id] = col.name
            end
            for _j, s in ipairs(col.items or col.content or {}) do
                if #entry.books >= limit then break end
                local book = p.sync:getNextUnreadBook(s)
                if book then
                    book.__series = s
                    book.seriesTitle = (book.seriesTitle ~= nil and book.seriesTitle ~= "") and book.seriesTitle or series_title(s)
                    book.__unread = tonumber(s.booksUnreadCount) or (s.yomi and tonumber(s.yomi.unread))
                    table.insert(entry.books, book)
                end
            end
            table.insert(data.lists, entry)
        end
    end
    p._home_cache = data
    return data
end

function UchiBrowser:_reloadHome(force)
    if force then self.plugin._home_cache = nil end
    self:init()
    self:switchItemTable(self.catalog_title, self.item_table)
    toggleTitleButtons(self, nil)
end

-- uchi/menu.lua's "Home screen lists" checklist (which collections show as
-- shelves, and how many series each shows), opened directly from the
-- browser instead of only from Tools > Uchiyomi > Home screen lists.
function UchiBrowser:openHomeListsMenu()
    local StockMenu = require("ui/widget/menu")
    local _ = self.plugin.i18n._
    local menu
    menu = StockMenu:new{
        title = _("Home screen lists"),
        item_table = self.plugin.menu:homeListsMenu(),
        close_callback = function()
            UIManager:close(menu)
            self:_reloadHome(true)
        end,
    }
    UIManager:show(menu)
end

function UchiBrowser:getHomeItemTable()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local NetworkMgr = require("ui/network/manager")
    local online = p.api ~= nil and NetworkMgr:isOnline()
    local items = {}
    local function header(text) table.insert(items, { text = text, is_header = true, select_enabled = false }) end
    local function note(text) table.insert(items, { text = text, select_enabled = false, kind = "note" }) end

    local pending = p.sync:countOfflineBuffer() + p.bookmarks:countOffline()
    if pending > 0 then
        table.insert(items, {
            text = T(_("%1 change(s) waiting to sync  (tap to sync now)"), pending),
            kind = "sync-pending",
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    p.sync:flushOfflineProgress(true)
                    p.bookmarks:flushOffline()
                    self:_reloadHome(true)
                end)
            end,
        })
    end

    if online then
        local ok, data = pcall(self._homeData, self)
        if ok and data then
            if p.settings.show_covers ~= false then
                local covers = {}
                for _i, b in ipairs(data.on_deck) do table.insert(covers, b) end
                for _i, l in ipairs(data.lists) do
                    for _j, b in ipairs(l.books) do table.insert(covers, b) end
                end
                pcall(p.cache.prefetchCovers, p.cache, covers, "book")
            end
            header(_("Keep reading"))
            local dismissed = p.settings.home_dismissed
            local on_deck = {}
            for _i, b in ipairs(data.on_deck) do
                if not (type(dismissed) == "table" and b.id and dismissed[b.id]) then
                    table.insert(on_deck, b)
                end
            end
            if #on_deck == 0 then
                note(_("Nothing in progress. Open a chapter to start."))
            else
                for _i, b in ipairs(on_deck) do table.insert(items, keep_reading_item(self, b)) end
            end
            for _i, l in ipairs(data.lists) do
                header(l.name)
                if #l.books == 0 then
                    note(_("Nothing unread in this list."))
                else
                    for _j, b in ipairs(l.books) do
                        local item = book_item(self, b, true)
                        if b.__unread and b.__unread > 0 then
                            item.text = item.text .. "  [" .. T(_("%1 unread"), b.__unread) .. "]"
                        end
                        table.insert(items, item)
                    end
                end
            end
        else
            logger.warn("kouchiyomi: home failed:", tostring(data))
            note(_("Could not load Keep reading: ") .. tostring(data))
        end
        header(_("Browse"))
        do
            local _sid, sname = self:_scope()
            if sname then
                table.insert(items, { text = T(_("Only showing series in: %1  (tap to show all)"), sname), kind = "scope", callback = function()
                    p._scope_off = true
                    self:_reloadHome(false)
                end })
            elseif p.settings.browse_scope and p.settings.browse_scope ~= "" then
                table.insert(items, { text = T(_("Showing all series  (tap to limit to %1)"), p.settings.browse_scope_name or "?"), kind = "scope", callback = function()
                    p._scope_off = nil
                    self:_reloadHome(false)
                end })
            end
        end
        table.insert(items, { text = _("New chapters (favourites)"), kind = "updates", callback = function() self:showUpdates() end })
        table.insert(items, { text = _("Favourites"), kind = "favorites", callback = function() self:showFavorites() end })
        table.insert(items, { text = _("Bookmarks"), kind = "bookmarks", callback = function() self:showBookmarks() end })
        table.insert(items, { text = _("Recently updated series"), kind = "recent", callback = function() self:showAllSeries("updated,desc", _("Recently updated series")) end })
        table.insert(items, { text = _("All series"), kind = "all-series", callback = function() self:showAllSeries("title,asc", _("All series")) end })
        table.insert(items, { text = _("Libraries"), kind = "libraries", callback = function() self:showLibraries() end })
        table.insert(items, { text = _("Search..."), kind = "search", callback = function() self:promptSearch() end })
        table.insert(items, { text = _("Downloaded chapters (offline)"), kind = "offline", callback = function() self:showOfflineLibrary() end })
        table.insert(items, { text = _("Choose home screen lists"), kind = "manage-lists", callback = function() self:openHomeListsMenu() end })
        table.insert(items, { text = _("Refresh"), kind = "refresh", callback = function() self:_reloadHome(true) end })
    else
        header(_("Offline"))
        table.insert(items, { text = _("Downloaded chapters"), kind = "offline", callback = function() self:showOfflineLibrary() end })
        table.insert(items, { text = _("Choose home screen lists"), kind = "manage-lists", callback = function() self:openHomeListsMenu() end })
        table.insert(items, { text = _("Connect to Wi-Fi and load Keep reading"), kind = "reconnect", callback = function()
            NetworkMgr:runWhenOnline(function() self:_reloadHome(true) end)
        end })
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Catalog views
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Browse scope: only the series of one list (setting `browse_scope`, see uchi/scope)
-- ---------------------------------------------------------------------------

--- The list the catalogue views are limited to: id, name. nil when there is none, or it is switched off for now.
function UchiBrowser:_scope()
    local p = self.plugin
    local id = p.settings.browse_scope
    if type(id) ~= "string" or id == "" or p._scope_off then return nil end
    return id, p.settings.browse_scope_name or id
end

--- The scoped list's series, from the server at most every ten minutes. nil, err when it cannot be read.
function UchiBrowser:_scopeItems(reveal)
    local p = self.plugin
    local id = self:_scope()
    local key = tostring(id) .. (reveal and ":18" or "")
    local c = p._scope_cache
    if c and c.key == key and os.time() - c.ts < 600 then return c.items end
    local res, err
    if id == Scope.FAVORITES then res, err = p.api:get_favorites(reveal) else res, err = p.api:get_collection(id, reveal) end
    if type(res) ~= "table" then return nil, err or "list not available" end
    local items = res.items or res.content or res
    p._scope_cache = { key = key, ts = os.time(), items = items }
    return items
end

--- `plain` is a catalogue view's fetch function; with a scope set it is replaced by one cut from the list.
-- opts: library_id, query, sort, reveal.
function UchiBrowser:_scoped(plain, opts)
    if not self:_scope() then return plain end
    return function(page, size)
        local items, err = self:_scopeItems(opts.reveal)
        if not items then return nil, err end
        return Scope.page(Scope.sort(Scope.filter(items, opts), opts.sort), page, size)
    end
end

--- A view's title, naming the list when it is limited to one.
function UchiBrowser:_scopedTitle(title)
    local _id, name = self:_scope()
    if name then return title .. " (" .. name .. ")" end
    return title
end

function UchiBrowser:showAllSeries(sort, title)
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = self:_scopedTitle(title),
        fetch_func = self:_scoped(function(page, size) return self.plugin.api:search_series(nil, page, size, nil, sort) end,
            { sort = sort }),
        item_builder = function(s) return series_item(self, s) end,
        cover_type = "series",
        empty_text = self.plugin.i18n._("No series found"),
    }
end

function UchiBrowser:showLibraries()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    self:_loadCatalog{
        title = _("Libraries"),
        fetch_func = function() return self.plugin.api:get_libraries() end,
        item_builder = function(lib)
            local name = lib.name or lib.id
            if lib.adult then name = name .. "  (18+)" end
            return { text = name, callback = function() self:showSeriesInLibrary(lib) end }
        end,
        empty_text = _("No libraries found"),
    }
end

function UchiBrowser:showSeriesInLibrary(lib)
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = self:_scopedTitle(lib.name or lib.id),
        fetch_func = self:_scoped(function(page, size)
            -- The one listing that asks to be shown 18+: the reader has opened a
            -- library marked 18+, which is as deliberate as going looking gets.
            return self.plugin.api:search_series(nil, page, size,
                { libraryId = { operator = "is", value = lib.id } }, "title,asc", lib.adult == true)
        end, { library_id = lib.id, sort = "title,asc", reveal = lib.adult == true and self.plugin.settings.show_adult == true }),
        item_builder = function(s) return series_item(self, s) end,
        cover_type = "series",
        empty_text = self.plugin.i18n._("No series in this library"),
    }
end

function UchiBrowser:showFavorites()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    self:_loadCatalog{
        title = _("Favourites"),
        fetch_func = function() return self.plugin.api:get_favorites() end,
        item_builder = function(s) return series_item(self, s) end,
        cover_type = "series",
        empty_text = _("No favourites yet. Hold a series to favourite it."),
    }
end

--- For every favourite series with something left to read: its next unread
-- chapter, series with newly added chapters first. Tap opens the chapter.
function UchiBrowser:showUpdates()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local InfoMessage = require("ui/widget/infomessage")
    self:_loadCatalog{
        title = _("Favourites: next unread"),
        fetch_func = function()
            local favs, err = self.plugin.api:get_favorites()
            if type(favs) ~= "table" then return favs, err end
            local list = favs.content or favs
            local msg = InfoMessage:new{ text = T(_("Checking %1 favourite(s)..."), #list) }
            UIManager:show(msg)
            UIManager:forceRePaint()
            local out = {}
            for i, s in ipairs(list) do
                local book = self.plugin.sync:getNextUnreadBook(s)
                if book then
                    book.__series = s
                    book.seriesTitle = (book.seriesTitle ~= nil and book.seriesTitle ~= "") and book.seriesTitle or series_title(s)
                    book.__unread = tonumber(s.booksUnreadCount) or (s.yomi and tonumber(s.yomi.unread))
                    book.__new = (s.yomi and tonumber(s.yomi.newCount)) or 0
                    book.__order = i
                    table.insert(out, book)
                end
            end
            UIManager:close(msg)
            table.sort(out, function(a, b)
                if a.__new ~= b.__new then return a.__new > b.__new end
                return a.__order < b.__order
            end)
            return { content = out, totalPages = 1 }
        end,
        item_builder = function(b)
            local item = book_item(self, b, true)
            local tags = {}
            if b.__new and b.__new > 0 then table.insert(tags, T(_("+%1 new"), b.__new)) end
            if b.__unread and b.__unread > 0 then table.insert(tags, T(_("%1 unread"), b.__unread)) end
            if #tags > 0 then item.text = item.text .. "  [" .. table.concat(tags, ", ") .. "]" end
            return item
        end,
        cover_type = "book",
        empty_text = _("Every chapter of your favourites is read."),
    }
end

function UchiBrowser:_keepReadingFromHistory()
    local hist, err = self.plugin.api:get_history(40)
    if type(hist) ~= "table" then return hist, err end
    local out = {}
    local seen_series = {}
    for _i, h in ipairs(hist.content or {}) do
        if h.series_id and not seen_series[h.series_id] then
            seen_series[h.series_id] = true
            local book
            if h.completed then
                book = self.plugin.api:get_next_book(h.book_id)
            else
                book = self.plugin.api:get_book(h.book_id)
                if type(book) == "table" and not book.readProgress then
                    book.readProgress = { page = h.page, completed = false }
                end
            end
            if type(book) == "table" and book.id then table.insert(out, book) end
        end
        if #out >= 20 then break end
    end
    return { content = out, totalPages = 1 }
end

function UchiBrowser:showBookmarks()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    self:_loadCatalog{
        title = _("Bookmarks"),
        fetch_func = function() return self.plugin.api:get_bookmarks() end,
        item_builder = function(bm)
            local label = T(_("%1 - %2, page %3"), bm.series_title or "?", bm.book_title or "?", bm.page or "?")
            return {
                text = label,
                callback = function()
                    local book = self.plugin.api:get_book(bm.book_id)
                    if type(book) == "table" and book.id then
                        self:onBookSelect(book, tonumber(bm.page))
                    else
                        self.plugin:notify(_("That chapter is no longer on the server."), "error")
                    end
                end,
            }
        end,
        empty_text = _("No bookmarks on Uchiyomi yet"),
    }
end

function UchiBrowser:promptSearch()
    local _ = self.plugin.i18n._
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search series"),
        input = self._last_search or "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = require("util").trim(dialog:getInputText() or "")
                UIManager:close(dialog)
                if q == "" then return end
                self._last_search = q
                self:_loadCatalog{
                    title = self:_scopedTitle(_("Search: ") .. q),
                    fetch_func = self:_scoped(function(page, size) return self.plugin.api:search_series(q, page, size) end,
                        { query = q }),
                    item_builder = function(s) return series_item(self, s) end,
                    cover_type = "series",
                    empty_text = _("No series matched"),
                }
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Chapters of a series, optionally filtered client-side by read status.
function UchiBrowser:showBooksInSeries(series, read_status)
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    local title = series_title(series)
    local filter
    if read_status and next(read_status) then
        filter = read_status
        local parts = {}
        if filter.UNREAD then table.insert(parts, _("unread")) end
        if filter.IN_PROGRESS then table.insert(parts, _("in progress")) end
        if filter.READ then table.insert(parts, _("read")) end
        if #parts < 3 then title = title .. " (" .. table.concat(parts, ", ") .. ")" end
    end
    local function status_of(b)
        local rp = b.readProgress
        if type(rp) ~= "table" then return "UNREAD" end
        if rp.completed then return "READ" end
        if (rp.page or 0) > 0 then return "IN_PROGRESS" end
        return "UNREAD"
    end
    local fetch
    if filter then
        local all
        fetch = function(page, size)
            if not all then
                all = {}
                for _i, b in ipairs(self.plugin.api:get_all_series_books(series.id) or {}) do
                    if filter[status_of(b)] then table.insert(all, b) end
                end
            end
            local out = {}
            for i = page * size + 1, math.min((page + 1) * size, #all) do table.insert(out, all[i]) end
            return { content = out, totalPages = math.max(1, math.ceil(#all / size)), totalElements = #all }
        end
    else
        fetch = function(page, size) return self.plugin.api:get_series_books(series.id, page, size) end
    end
    self:_loadCatalog{
        title = title,
        fetch_func = fetch,
        item_builder = function(b)
            b.seriesTitle = b.seriesTitle or series_title(series)
            b.__series = series
            return book_item(self, b, false)
        end,
        cover_type = "book",
        empty_text = _("No chapters"),
        push_opts = { is_series = true, series = series, read_status = read_status },
    }
end

function UchiBrowser:showFilterDialog(series, current)
    local ButtonDialog = require("ui/widget/buttondialog")
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local selected = {}
    if current and next(current) then
        for k, v in pairs(current) do selected[k] = v end
    else
        selected = { UNREAD = true, IN_PROGRESS = true, READ = true }
    end
    local dialog
    local function toggle(k) return function() selected[k] = not selected[k] end end
    dialog = ButtonDialog:new{
        title = T(_("Filter: %1"), series_title(series)),
        buttons = {
            {
                { text = _("Unread"), checked_func = function() return selected.UNREAD end, callback = toggle("UNREAD") },
                { text = _("In progress"), checked_func = function() return selected.IN_PROGRESS end, callback = toggle("IN_PROGRESS") },
                { text = _("Read"), checked_func = function() return selected.READ end, callback = toggle("READ") },
            },
            {
                { text = _("Apply"), callback = function()
                    UIManager:close(dialog)
                    self:onReturn()
                    local all = selected.UNREAD and selected.IN_PROGRESS and selected.READ
                    self:showBooksInSeries(series, (not all) and selected or nil)
                end },
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Offline library
-- ---------------------------------------------------------------------------

function UchiBrowser:showOfflineLibrary()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local item_table = {}
    for _i, grp in ipairs(self.plugin.sync:getOfflineSeriesList()) do
        local title = (grp.series and grp.series ~= "" and grp.series) or _("Unknown series")
        local status = grp.unread == 0 and _("all read") or T(_("%1 unread / %2"), grp.unread, grp.total)
        table.insert(item_table, {
            text = title .. "  (" .. status .. ")",
            callback = function() self:showOfflineBooksInSeries(grp, title) end,
        })
    end
    if #item_table == 0 then table.insert(item_table, { text = _("No downloaded chapters yet.") }) end
    self._pagination = nil
    self:pushCatalog(_("Downloaded chapters"), item_table, {})
end

function UchiBrowser:showOfflineBooksInSeries(grp, title)
    local _ = self.plugin.i18n._
    local ui = self.plugin.ui
    local item_table = {}
    for _i, info in ipairs(grp.books) do
        local marker = info.finished and "\u{2713} " or (info.in_progress and "\u{25B8} " or "\u{2022} ")
        local idx = info.series_index and ("#" .. tostring(info.series_index) .. "  ") or ""
        local label = marker .. idx .. (info.title or info.path)
        if info.in_progress and info.percent then
            label = label .. string.format("  (%d%%)", math.floor(info.percent * 100 + 0.5))
        end
        local path = info.path
        table.insert(item_table, {
            text = label,
            callback = function()
                UIManager:nextTick(function()
                    UIManager:close(self)
                    require("apps/filemanager/filemanagerutil").openFile(ui, path)
                end)
            end,
            hold_callback = function() self:onOfflineBookHold(info) end,
        })
    end
    if #item_table == 0 then table.insert(item_table, { text = _("No downloaded chapters in this series.") }) end
    self._pagination = nil
    self:pushCatalog(title, item_table, {})
end

function UchiBrowser:onOfflineBookHold(info)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = info.title or info.path,
        buttons = {
            { { text = _("Delete downloaded file"), callback = function()
                UIManager:close(dialog)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete %1 from this device? Progress stays on Uchiyomi."), info.title or info.path),
                    ok_callback = function()
                        os.remove(info.path)
                        self.plugin.sync:purgeSidecar(info.path)
                        self.plugin.settings.matched_books_cache[info.path] = nil
                        if self.plugin.settings.downloaded_books then self.plugin.settings.downloaded_books[info.path] = nil end
                        self.plugin:saveSettings()
                        self:onReturn()
                        self:showOfflineLibrary()
                    end,
                })
            end } },
            { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Opening chapters
-- ---------------------------------------------------------------------------

function UchiBrowser:_openLocal(path, goto_page)
    local ui = self.plugin.ui
    UIManager:nextTick(function()
        UIManager:close(self)
        -- On the class: opening the file builds a new plugin instance, so a
        -- field on this one would never be read.
        if goto_page then require("uchi/sync").pending_goto_page = goto_page end
        require("apps/filemanager/filemanagerutil").openFile(ui, path)
    end)
end

function UchiBrowser:_download(book, then_open, goto_page)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self.plugin.sync:downloadBook(book, book.seriesTitle, function(path)
            if then_open then self:_openLocal(path, goto_page) end
            self:updateItems()
        end, nil, book.__series)
    end)
end

function UchiBrowser:_stream(book, goto_page)
    UIManager:nextTick(function()
        UIManager:close(self)
        self.plugin.stream:open(book, goto_page)
    end)
end

--- Tap on a chapter. goto_page (optional) jumps to a page after opening.
function UchiBrowser:onBookSelect(book, goto_page)
    local _ = self.plugin.i18n._
    local sync = self.plugin.sync
    local local_path = sync:getBookLocalPath(book, book.seriesTitle)
    local lfs = require("libs/libkoreader-lfs")
    if local_path and lfs.attributes(local_path, "mode") == "file" then
        self:_openLocal(local_path, goto_page)
        return
    end
    local mode = self.plugin:openModeFor(book, book.__series)
    if mode == "download" then
        self:_download(book, true, goto_page)
    elseif mode == "stream" then
        self:_stream(book, goto_page)
    else
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = Labels.display(book, true),
            buttons = {
                { { text = _("Download & open"), is_enter_default = true, callback = function() UIManager:close(dialog); self:_download(book, true, goto_page) end } },
                { { text = _("Stream"), callback = function() UIManager:close(dialog); self:_stream(book, goto_page) end } },
                { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } },
            },
        }
        UIManager:show(dialog)
    end
end

function UchiBrowser:promptCount(title, default_val, confirm_text, on_confirm)
    local InputDialog = require("ui/widget/inputdialog")
    local _ = self.plugin.i18n._
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(default_val or 5),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = confirm_text or _("Download"), is_enter_default = true, callback = function()
                local n = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if n and n >= 1 then on_confirm(math.floor(n)) end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function UchiBrowser:_downloadBookList(books)
    SeriesActions.download_books(self.plugin, books, { changed = function() self:updateItems() end })
end

-- ---------------------------------------------------------------------------
-- Hold menus
-- ---------------------------------------------------------------------------

-- A series gone from the library (or from Favourites) leaves the list being looked at, and every list underneath
-- it that would show it again on the way back.
function UchiBrowser:_dropSeries(series_id)
    local function drop(items)
        if type(items) ~= "table" then return end
        for i = #items, 1, -1 do
            local e = items[i]
            if e and ((e.series and e.series.id == series_id) or (e.book and e.book.seriesId == series_id and e.cover_type ~= "series")) then
                table.remove(items, i)
            end
        end
    end
    drop(self.item_table)
    for _i, path in ipairs(self.paths or {}) do drop(path.item_table) end
    self:updateItems()
end

-- What changed about a series from its hold menu, as far as the list on screen is concerned.
function UchiBrowser:_seriesChanged(what, series)
    if what == "removed" and series then
        self:_dropSeries(series.id)
    elseif what == "favorite" and series and self.catalog_title == self.plugin.i18n._("Favourites") and not SeriesActions.is_favorite(series) then
        self:_dropSeries(series.id)
    elseif #self.paths == 0 then
        self:_reloadHome(true)
    else
        local here = self.paths[#self.paths]
        if what == "read" and here and here.opts and here.opts.series and series and here.opts.series.id == series.id then
            -- The chapter rows carry their read state; load them again.
            self:onReturn()
            self:showBooksInSeries(here.opts.series, here.opts.read_status)
        else
            self:updateItems()
        end
    end
end

function UchiBrowser:_seriesHooks()
    return {
        changed = function(what, series) self:_seriesChanged(what, series) end,
        open_book = function(book) self:onBookSelect(book) end,
        open_library = function(series)
            local res = self.plugin.api:get_libraries()
            local libs = type(res) == "table" and (res.content or res) or {}
            local lib = { id = series.libraryId }
            for _i, l in ipairs(libs) do
                if tostring(l.id) == tostring(series.libraryId) then lib = l break end
            end
            self:showSeriesInLibrary(lib)
        end,
    }
end

function UchiBrowser:onSeriesHold(entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local series = entry.series
    if not series or not series.id then return end
    local dialog
    local buttons = SeriesActions.rows(self.plugin, series, self:_seriesHooks(), function() UIManager:close(dialog) end)
    table.insert(buttons, { { text = self.plugin.i18n._("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = series_title(series), shrink_unneeded_width = true, buttons = buttons }
    UIManager:show(dialog)
end

-- Marks a Keep reading card's chapter read, then updates that same card in
-- place to the series' next unread chapter (so the row still has an entry
-- to open, just the next one) instead of refetching the whole home screen
-- -- only removes the card when getNextUnreadBook finds nothing left
-- unread. entry is the exact table in self.item_table (see
-- uchi/ui_board_menu.lua: the same entry reference flows from
-- item_table through Cards.cell's hit action to here), so mutating it in
-- place is enough; self:updateItems() just repaints with the new content.
function UchiBrowser:_markKeepReadingEntryRead(entry, book)
    local _ = self.plugin.i18n._
    local ok = self.plugin.sync:setBookRead(book, true)
    if not ok then
        self.plugin:notify(_("Could not update read status"), "error")
        return
    end
    local series_id = book.seriesId or book.series_id
    local next_book = nil
    if series_id and self.plugin.api then
        local series = self.plugin.api:get_series(series_id)
        if type(series) == "table" then
            next_book = self.plugin.sync:getNextUnreadBook(series)
        end
    end
    if next_book then
        if self.plugin.settings.show_covers ~= false then
            pcall(self.plugin.cache.prefetchCovers, self.plugin.cache, { next_book }, "book")
        end
        entry.book = next_book
        entry.text = Labels.display(next_book, true)
        entry.cover_id = self.plugin.settings.show_covers ~= false and next_book.id or nil
        entry.callback = function() self:onBookSelect(next_book) end
        self.plugin:notify(_("Marked read — next chapter ready"), "info")
    else
        for i, it in ipairs(self.item_table) do
            if it == entry then table.remove(self.item_table, i); break end
        end
        self.plugin:notify(_("Marked read"), "info")
    end
    self:updateItems()
end

-- Hold on a Home shelf card (Keep reading, or a home list): quick "I don't
-- want to see this here" actions, since there is no other way to curate
-- either shelf. Keep reading has no book.__series (it comes from Uchiyomi's
-- on-deck list, not a favourited series): that's what tells a pure
-- Keep-reading card apart from a home-list one, and is what gates "Remove
-- from Continue Reading" below. Returns true when it handled the hold,
-- false to fall through to the full chapter action sheet.
function UchiBrowser:onHomeCardHold(entry)
    local book = entry.book
    if not book then return false end
    local _ = self.plugin.i18n._
    local series = book.__series
    local is_fav = series and ((series.yomi and series.yomi.favorite == true) or series.favorite == true)
    local is_read = type(book.readProgress) == "table" and book.readProgress.completed
    if not series and not book.id and is_read then return false end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    if series and series.id then
        table.insert(buttons, { { text = is_fav and _("Remove from favourites") or _("Add to favourites"), align = "left", callback = function()
            UIManager:close(dialog)
            local ok = is_fav and self.plugin.api:remove_favorite(series.id) or self.plugin.api:add_favorite(series.id)
            if ok then
                self.plugin:notify(is_fav and _("Removed from favourites") or _("Added to favourites"), "info")
                self:_reloadHome(true)
            else
                self.plugin:notify(_("Could not update favourites"), "error")
            end
        end } })
    end
    -- Local to this device only: Uchiyomi's own reading state (and its
    -- favourite/unread status) is untouched, so it is not "marking as read"
    -- -- it just stops this chapter from appearing on this shelf, the way
    -- Plex lets you clear something off Continue Watching without
    -- finishing it. getHomeItemTable filters on_deck against this set.
    if not series and book.id then
        table.insert(buttons, { { text = _("Remove from Continue Reading"), align = "left", callback = function()
            UIManager:close(dialog)
            self.plugin.settings.home_dismissed = self.plugin.settings.home_dismissed or {}
            self.plugin.settings.home_dismissed[book.id] = true
            self.plugin:saveSettings()
            self.plugin:notify(_("Removed from Continue Reading"), "info")
            self:_reloadHome(false)
        end } })
    end
    if not is_read then
        if series then
            -- A home-list card is already "the next unread chapter of this
            -- favourited series" (see _homeData); reloading after marking
            -- this one read makes getNextUnreadBook pick the new one on
            -- its own, so a plain reload already does the right thing.
            table.insert(buttons, { { text = _("Mark as read  (remove from here)"), align = "left", callback = function()
                UIManager:close(dialog)
                local ok = self.plugin.sync:setBookRead(book, true)
                if ok then
                    self.plugin:notify(_("Marked read"), "info")
                    self:_reloadHome(true)
                else
                    self.plugin:notify(_("Could not update read status"), "error")
                end
            end } })
        else
            -- A Keep reading card: Uchiyomi's own on-deck list does not
            -- reliably advance to the series' next chapter by itself (a
            -- plain reload after marking read was just dropping the card),
            -- so this looks up the next unread chapter explicitly and only
            -- drops the card when there really is nothing left unread.
            table.insert(buttons, { { text = _("Mark as read"), align = "left", callback = function()
                UIManager:close(dialog)
                self:_markKeepReadingEntryRead(entry, book)
            end } })
        end
    end
    table.insert(buttons, { { text = _("More..."), align = "left", callback = function()
        UIManager:close(dialog)
        self:onChapterHold(entry)
    end } })
    table.insert(buttons, { { text = _("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = Labels.display(book, true), buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
    return true
end

function UchiBrowser:onMenuHold(entry)
    if not entry then return end
    if entry.hold_callback then entry.hold_callback(); return end
    if entry.cover_type == "series" or entry.series ~= nil then
        self:onSeriesHold(entry)
        return
    end
    if #self.paths == 0 and self:onHomeCardHold(entry) then return end
    self:onChapterHold(entry)
end

-- The series a chapter belongs to, as the server describes it (the chapter only carries its id and title).
function UchiBrowser:_seriesOfBook(book)
    if type(book.__series) == "table" and book.__series.id then return book.__series end
    local series, err = self.plugin.api:get_series(book.seriesId)
    if type(series) ~= "table" or not series.id then
        self.plugin:notify(self.plugin.i18n.T(self.plugin.i18n._("Could not load the series: %1"), tostring(err or "?")), "error")
        return nil
    end
    return series
end

-- The full chapter action sheet (Open/Download/Stream/mark read/delete).
-- Called directly for a hold anywhere other than a Home shelf card, and
-- from onHomeCardHold's "More..." row.
function UchiBrowser:onChapterHold(entry)
    local book = entry.book
    if not book then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local title = Labels.display(book, true)
    local downloaded = self.plugin.sync:isBookDownloaded(book)
    local is_read = type(book.readProgress) == "table" and book.readProgress.completed
    local dialog
    local buttons = {}
    if downloaded then
        table.insert(buttons, { { text = _("Open"), align = "left", callback = function() UIManager:close(dialog); self:onBookSelect(book) end } })
    else
        table.insert(buttons, { { text = _("Download"), align = "left", callback = function() UIManager:close(dialog); self:_download(book, false) end } })
        table.insert(buttons, { { text = _("Download & open"), align = "left", callback = function() UIManager:close(dialog); self:_download(book, true) end } })
    end
    table.insert(buttons, { { text = _("Stream"), align = "left", callback = function() UIManager:close(dialog); self:_stream(book) end } })
    table.insert(buttons, { { text = _("Download this + next chapters..."), align = "left", callback = function()
        UIManager:close(dialog)
        self:promptCount(_("How many chapters after this one?"), 5, _("Download"), function(n)
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function()
                self:_downloadBookList(self.plugin.sync:getBookAndFollowing(book, n))
            end)
        end)
    end } })
    table.insert(buttons, { { text = is_read and _("Mark as unread") or _("Mark as read"), align = "left", callback = function()
        UIManager:close(dialog)
        local ok = self.plugin.sync:setBookRead(book, not is_read)
        if ok then
            book.readProgress = (not is_read) and { page = (book.media and book.media.pagesCount) or 1, completed = true } or nil
            self:updateItems()
        else
            self.plugin:notify(_("Could not update read status"), "error")
        end
    end } })
    if downloaded then
        table.insert(buttons, { { text = _("Delete downloaded file"), align = "left", callback = function()
            UIManager:close(dialog)
            local path = self.plugin.sync:getBookLocalPath(book, book.seriesTitle)
            if path then
                os.remove(path)
                self.plugin.sync:purgeSidecar(path)
                self.plugin.settings.matched_books_cache[path] = nil
                if self.plugin.settings.downloaded_books then self.plugin.settings.downloaded_books[path] = nil end
                self.plugin:saveSettings()
                self:updateItems()
            end
        end } })
    end
    -- Chapters turn up outside their series (new chapters, bookmarks, history, Keep reading): from here the series
    -- is one tap away, and so are its actions.
    local sid = book.seriesId
    local here = self.paths[#self.paths]
    local in_series = here and here.opts and here.opts.series and here.opts.series.id == sid
    if sid and not in_series then
        table.insert(buttons, { { text = _("Open series"), align = "left", callback = function()
            UIManager:close(dialog)
            local series = self:_seriesOfBook(book)
            if series then self:showBooksInSeries(series) end
        end }, { text = _("Series actions..."), align = "left", callback = function()
            UIManager:close(dialog)
            local series = self:_seriesOfBook(book)
            if series then self:onSeriesHold({ series = series, cover_id = series.id }) end
        end } })
    end
    table.insert(buttons, { { text = _("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = title, buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

return UchiBrowser
