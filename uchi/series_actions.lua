--[[
    What can be done to a SERIES, wherever it turns up: the browser's hold menu on any series thumbnail, its
    "Series actions..." row, and the reader's menu-bar sheet (uchi/reader_menu) all draw their rows from here, so
    they cannot drift apart.

    Everything takes `plugin` and a Uchiyomi series DTO (`{ id, name, libraryId, autoUpdate, yomi = { favorite },
    metadata = { title, summary, genres, status, author } }`). Nothing here knows about the browser: a caller that
    wants its view updated passes `hooks.changed(what, series)`, `what` being "favorite", "read", "removed" or
    "monitor".

    Remove from library, Check for new chapters and Monitor are Uchiyomi's ADMIN routes. The token this device
    runs on is read + write, which the server refuses there on purpose (a token left on a Kobo must not manage the
    server), so those ask for the admin password once, use the 15-minute session it returns, and keep it in memory
    only -- nothing admin-scoped is ever stored on the device.
--]]

local UIManager = require("ui/uimanager")

local SA = {}

-- An admin session lives 15 minutes on the server; use it for 13 so the last call never lands on an expired one.
local ADMIN_SESSION_SECONDS = 13 * 60
-- On the module, not the plugin: a new plugin instance is built with every document that opens.
SA.admin_session = nil

function SA.title(series)
    return (series.metadata and series.metadata.title ~= "" and series.metadata.title) or series.name or "?"
end

function SA.is_favorite(series)
    return (series.yomi and series.yomi.favorite == true) or series.favorite == true
end

function SA.is_monitored(series)
    return series.autoUpdate ~= false
end

-- ---------------------------------------------------------------------------
-- Admin calls
-- ---------------------------------------------------------------------------

--- The in-memory admin session, if one is still good.
function SA.live_admin_token()
    local s = SA.admin_session
    if s and os.time() - s.at < ADMIN_SESSION_SECONDS then return s.token end
    SA.admin_session = nil
    return nil
end

--- Ask for the admin password (and a 2FA code when the account has one). `on_token(token)` gets the session.
function SA.ask_admin_login(plugin, on_token)
    local _ = plugin.i18n._
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Admin password"),
        description = _("Removing a series from the library, checking it for new chapters and monitoring it are admin actions, which this device's token is not allowed to do. The password is used once and not stored."),
        fields = {
            { hint = _("Password"), text_type = "password" },
            { hint = _("2FA code (only if enabled on the account)"), input_type = "number" },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Continue"), is_enter_default = true, callback = function()
                local password, totp = unpack(dialog:getFields())
                if not password or password == "" then plugin:notify(_("Enter the admin password"), "error"); return end
                UIManager:close(dialog)
                UIManager:scheduleIn(0.2, function()
                    local token, err = plugin.api:admin_login(plugin.settings.username or "", password, totp)
                    if not token then
                        plugin:notify(tostring(err or _("Login failed")), "error")
                        return
                    end
                    SA.admin_session = { token = token, at = os.time() }
                    on_token(token)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[
    Run an admin call. `call(token)` does the request with that token (nil = the device's own) and returns
    `res, err, code`; `on_done(res, err, code)` gets the final answer. The device's own token is tried first, so a
    token that does carry the admin scope never asks for a password; a 403 asks once.
--]]
function SA.admin_call(plugin, call, on_done)
    local _ = plugin.i18n._
    local res, err, code = call(SA.live_admin_token())
    if res or code ~= 403 then return on_done(res, err, code) end
    SA.admin_session = nil
    SA.ask_admin_login(plugin, function(token)
        local r, e, c = call(token)
        if not r and c == 403 then e = _("That account is not an admin.") end
        on_done(r, e, c)
    end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function SA.toggle_favorite(plugin, series, hooks)
    local _ = plugin.i18n._
    local was = SA.is_favorite(series)
    local ok
    if was then ok = plugin.api:remove_favorite(series.id) else ok = plugin.api:add_favorite(series.id) end
    if not ok then
        plugin:notify(_("Could not update favourites"), "error")
        return false
    end
    series.yomi = series.yomi or {}
    series.yomi.favorite = not was
    series.favorite = nil
    plugin._home_cache = nil
    plugin:notify(was and _("Removed from favourites") or _("Added to favourites"), "info")
    if hooks and hooks.changed then hooks.changed("favorite", series) end
    return true
end

--- Pick one of the caller's lists (or make a new one) and put the series in it.
function SA.add_to_list(plugin, series, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local res, err = plugin.api:get_lists()
    local lists = type(res) == "table" and (res.content or res) or nil
    if type(lists) ~= "table" then
        plugin:notify(T(_("Could not load your lists: %1"), tostring(err or "?")), "error")
        return
    end
    local dialog
    local function added(list)
        local ok, e = plugin.api:add_to_list(list.id, series.id)
        if ok then
            plugin._home_cache = nil
            plugin:notify(T(_("Added to %1"), list.name or "?"), "info")
            if hooks and hooks.changed then hooks.changed("list", series) end
        else
            plugin:notify(T(_("Could not add to the list: %1"), tostring(e or "?")), "error")
        end
    end
    local buttons = {}
    for _i, list in ipairs(lists) do
        -- A smart list fills itself from a search; only hand-made ones take a series.
        if type(list) == "table" and list.id and (list.kind == nil or list.kind == "manual") and list.mine ~= false then
            table.insert(buttons, { { text = list.name or "?", align = "left", callback = function()
                UIManager:close(dialog)
                added(list)
            end } })
        end
    end
    table.insert(buttons, { { text = _("New list..."), align = "left", callback = function()
        UIManager:close(dialog)
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = _("Name of the new list"),
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                { text = _("Create and add"), is_enter_default = true, callback = function()
                    local name = require("util").trim(input:getInputText() or "")
                    if name == "" then return end
                    UIManager:close(input)
                    local list, e = plugin.api:create_list(name)
                    if type(list) == "table" and list.id then added(list)
                    else plugin:notify(T(_("Could not create the list: %1"), tostring(e or "?")), "error") end
                end },
            } },
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end } })
    table.insert(buttons, { { text = _("Cancel"), align = "center", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = T(_("Add %1 to a list"), SA.title(series)), buttons = buttons, shrink_unneeded_width = true }
    UIManager:show(dialog)
end

--- The chapters of this series that are on the device: Sync's offline infos with this series' id.
function SA.downloaded(plugin, series)
    local out = {}
    local ok, infos = pcall(plugin.sync.getDownloadedBookInfos, plugin.sync)
    if not ok then return out end
    for _i, info in ipairs(infos) do
        if tostring(info.series_id or "") == tostring(series.id) then table.insert(out, info) end
    end
    return out
end

--- Mark every chapter read / unread: one request, then the copies on this device follow so the reader and the
-- server agree. (The old way asked once per chapter, which for a long series was minutes of a frozen screen.)
function SA.mark_all(plugin, series, read, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local ConfirmBox = require("ui/widget/confirmbox")
    local title = SA.title(series)
    UIManager:show(ConfirmBox:new{
        text = read and T(_("Mark every chapter of %1 as read on Uchiyomi?"), title)
            or T(_("Mark every chapter of %1 as unread on Uchiyomi? Reading progress for the series is cleared."), title),
        ok_callback = function()
            local ok, err = plugin.api:set_series_read({ series.id }, read)
            if not ok then
                plugin:notify(T(_("Could not update read status: %1"), tostring(err or "?")), "error")
                return
            end
            local Sidecar = require("uchi/sidecar")
            local open_path = plugin.ui and plugin.ui.document and plugin.ui.document.file
            for _i, info in ipairs(SA.downloaded(plugin, series)) do
                if info.path ~= open_path then
                    local total = info.page_count or 0
                    pcall(Sidecar.writeLocalProgress, info.path, read and total or 1, total, read)
                end
            end
            plugin._home_cache = nil
            plugin:notify(read and _("Marked every chapter read") or _("Marked every chapter unread"), "info")
            if hooks and hooks.changed then hooks.changed("read", series) end
        end,
    })
end

--- Delete this series' downloaded chapters from the device (progress stays on Uchiyomi).
function SA.delete_downloaded(plugin, series, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local infos = SA.downloaded(plugin, series)
    if #infos == 0 then
        plugin:notify(_("Nothing from this series is downloaded."), "info")
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1 downloaded chapter(s) of %2 from this device? Progress stays on Uchiyomi."), #infos, SA.title(series)),
        ok_callback = function()
            local open_path = plugin.ui and plugin.ui.document and plugin.ui.document.file
            local n = 0
            for _i, info in ipairs(infos) do
                if info.path ~= open_path then
                    plugin.sync:deleteDownloadedFile(info.path, false)
                    n = n + 1
                end
            end
            plugin:notify(T(_("Deleted %1 chapter(s) from this device"), n), "info")
            if hooks and hooks.changed then hooks.changed("downloads", series) end
        end,
    })
end

--- Queue the next unread chapters for download.
function SA.download_next(plugin, series, hooks)
    local _ = plugin.i18n._
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("How many chapters?"),
        input = "5",
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Download"), is_enter_default = true, callback = function()
                local n = tonumber(dialog:getInputText())
                UIManager:close(dialog)
                if not (n and n >= 1) then return end
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(function()
                    SA.download_books(plugin, plugin.sync:getNextUnreadBooksInSeries(series.id, math.floor(n)), hooks)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SA.download_books(plugin, books, hooks)
    local _ = plugin.i18n._
    local todo = {}
    for _i, b in ipairs(books or {}) do
        if not plugin.sync:isBookDownloaded(b) then table.insert(todo, b) end
    end
    if #todo == 0 then
        plugin:notify(_("Nothing to download (already on the device)."), "info")
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        plugin.sync:downloadBooksSeq(todo, 1, function()
            plugin:notify(_("Downloads finished."), "info")
            if hooks and hooks.changed then hooks.changed("downloads") end
        end)
    end)
end

--- A text page about the series: author, status, genres, counts, summary.
function SA.show_info(plugin, series)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local md = series.metadata or {}
    local lines = {}
    local function add(label, value)
        if value ~= nil and tostring(value) ~= "" then table.insert(lines, label .. ": " .. tostring(value)) end
    end
    add(_("Author"), md.author)
    local status = md.status and md.status ~= "" and md.status:sub(1, 1) .. md.status:sub(2):lower() or nil
    add(_("Status"), status)
    if type(md.genres) == "table" and #md.genres > 0 then add(_("Genres"), table.concat(md.genres, ", ")) end
    local count = tonumber(series.booksCount)
    if count then
        local read = tonumber(series.booksReadCount)
        add(_("Chapters"), read and read > 0 and T(_("%1 (%2 read)"), count, read) or count)
    end
    add(_("Monitored"), SA.is_monitored(series) and _("yes, new chapters are fetched") or _("no"))
    add(_("On this device"), T(_("%1 chapter(s)"), #SA.downloaded(plugin, series)))
    if md.summary and md.summary ~= "" then
        table.insert(lines, "")
        table.insert(lines, md.summary)
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = SA.title(series), text = table.concat(lines, "\n") })
end

--- Admin: look for new chapters now.
function SA.check_now(plugin, series, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    SA.admin_call(plugin, function(token) return plugin.api:admin_check_series(series.id, token) end, function(res, err)
        if res then
            plugin:notify(T(_("Checking %1 for new chapters. They appear in a few minutes."), SA.title(series)), "info")
            if hooks and hooks.changed then hooks.changed("check", series) end
        else
            plugin:notify(T(_("Could not start the check: %1"), tostring(err or "?")), "error")
        end
    end)
end

--- Admin: start or stop fetching new chapters for the series.
function SA.set_monitored(plugin, series, monitored, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    SA.admin_call(plugin, function(token) return plugin.api:admin_set_monitored(series.id, monitored, token) end, function(res, err)
        if res then
            series.autoUpdate = monitored
            plugin:notify(monitored and T(_("Monitoring %1"), SA.title(series)) or T(_("No longer monitoring %1"), SA.title(series)), "info")
            if hooks and hooks.changed then hooks.changed("monitor", series) end
        else
            plugin:notify(T(_("Could not change monitoring: %1"), tostring(err or "?")), "error")
        end
    end)
end

--- Admin: remove from the library. This HIDES the series on the server (its files, progress, favourites and
-- ratings stay, and Admin > Library puts it back); it is not a delete. Asks first.
function SA.remove_from_library(plugin, series, hooks)
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove %1 from your Uchiyomi library?\n\nIt is hidden from every list and no longer updated. Its files and your reading progress are kept, and an admin can put it back under Admin > Library."), SA.title(series)),
        ok_text = _("Remove"),
        ok_callback = function()
            SA.admin_call(plugin, function(token) return plugin.api:admin_hide_series(series.id, token) end, function(res, err)
                if res then
                    plugin._home_cache = nil
                    plugin:notify(T(_("Removed %1 from the library"), SA.title(series)), "info")
                    if hooks and hooks.changed then hooks.changed("removed", series) end
                else
                    plugin:notify(T(_("Could not remove it: %1"), tostring(err or "?")), "error")
                end
            end)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- The dialog
-- ---------------------------------------------------------------------------

--[[
    The hold menu for a series, as ButtonDialog rows. `hooks`:
      changed(what, series)   the view should refresh
      open_book(book)         enables "Continue reading" (only a browser can open a chapter)
      open_library(series)    enables "Open library"
      open_series(series)     enables "Open series"
    Paired rows keep it short enough to fit a small screen without scrolling.
--]]
function SA.rows(plugin, series, hooks, close)
    local _ = plugin.i18n._
    hooks = hooks or {}
    local rows = {}
    local function item(text, fn, o)
        o = o or {}
        return { text = text, align = o.align, enabled = o.enabled, callback = function()
            if close then close() end
            fn()
        end }
    end
    local function row(...) table.insert(rows, { ... }) end

    if hooks.open_book then
        row(item(_("Continue reading"), function()
            local book = plugin.sync:getNextUnreadBook(series)
            if book then
                book.seriesTitle = book.seriesTitle or SA.title(series)
                book.__series = series
                hooks.open_book(book)
            else
                plugin:notify(_("Everything in this series is read."), "info")
            end
        end, { align = "left" }))
    end
    if hooks.open_series then row(item(_("Open series"), function() hooks.open_series(series) end, { align = "left" })) end
    row(item(_("Download next unread chapters..."), function() SA.download_next(plugin, series, hooks) end, { align = "left" }))
    row(
        item(SA.is_favorite(series) and _("Remove from favourites") or _("Add to favourites"), function() SA.toggle_favorite(plugin, series, hooks) end),
        item(_("Add to list..."), function() SA.add_to_list(plugin, series, hooks) end))
    row(
        item(_("Mark all read"), function() SA.mark_all(plugin, series, true, hooks) end),
        item(_("Mark all unread"), function() SA.mark_all(plugin, series, false, hooks) end))
    local on_device = #SA.downloaded(plugin, series)
    row(
        item(_("Series info..."), function() SA.show_info(plugin, series) end),
        hooks.open_library and series.libraryId and item(_("Open library"), function() hooks.open_library(series) end) or nil)
    if on_device > 0 then
        row(item(plugin.i18n.T(_("Delete %1 downloaded chapter(s) from this device..."), on_device), function() SA.delete_downloaded(plugin, series, hooks) end, { align = "left" }))
    end
    row(
        item(_("Check for new chapters"), function() SA.check_now(plugin, series, hooks) end),
        item(SA.is_monitored(series) and _("Stop monitoring") or _("Monitor"), function() SA.set_monitored(plugin, series, not SA.is_monitored(series), hooks) end))
    row(item(_("Remove from library..."), function() SA.remove_from_library(plugin, series, hooks) end, { align = "left" }))
    return rows
end

return SA
