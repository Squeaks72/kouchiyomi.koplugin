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

local DEFAULT_SETTINGS = {
    server_url = "",
    username = "",
    api_token = "",
    opds_token = "",
    show_adult = false,

    open_mode = "download",          -- download | stream | ask
    offer_stream = false,
    auto_reading_direction = true,

    sync_progress = true,
    sync_bookmarks = true,
    sync_forward = "silent",         -- prompt | silent | disable
    sync_backward = "prompt",
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
        table.insert(lines, "End-of-chapter hook installed: " .. tostring(ui.status ~= nil and ui.status.orig_onEndOfBook ~= nil))
        table.insert(lines, "Last end-of-chapter outcome: " .. tostring(self.last_end_of_chapter or "none yet in this chapter"))
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

    -- End-of-book hook: mark the chapter read and offer the next one. Every
    -- way this can decline is recorded (Tools > Uchiyomi > Diagnostics).
    if ui.status and not ui.status.orig_onEndOfBook then
        ui.status.orig_onEndOfBook = ui.status.onEndOfBook
        ui.status.onEndOfBook = function(this, ...)
            local args = { ... }
            local show_native = function()
                if this.orig_onEndOfBook then this.orig_onEndOfBook(this, unpack(args)) end
            end
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
            else
                self.last_end_of_chapter = self.is_active and "not a Uchiyomi chapter" or "plugin inactive"
            end
            if this.orig_onEndOfBook then return this.orig_onEndOfBook(this, ...) end
        end
    end

    if not self.current_book_id then return end

    -- Reading direction from the series metadata (manga => RTL).
    if self.settings.auto_reading_direction ~= false then
        pcall(function()
            local Sidecar = require("uchi/sidecar")
            local ds = Sidecar.openDocSettings(filepath, false)
            local dir = ds and ds:readSetting("uchiyomi_reading_direction")
            if not dir then
                local cm = Sidecar.loadCustomMetadata(filepath)
                dir = cm and cm.uchiyomi_reading_direction
            end
            if dir == "RIGHT_TO_LEFT" and ui.view and not ui.view.inverse_reading_order then
                ui.view:onToggleReadingOrder(true)
                if ui.doc_settings then ui.doc_settings:saveSetting("inverse_reading_order", true) end
            end
        end)
    end

    -- A bookmark tapped in the browser asked to open at a given page.
    if self.pending_goto_page then
        local page = self.pending_goto_page
        self.pending_goto_page = nil
        UIManager:nextTick(function()
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("GotoPage", page))
        end)
    end

    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isOnline() then
        if next(self.settings.offline_progress_buffer or {}) then self.sync:flushOfflineProgress(false) end
        self.bookmarks:flushOffline()
        if not self.pending_goto_page then self.sync:pullProgress(ui, false) end
        self.bookmarks:syncOpenDocument(ui, false)
    end
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
    end)
end

return Plugin
