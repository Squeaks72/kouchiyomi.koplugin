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

function Menu:createMainMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local items = {}

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
                return (p.settings.opds_token and p.settings.opds_token ~= "") and _("OPDS token: set (fast CBZ downloads)") or _("OPDS token: missing (downloads page by page)")
            end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("OPDS token"), "opds_token", false, tm) end,
        },
        {
            text_func = function() return T(_("Username: %1"), p.settings.username or "") end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Username"), "username", false, tm) end,
        },
        {
            text = _("Show 18+ libraries"),
            checked_func = function() return p.settings.show_adult == true end,
            keep_menu_open = true,
            callback = function()
                p.settings.show_adult = not p.settings.show_adult
                p:saveSettings()
                p:initAPI()
            end,
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
    local function mode_item(value, label)
        return {
            text = label,
            checked_func = function() return (p.settings.open_mode or "download") == value end,
            radio = true,
            keep_menu_open = true,
            callback = function() p.settings.open_mode = value; p:saveSettings() end,
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
            text = _("New chapters"),
            separator = true,
            -- These are written into a chapter's sidecar as it downloads, which is the only moment
            -- KOReader will read them without the document being re-rendered. Chapters already on the
            -- device keep whatever they were last closed with.
            sub_item_table = {
                { text = _("View mode:"), enabled = false },
                pick("chapter_view_mode", "page", _("One page per turn"), "leave"),
                pick("chapter_view_mode", "continuous", _("Continuous scroll (webtoons)"), "leave"),
                pick("chapter_view_mode", "leave", _("Leave KOReader alone"), "leave"),
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
            text_func = function()
                local n = tonumber(p.settings.read_ahead) or 1
                if n <= 0 then return _("Read ahead: off") end
                return T(_("Read ahead: fetch the next %1 chapter(s) in the background"), n)
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
            text = _("Delete a finished chapter once Uchiyomi has it marked read"),
            help_text = _("When you move on to the next chapter, the finished file is removed after the server confirms it is read. Progress and bookmarks stay on Uchiyomi."),
            checked_func = function() return p.settings.delete_read_on_advance ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.delete_read_on_advance = not (p.settings.delete_read_on_advance ~= false); p:saveSettings() end,
        },
    }
end

function Menu:syncMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    local labels = { prompt = _("ask"), silent = _("jump silently"), disable = _("ignore") }
    local order = { "silent", "prompt", "disable" }
    local function cycle(key)
        local cur = p.settings[key] or "prompt"
        for i, v in ipairs(order) do
            if v == cur then p.settings[key] = order[i % #order + 1]; break end
        end
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
            text_func = function() return T(_("When Uchiyomi is behind: %1"), labels[p.settings.sync_backward or "prompt"]) end,
            keep_menu_open = true,
            callback = function(tm) cycle("sync_backward"); if tm then tm:updateItems() end end,
        },
        {
            text_func = function() return T(_("Push progress every %1 pages"), p.settings.push_interval or 5) end,
            keep_menu_open = true,
            callback = function(tm) self:promptInput(_("Pages between progress pushes"), "push_interval", true, tm) end,
        },
        {
            text = _("Reconcile downloaded chapters when Wi-Fi connects"),
            checked_func = function() return p.settings.reconcile_on_connect ~= false end,
            keep_menu_open = true,
            callback = function() p.settings.reconcile_on_connect = not (p.settings.reconcile_on_connect ~= false); p:saveSettings() end,
        },
        {
            text = _("Show pending sync / download count in the reader footer"),
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

function Menu:layoutMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local p = self.plugin
    return {
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
            text_func = function() return (p.settings.github_token ~= "" ) and _("GitHub token: set") or _("GitHub token: none (needed while the repo is private)") end,
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

function Menu:openBrowser(offline)
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
