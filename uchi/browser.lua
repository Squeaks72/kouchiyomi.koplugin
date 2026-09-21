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

local _base_list_recalc = UchiListMenu._recalculateDimen
local _base_list_update = UchiListMenu.updateItems
local _base_grid_recalc = UchiGridMenu._recalculateDimen
local _base_grid_update = UchiGridMenu.updateItems

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

local function book_title(book)
    return (book.metadata and book.metadata.title ~= "" and book.metadata.title) or book.name or "?"
end

local function toggleTitleButtons(browser, opts)
    local title_bar = browser.title_bar
    if not title_bar then return end
    local _ = browser.plugin.i18n._
    local is_home = (#browser.paths == 0)
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
            local buttons = {}
            local covers_on = browser.plugin.settings.show_covers ~= false
            if covers_on then
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
            browser.menu_dialog = ButtonDialog:new{
                buttons = buttons,
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

local UchiBrowser = UchiListMenu:extend{
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
    self.item_table = self:getHomeItemTable()
    self.title_bar_left_icon = "search"
    self.onLeftButtonTap = function() end
    self.close_callback = function()
        self:onCloseWidget()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:afterWifiAction()
    end
    Menu.init(self)
    if self.title_bar and self.title_bar.left_button then hideWidget(self.title_bar.left_button) end
    self:autoSetViewMode(self.item_table)
end

-- ---------------------------------------------------------------------------
-- Rendering / pagination plumbing
-- ---------------------------------------------------------------------------

function UchiBrowser:getPageSize(has_covers)
    local mode = self.plugin.settings.view_mode or "list"
    if not has_covers then return math.max(6, self.plugin.settings.list_rows or 5) end
    if mode == "grid" then
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

function UchiBrowser:getHomeItemTable()
    local _ = self.plugin.i18n._
    return {
        { text = _("Continue reading"),       callback = function() self:showContinueReading() end },
        { text = _("New chapters (favourites)"), callback = function() self:showUpdates() end },
        { text = _("Favourites"),             callback = function() self:showFavorites() end },
        { text = _("Bookmarks"),              callback = function() self:showBookmarks() end },
        { text = _("Recently updated series"), callback = function() self:showAllSeries("updated,desc", _("Recently updated series")) end },
        { text = _("All series"),             callback = function() self:showAllSeries("title,asc", _("All series")) end },
        { text = _("Libraries"),              callback = function() self:showLibraries() end },
        { text = _("Search..."),              callback = function() self:promptSearch() end },
        { text = _("Downloaded chapters (offline)"), callback = function() self:showOfflineLibrary() end },
    }
end

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
    local text = book_title(book)
    if with_series and book.seriesTitle then text = book.seriesTitle .. " - " .. text end
    return {
        text = text,
        callback = function() self:onBookSelect(book) end,
        cover_id = book.id,
        cover_type = "book",
        book = book,
    }
end

-- ---------------------------------------------------------------------------
-- Catalog views
-- ---------------------------------------------------------------------------

function UchiBrowser:showAllSeries(sort, title)
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = title,
        fetch_func = function(page, size) return self.plugin.api:search_series(nil, page, size, nil, sort) end,
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
        title = lib.name or lib.id,
        fetch_func = function(page, size)
            return self.plugin.api:search_series(nil, page, size, { libraryId = { operator = "is", value = lib.id } }, "title,asc")
        end,
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

function UchiBrowser:showUpdates()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    self:_loadCatalog{
        title = _("New chapters"),
        fetch_func = function() return self.plugin.api:get_updates() end,
        cover_source = function(u) return u.series end,
        item_builder = function(u)
            local s = u.series
            if not s then return nil end
            local item = series_item(self, s)
            item.text = T(_("%1  (+%2 new)"), series_title(s), u.newCount or 0)
            return item
        end,
        cover_type = "series",
        empty_text = _("No new chapters in your favourites"),
    }
end

function UchiBrowser:showContinueReading()
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    self:_loadCatalog{
        title = _("Continue reading"),
        fetch_func = function()
            local hist = self.plugin.api:get_history(40)
            if type(hist) ~= "table" then return hist end
            local out = {}
            local seen_series = {}
            for _i, h in ipairs(hist.content or {}) do
                if h.series_id and not seen_series[h.series_id] then
                    seen_series[h.series_id] = true
                    local book
                    if h.completed then
                        book = self.plugin.api:get_next_book(h.book_id)
                        if book then book.__label = _("Next up") end
                    else
                        book = self.plugin.api:get_book(h.book_id)
                        if book then book.__label = T(_("Page %1"), h.page or "?") end
                    end
                    if type(book) == "table" and book.id then table.insert(out, book) end
                end
                if #out >= 20 then break end
            end
            return { content = out, totalPages = 1 }
        end,
        item_builder = function(b)
            local item = book_item(self, b, true)
            if b.__label then item.text = item.text .. "  [" .. b.__label .. "]" end
            return item
        end,
        cover_type = "book",
        empty_text = _("Nothing in progress. Open a chapter to start."),
    }
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
                    title = _("Search: ") .. q,
                    fetch_func = function(page, size) return self.plugin.api:search_series(q, page, size) end,
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
        if goto_page then self.plugin.pending_goto_page = goto_page end
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
    local mode = self.plugin.settings.open_mode or "download"
    if mode == "download" then
        self:_download(book, true, goto_page)
    elseif mode == "stream" then
        self:_stream(book, goto_page)
    else
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog
        dialog = ButtonDialog:new{
            title = book_title(book),
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
    local _ = self.plugin.i18n._
    local to_download = {}
    for _i, b in ipairs(books or {}) do
        if not self.plugin.sync:isBookDownloaded(b) then table.insert(to_download, b) end
    end
    if #to_download == 0 then
        self.plugin:notify(_("Nothing to download (already on the device)."), "info")
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self.plugin.sync:downloadBooksSeq(to_download, 1, function()
            self.plugin:notify(_("Downloads finished."), "info")
            self:updateItems()
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Hold menus
-- ---------------------------------------------------------------------------

function UchiBrowser:onSeriesHold(entry)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local series = entry.series
    if not series or not series.id then return end
    local title = series_title(series)
    local dialog
    local is_fav = (series.yomi and series.yomi.favorite == true) or series.favorite == true
    dialog = ButtonDialog:new{
        title = title,
        shrink_unneeded_width = true,
        buttons = {
            { { text = _("Download next unread chapters..."), align = "left", callback = function()
                UIManager:close(dialog)
                self:promptCount(_("How many chapters?"), 5, _("Download"), function(n)
                    local NetworkMgr = require("ui/network/manager")
                    NetworkMgr:runWhenOnline(function()
                        self:_downloadBookList(self.plugin.sync:getNextUnreadBooksInSeries(series.id, n))
                    end)
                end)
            end } },
            { { text = is_fav and _("Remove from favourites") or _("Add to favourites"), align = "left", callback = function()
                UIManager:close(dialog)
                local ok
                if is_fav then ok = self.plugin.api:remove_favorite(series.id) else ok = self.plugin.api:add_favorite(series.id) end
                if ok then
                    series.yomi = series.yomi or {}
                    series.yomi.favorite = not is_fav
                    self.plugin:notify(is_fav and _("Removed from favourites") or _("Added to favourites"), "info")
                else
                    self.plugin:notify(_("Could not update favourites"), "error")
                end
            end } },
            { { text = _("Mark all chapters read"), align = "left", callback = function()
                UIManager:close(dialog)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Mark every chapter of %1 as read on Uchiyomi?"), title),
                    ok_callback = function()
                        local n = 0
                        for _i, b in ipairs(self.plugin.api:get_all_series_books(series.id) or {}) do
                            if self.plugin.sync:setBookRead(b, true) then n = n + 1 end
                        end
                        self.plugin:notify(T(_("Marked %1 chapter(s) read"), n), "info")
                        self:updateItems()
                    end,
                })
            end } },
            { { text = _("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } },
        },
    }
    UIManager:show(dialog)
end

function UchiBrowser:onMenuHold(entry)
    if not entry then return end
    if entry.hold_callback then entry.hold_callback(); return end
    if entry.cover_type == "series" or entry.series ~= nil then
        self:onSeriesHold(entry)
        return
    end
    local book = entry.book
    if not book then return end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local title = book_title(book)
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
    table.insert(buttons, { { text = _("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = title, buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

return UchiBrowser
