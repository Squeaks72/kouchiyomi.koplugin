--[[
    Reading-progress sync, downloads and offline library for kouchiyomi.

    Model: a downloaded chapter file is bound to an Uchiyomi book id through
    its sidecar (see uchi/sidecar.lua). Progress is pushed on our own triggers
    (page turns, close, suspend) and pulled when a chapter is opened or Wi-Fi
    comes back. When offline, the latest state per book is buffered and
    flushed later; Uchiyomi's own progress wins ties and is never regressed.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Sidecar = require("uchi/sidecar")

local Sync = {}

function Sync:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

local function sanitize_filename(name)
    name = tostring(name or ""):gsub('[/%\\%:%*%?%"%<%>%|]', "_"):gsub("%s+$", ""):gsub("^%s+", "")
    if name == "" then name = "untitled" end
    return name
end
Sync.sanitize_filename = sanitize_filename

local function book_title(book)
    return (book.metadata and book.metadata.title) or book.name or book.id or "Untitled"
end
Sync.book_title = book_title

-- ---------------------------------------------------------------------------
-- File <-> book binding
-- ---------------------------------------------------------------------------

function Sync:getOrMatchBook(filepath)
    if not filepath then return nil end
    local cached = self.plugin.settings.matched_books_cache[filepath]
    if cached then return cached end
    local id = Sidecar.readBookId(filepath)
    if id then
        self.plugin.settings.matched_books_cache[filepath] = id
        self.plugin:saveSettings()
        return id
    end
    return nil, "Not linked"
end

--- True when a file lives inside the plugin's download folder.
function Sync:isUnderDownloadDir(filepath)
    if not filepath then return false end
    local dir = self.plugin.settings.download_dir
    if not dir or dir == "" then
        local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
        if not home or home == "" then return false end
        dir = home .. "/Uchiyomi"
    end
    dir = dir:gsub("/+$", "")
    return filepath:sub(1, #dir + 1) == dir .. "/"
end

local function norm_name(s)
    s = sanitize_filename(tostring(s or "")):lower():gsub("%s+", " ")
    return s
end

--- Best effort: bind a file that reached the device outside the plugin
-- (syncthing, USB, another client) to its Uchiyomi chapter. The parent
-- folder is matched against series titles, the file name against chapter
-- titles, then against chapter numbers. Returns the book id, or nil, reason.
function Sync:autoLinkFile(filepath)
    if not self.plugin.api or not filepath then return nil, "not configured" end
    local dir, fname = filepath:match("^(.*)/([^/]+)$")
    if not fname then return nil, "no file name" end
    local stem = fname:gsub("%.%w+$", "")
    local folder = dir and dir:match("([^/]+)$") or ""
    if folder == "" then return nil, "no series folder" end

    local res, err = self.plugin.api:search_series(folder, 0, 20)
    if type(res) ~= "table" then return nil, "series search failed: " .. tostring(err) end
    local list = res.content or res
    local candidates = {}
    for _i, s in ipairs(list) do
        if s.id and norm_name((s.metadata and s.metadata.title) or s.name) == norm_name(folder) then
            table.insert(candidates, s)
        end
    end
    if #candidates == 0 and #list == 1 and list[1].id then candidates[1] = list[1] end
    if #candidates == 0 then return nil, "no series on the server is called '" .. folder .. "'" end

    local want_num = tonumber(stem:match("(%d+%.?%d*)%s*$") or stem:match("[Cc]h%a*%.?%s*(%d+%.?%d*)"))
    for _i, series in ipairs(candidates) do
        local books = self.plugin.api:get_all_series_books(series.id) or {}
        local by_title, by_number, number_hits = nil, nil, 0
        for _j, b in ipairs(books) do
            if norm_name(book_title(b)) == norm_name(stem) or norm_name(b.name) == norm_name(stem) then
                by_title = b
                break
            end
            local n = tonumber(b.metadata and b.metadata.number) or tonumber(b.number)
            if want_num and n and n == want_num then
                by_number = b
                number_hits = number_hits + 1
            end
        end
        local book = by_title or (number_hits == 1 and by_number) or nil
        if book then
            local s_title = (series.metadata and series.metadata.title) or series.name
            book.seriesTitle = (book.seriesTitle and book.seriesTitle ~= "") and book.seriesTitle or s_title
            self.plugin.settings.matched_books_cache[filepath] = book.id
            self.plugin:saveSettings()
            pcall(Sidecar.saveBookMetadata, filepath, book, s_title, series)
            logger.info("kouchiyomi: auto-linked", filepath, "->", book.id)
            return book.id, book
        end
    end
    return nil, "no chapter matching '" .. stem .. "' in " .. tostring((candidates[1].metadata and candidates[1].metadata.title) or candidates[1].name)
end

function Sync:getLocalPathForBookId(book_id)
    if not book_id then return nil end
    local target = tostring(book_id)
    local lfs = require("libs/libkoreader-lfs")
    for path, mid in pairs(self.plugin.settings.matched_books_cache or {}) do
        if tostring(mid) == target and lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return nil
end

--- Manually link the open document to a chapter, by searching the server.
function Sync:matchCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not doc or not doc.file then
        self.plugin:notify(_("No open book to match."), "error")
        return
    end
    if not self.plugin.api then
        self.plugin:notify(_("Uchiyomi is not configured."), "error")
        return
    end
    local filepath = doc.file
    local filename = filepath:match("([^/\\]+)$") or filepath
    local parent_dir = filepath:match("([^/\\]+)[/\\][^/\\]+$") or ""
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search Uchiyomi for the series"),
        input = parent_dir ~= "" and parent_dir or filename:gsub("%.%w+$", ""),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                self:_pickSeriesThenBook(filepath, q)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Sync:_pickSeriesThenBook(filepath, query)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local res = self.plugin.api:search_series(query, 0, 10)
    local content = res and res.content or {}
    if #content == 0 then
        self.plugin:notify(_("No matching series found."), "error")
        return
    end
    local dialog
    local buttons = {}
    for _i, s in ipairs(content) do
        table.insert(buttons, { {
            text = s.name or (s.metadata and s.metadata.title) or s.id,
            callback = function()
                UIManager:close(dialog)
                self:_pickBook(filepath, s)
            end,
        } })
    end
    table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = _("Select the series"), buttons = buttons }
    UIManager:show(dialog)
end

function Sync:_pickBook(filepath, series)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local books = self.plugin.api:get_all_series_books(series.id) or {}
    if #books == 0 then
        self.plugin:notify(_("That series has no chapters on the server."), "error")
        return
    end
    local page_size = 10
    local total_pages = math.ceil(#books / page_size)
    local dialog
    local function showPage(pn)
        local buttons = {}
        for i = (pn - 1) * page_size + 1, math.min(pn * page_size, #books) do
            local book = books[i]
            table.insert(buttons, { {
                text = book_title(book),
                callback = function()
                    UIManager:close(dialog)
                    self.plugin.settings.matched_books_cache[filepath] = book.id
                    self.plugin:saveSettings()
                    pcall(Sidecar.saveBookMetadata, filepath, book, series.name, series)
                    self.plugin:notify(T(_("Linked to: %1"), book_title(book)), "info")
                    if self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file == filepath then
                        self.plugin.current_book_id = book.id
                        self:pullProgress(self.plugin.ui, false)
                        if self.plugin.bookmarks then self.plugin.bookmarks:syncOpenDocument(self.plugin.ui) end
                    end
                end,
            } })
        end
        local nav = {}
        if pn > 1 then table.insert(nav, { text = "<< " .. _("Prev"), callback = function() UIManager:close(dialog); showPage(pn - 1) end }) end
        if pn < total_pages then table.insert(nav, { text = _("Next") .. " >>", callback = function() UIManager:close(dialog); showPage(pn + 1) end }) end
        if #nav > 0 then table.insert(buttons, nav) end
        table.insert(buttons, { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } })
        local title = _("Select the chapter")
        if total_pages > 1 then title = title .. " (" .. pn .. "/" .. total_pages .. ")" end
        dialog = ButtonDialog:new{ title = title, buttons = buttons }
        UIManager:show(dialog)
    end
    showPage(1)
end

function Sync:unlinkCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    if not doc or not doc.file then
        self.plugin:notify(_("No open book to unlink."), "error")
        return
    end
    self.plugin.settings.matched_books_cache[doc.file] = nil
    self.plugin:saveSettings()
    Sidecar.clearBookId(doc.file)
    self.plugin.current_book_id = nil
    self.plugin:notify(_("Unlinked from Uchiyomi."), "info")
end

-- ---------------------------------------------------------------------------
-- Progress: pull
-- ---------------------------------------------------------------------------

local function current_page(ui)
    return ui.view and ui.view.state and ui.view.state.page or 1
end

local function page_count(ui)
    return (ui.view and ui.view.state and ui.view.state.page_count)
        or (ui.document and ui.document.getPageCount and ui.document:getPageCount())
        or current_page(ui)
end

function Sync:isDocMarkedComplete(ui)
    if not ui or not ui.doc_settings then return false end
    local summary = ui.doc_settings:readSetting("summary")
    if type(summary) == "table" and summary.status == "complete" then return true end
    local pct = ui.doc_settings:readSetting("percent_finished")
    return type(pct) == "number" and pct >= 1
end

function Sync:markOpenDocComplete(ui)
    if not ui or not ui.doc_settings then return end
    local summary = ui.doc_settings:readSetting("summary") or {}
    if summary.status ~= "complete" then
        summary.status = "complete"
        summary.modified = os.date("%Y-%m-%d", os.time())
        ui.doc_settings:saveSetting("summary", summary)
        pcall(function()
            local BookList = require("ui/widget/booklist")
            BookList.setBookInfoCacheProperty(ui.document.file, "status", "complete")
        end)
    end
end

--- Pull server progress for the open document and reconcile with the local
-- position according to the configured strategies.
function Sync:pullProgress(ui, is_manual)
    if not self.plugin.settings.sync_progress then return false end
    if not self.plugin.api or not ui or not ui.document then return false end
    local filepath = ui.document.file
    local book_id = filepath and self:getOrMatchBook(filepath)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not book_id then
        if is_manual then self.plugin:notify(_("This book is not linked to Uchiyomi. Use 'Link current book' first."), "error") end
        return false
    end

    local function do_pull()
        local progress, err = self.plugin.api:get_read_progress(book_id)
        if progress == nil then
            if is_manual then self.plugin:notify(T(_("Could not fetch progress: %1"), tostring(err)), "error") end
            return false
        end
        if type(progress) ~= "table" then
            if is_manual then self.plugin:notify(_("No progress recorded on the server yet."), "info") end
            return true
        end
        local total = page_count(ui)
        local cur = current_page(ui)
        local remote = tonumber(progress.page) or 0
        if progress.completed then
            self:markOpenDocComplete(ui)
            if remote == 0 then remote = total end
        end
        if remote <= 0 or remote == cur then
            if is_manual then self.plugin:notify(_("Already at the server position."), "info") end
            return true
        end
        local strategy, text
        if remote > cur then
            strategy = self.plugin.settings.sync_forward or "silent"
            text = T(_("Uchiyomi is further along (page %1 of %2). Jump there?"), remote, total)
        else
            strategy = self.plugin.settings.sync_backward or "prompt"
            text = T(_("Uchiyomi is behind (page %1 of %2). Go back there?"), remote, total)
        end
        if strategy == "disable" then return true end
        local Event = require("ui/event")
        if strategy == "silent" then
            UIManager:broadcastEvent(Event:new("GotoPage", remote))
            self.plugin.last_pushed_page = remote
            if is_manual then self.plugin:notify(T(_("Jumped to page %1"), remote), "info") end
        else
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("GotoPage", remote))
                    self.plugin.last_pushed_page = remote
                end,
            })
        end
        return true
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then
            NetworkMgr:willRerunWhenOnline(do_pull)
        end
        return false
    end
    return do_pull()
end

-- ---------------------------------------------------------------------------
-- Progress: push
-- ---------------------------------------------------------------------------

function Sync:bufferOfflineProgress(book_id, page, total_pages, completed)
    if not book_id then return end
    local buf = self.plugin.settings.offline_progress_buffer or {}
    buf[tostring(book_id)] = { page = page, total_pages = total_pages, completed = completed and true or false, ts = os.time() }
    self.plugin.settings.offline_progress_buffer = buf
    self.plugin:saveSettings()
end

function Sync:countOfflineBuffer()
    local n = 0
    for _i in pairs(self.plugin.settings.offline_progress_buffer or {}) do n = n + 1 end
    return n
end

function Sync:_offlineEntryIsAhead(entry, server)
    if type(server) ~= "table" then return true end
    if server.completed then return false end
    if entry.completed then return true end
    return (tonumber(entry.page) or 0) > (tonumber(server.page) or 0)
end

function Sync:flushOfflineProgress(is_manual)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local buf = self.plugin.settings.offline_progress_buffer or {}
    local pending = self:countOfflineBuffer()
    if pending == 0 then
        if is_manual then self.plugin:notify(_("Nothing pending."), "info") end
        return
    end
    if not self.plugin.api then return end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then
            NetworkMgr:willRerunWhenOnline(function() self:flushOfflineProgress(true) end)
        end
        return
    end
    local flushed, failed, superseded = 0, 0, 0
    for book_id, entry in pairs(buf) do
        local server = self.plugin.api:get_read_progress(book_id)
        if not self:_offlineEntryIsAhead(entry, server) then
            if type(server) == "table" and server.completed then self:markLocalBookComplete(book_id) end
            buf[book_id] = nil
            superseded = superseded + 1
        else
            local ok, err = self.plugin.api:put_progress(book_id, entry.page, entry.completed, false)
            if ok then
                buf[book_id] = nil
                flushed = flushed + 1
            else
                failed = failed + 1
                logger.warn("kouchiyomi: offline flush failed for", tostring(book_id), tostring(err))
            end
        end
    end
    self.plugin.settings.offline_progress_buffer = buf
    self.plugin:saveSettings()
    if is_manual or flushed > 0 then
        if failed > 0 then
            self.plugin:notify(T(_("Synced %1 chapter(s); %2 still pending."), flushed, failed), "error")
        elseif flushed == 0 and superseded > 0 then
            self.plugin:notify(T(_("Uchiyomi was already ahead for %1 chapter(s)."), superseded), "info")
        else
            self.plugin:notify(T(_("Synced offline progress for %1 chapter(s)."), flushed), "info")
        end
    end
end

function Sync:markLocalBookComplete(book_id)
    local path = self:getLocalPathForBookId(book_id)
    if not path then return end
    local open_path = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
    if path == open_path then return end
    Sidecar.writeLocalProgress(path, nil, nil, true)
end

--- Push the open document's position. Buffers when offline.
function Sync:pushProgressForDocument(ui)
    if not self.plugin.settings.sync_progress then return end
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    local book_id = filepath and self:getOrMatchBook(filepath)
    if not book_id then return end
    local cur = current_page(ui)
    local total = page_count(ui)
    local completed = cur >= total
    if not completed and self:isDocMarkedComplete(ui) then
        cur = total
        completed = true
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        self:bufferOfflineProgress(book_id, cur, total, completed)
        return
    end
    if next(self.plugin.settings.offline_progress_buffer or {}) then
        self:flushOfflineProgress(false)
    end
    local ok, err = self.plugin.api:put_progress(book_id, cur, completed, false)
    if not ok then
        logger.warn("kouchiyomi: progress push failed:", tostring(err))
        self:bufferOfflineProgress(book_id, cur, total, completed)
    end
end

--- Mark a chapter read/unread on the server (and locally if downloaded).
function Sync:setBookRead(book, read)
    if not self.plugin.api then return false end
    local total = (book.media and book.media.pagesCount) or 0
    local ok, err
    if read then
        ok, err = self.plugin.api:put_progress(book.id, total > 0 and total or 1, true, true)
    else
        ok, err = self.plugin.api:put_progress(book.id, 0, false, true)
    end
    if ok then
        local path = self:getLocalPathForBookId(book.id)
        if path then
            local open_path = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
            if path ~= open_path then
                Sidecar.writeLocalProgress(path, read and total or 1, total, read)
            end
        end
    end
    return ok, err
end

-- ---------------------------------------------------------------------------
-- Reconcile every downloaded chapter with the server (server wins)
-- ---------------------------------------------------------------------------

--- For each downloaded, linked chapter that is NOT open, pull the server's
-- progress and bookmarks into the local sidecar. Returns the count changed.
function Sync:reconcileDownloaded(is_manual)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not self.plugin.api then return 0 end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then self.plugin:notify(_("Offline: cannot reconcile with Uchiyomi now."), "error") end
        return 0
    end
    -- Anything we recorded offline goes up first so it is not overwritten.
    if next(self.plugin.settings.offline_progress_buffer or {}) then
        self:flushOfflineProgress(false)
    end
    if self.plugin.bookmarks then self.plugin.bookmarks:flushOffline() end

    local open_path = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
    local changed = 0
    local server_bookmarks
    for _i, info in ipairs(self:getDownloadedBookInfos()) do
        if info.book_id and info.path ~= open_path then
            local progress, _err, book = self.plugin.api:get_read_progress(info.book_id)
            if book then
                local total = (book.media and book.media.pagesCount) or info.page_count or 0
                if type(progress) == "table" then
                    local rp = tonumber(progress.page) or 0
                    local local_page = info.page or 0
                    if progress.completed ~= info.finished or (rp > 0 and rp ~= local_page) then
                        Sidecar.writeLocalProgress(info.path, rp > 0 and rp or nil, total, progress.completed)
                        changed = changed + 1
                    end
                end
                if self.plugin.bookmarks and self.plugin.settings.sync_bookmarks then
                    server_bookmarks = server_bookmarks or self.plugin.bookmarks:fetchServerBookmarks()
                    if server_bookmarks then
                        if self.plugin.bookmarks:syncClosedDocument(info.path, info.book_id, server_bookmarks[info.book_id] or {}) then
                            changed = changed + 1
                        end
                    end
                end
            end
        end
    end
    if is_manual then
        self.plugin:notify(T(_("Reconciled with Uchiyomi: %1 chapter(s) updated."), changed), "info")
    end
    return changed
end

-- ---------------------------------------------------------------------------
-- Downloads
-- ---------------------------------------------------------------------------

function Sync:getBookLocalPath(book, series_title)
    local title = sanitize_filename(book_title(book))
    if not title:lower():match("%.cbz$") then title = title .. ".cbz" end
    local download_dir = self.plugin:getDownloadDir()
    if not download_dir then return nil end
    local s_title = series_title or book.seriesTitle
    if self.plugin.settings.download_to_subfolder and s_title and s_title ~= "" then
        download_dir = download_dir .. "/" .. sanitize_filename(s_title)
    end
    return download_dir .. "/" .. title, title
end

function Sync:isBookDownloaded(book)
    local path = self:getBookLocalPath(book, book.seriesTitle)
    if not path then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "file"
end

function Sync:getNextUnreadBooksInSeries(series_id, count)
    if not self.plugin.api or not series_id then return {} end
    local books = self.plugin.api:get_all_series_books(series_id) or {}
    local out = {}
    for _i, b in ipairs(books) do
        local rp = b.readProgress
        if not (type(rp) == "table" and rp.completed) then
            table.insert(out, b)
            if #out >= count then break end
        end
    end
    return out
end

--- The first chapter of a series (in reading order) that is not finished,
-- or nil when everything is read. The server's read count is used to start
-- near the right page; chapters read out of order are caught by a full scan.
function Sync:getNextUnreadBook(series)
    if not self.plugin.api or not series or not series.id then return nil end
    local unread = tonumber(series.booksUnreadCount) or (series.yomi and tonumber(series.yomi.unread))
    if unread == 0 then return nil end
    local size = 100
    local start = math.floor((tonumber(series.booksReadCount) or 0) / size)
    local function scan(from, to)
        for page = from, to do
            local res = self.plugin.api:get_series_books(series.id, page, size)
            if type(res) ~= "table" then return nil, true end
            local content = res.content or res
            for _i, b in ipairs(content) do
                local rp = b.readProgress
                if not (type(rp) == "table" and rp.completed) then return b end
            end
            if res.last == true or #content < size then return nil end
        end
        return nil
    end
    local found, failed = scan(start, start + 500)
    if found or failed or start == 0 then return found end
    return (scan(0, start - 1))
end

function Sync:getBookAndFollowing(book, count)
    local list = { book }
    if not self.plugin.api or not book or not book.id then return list end
    local current = book.id
    for _ = 1, count do
        local nxt = self.plugin.api:get_next_book(current)
        if type(nxt) ~= "table" or not nxt.id then break end
        table.insert(list, nxt)
        current = nxt.id
    end
    return list
end

function Sync:getManagedDownloadsSize()
    local lfs = require("libs/libkoreader-lfs")
    local total, count = 0, 0
    for path in pairs(self.plugin.settings.downloaded_books or {}) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            total = total + attr.size
            count = count + 1
        end
    end
    return total, count
end

function Sync:purgeSidecar(filepath)
    pcall(function()
        local DocSettings = require("docsettings")
        local has = true
        if DocSettings.hasSidecarFile then has = DocSettings:hasSidecarFile(filepath) end
        if has then DocSettings:open(filepath):purge() end
    end)
end

function Sync:enforceDownloadCap(protect_path)
    local max_gb = tonumber(self.plugin.settings.max_download_gb)
    if not max_gb or max_gb <= 0 then return end
    local max_bytes = math.floor(max_gb * 1024 * 1024 * 1024)
    local lfs = require("libs/libkoreader-lfs")
    local reg = self.plugin.settings.downloaded_books or {}
    local open_path = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
    local entries, total, changed = {}, 0, false
    for path, ts in pairs(reg) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            total = total + attr.size
            table.insert(entries, { path = path, ts = tonumber(ts) or attr.modification or 0, size = attr.size })
        else
            reg[path] = nil
            changed = true
        end
    end
    if total > max_bytes then
        table.sort(entries, function(a, b) return a.ts < b.ts end)
        local evicted = 0
        for _i, e in ipairs(entries) do
            if total <= max_bytes then break end
            if e.path ~= protect_path and e.path ~= open_path then
                os.remove(e.path)
                self:purgeSidecar(e.path)
                reg[e.path] = nil
                self.plugin.settings.matched_books_cache[e.path] = nil
                total = total - e.size
                evicted = evicted + 1
                changed = true
            end
        end
        if evicted > 0 then
            local _ = self.plugin.i18n._
            local T = self.plugin.i18n.T
            self.plugin:notify(T(_("Storage cap: removed %1 old chapter(s)"), evicted), "info")
        end
    end
    if changed then self.plugin:saveSettings() end
end

--- Download one chapter; calls on_success(path) / on_failure(err) on the next tick.
function Sync:downloadBook(book, series_title, on_success, on_failure, series)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    series = series or book.__series
    if not series and self.plugin.api and book.seriesId then
        local s = self.plugin.api:get_series(book.seriesId)
        if type(s) == "table" then series = s; book.__series = s end
    end
    series_title = series_title or book.seriesTitle or (series and (series.name or (series.metadata and series.metadata.title)))
    if not self.plugin.api then
        if on_failure then on_failure("Not configured") end
        return
    end
    local local_path, filename = self:getBookLocalPath(book, series_title)
    if not local_path then
        if on_failure then on_failure("No download directory") end
        return
    end
    local util = require("util")
    local final_dir = local_path:match("(.*)/[^/]+")
    util.makePath(final_dir .. "/")

    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = T(_("Downloading %1..."), filename) }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local tmp_path = local_path .. ".part"

    UIManager:nextTick(function()
        local ok, err = self.plugin.api:download_book(book.id, tmp_path, function(done, total)
            if total and total > 0 and done % 5 == 0 then
                UIManager:close(msg)
                msg = InfoMessage:new{ text = T(_("Downloading %1... page %2/%3"), filename, done, total) }
                UIManager:show(msg)
                UIManager:forceRePaint()
            end
        end)
        UIManager:close(msg)
        if ok then
            self.plugin.settings.matched_books_cache[local_path] = book.id
            self.plugin.settings.downloaded_books = self.plugin.settings.downloaded_books or {}
            self.plugin.settings.downloaded_books[local_path] = os.time()
            self.plugin:saveSettings()
            pcall(Sidecar.saveBookMetadata, local_path, book, series_title, series)
            os.rename(tmp_path, local_path)
            -- Seed the sidecar with the server's progress and bookmarks so the
            -- chapter opens where you left it on another device.
            pcall(function()
                local rp = book.readProgress
                local total = book.media and book.media.pagesCount
                if type(rp) == "table" and ((rp.page or 0) > 0 or rp.completed) then
                    Sidecar.writeLocalProgress(local_path, rp.page, total, rp.completed)
                end
                if self.plugin.bookmarks and self.plugin.settings.sync_bookmarks then
                    local all = self.plugin.bookmarks:fetchServerBookmarks()
                    if all then self.plugin.bookmarks:syncClosedDocument(local_path, book.id, all[book.id] or {}) end
                end
            end)
            self:downloadSeriesCoverIfMissing(book, final_dir, series_title)
            self:enforceDownloadCap(local_path)
            self.plugin:notify(T(_("Saved: %1"), filename), "info")
            if on_success then UIManager:nextTick(function() on_success(local_path) end) end
            UIManager:nextTick(function()
                pcall(function()
                    local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
                    if BookInfoManager and BookInfoManager.deleteBookInfo then BookInfoManager:deleteBookInfo(local_path) end
                end)
                local okfm, FileManager = pcall(require, "apps/filemanager/filemanager")
                if okfm and FileManager.instance then FileManager.instance:onRefresh() end
            end)
        else
            os.remove(tmp_path)
            logger.warn("kouchiyomi: download failed", tostring(err))
            self.plugin:notify(T(_("Download failed: %1"), tostring(err)), "error")
            if on_failure then UIManager:nextTick(function() on_failure(tostring(err)) end) end
        end
    end)
end

function Sync:downloadBooksSeq(books, index, on_done)
    index = index or 1
    if index > #books then
        if on_done then on_done() end
        return
    end
    local book = books[index]
    if books[index + 1] then self:cacheNextChapter(book.id, books[index + 1]) end
    local step = function() self:downloadBooksSeq(books, index + 1, on_done) end
    self:downloadBook(book, book.seriesTitle, step, step)
end

function Sync:downloadSeriesCoverIfMissing(book, final_dir, series_title)
    if not self.plugin.api then return end
    if not (self.plugin.settings.download_to_subfolder and series_title and series_title ~= "") then return end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(final_dir, "mode") ~= "directory" then return end
    for file in lfs.dir(final_dir) do
        if file:match("^%.cover%.") or file == ".cover" then return end
    end
    if not book.seriesId then return end
    local img = self.plugin.api:download_series_thumbnail(book.seriesId)
    if type(img) ~= "string" or #img == 0 then return end
    local ext = "jpg"
    if img:sub(1, 4) == "\137PNG" then ext = "png"
    elseif img:sub(1, 4) == "RIFF" and img:sub(9, 12) == "WEBP" then ext = "webp"
    elseif img:sub(1, 3) == "GIF" then ext = "gif" end
    local f = io.open(final_dir .. "/.cover." .. ext, "wb")
    if f then f:write(img); f:close() end
end

-- ---------------------------------------------------------------------------
-- Next chapter
-- ---------------------------------------------------------------------------

local function next_descriptor(book)
    if type(book) ~= "table" or not book.id then return nil end
    return {
        id = book.id, name = book.name, seriesId = book.seriesId, seriesTitle = book.seriesTitle,
        media = book.media and { pagesCount = book.media.pagesCount } or nil,
        metadata = book.metadata and { title = book.metadata.title, number = book.metadata.number, numberSort = book.metadata.numberSort } or nil,
    }
end

--- Ask the server which chapter follows book_id and remember it, so the
-- answer is known later when Wi-Fi is gone. Returns the book, or nil, err, code.
function Sync:cacheNextChapterFor(book_id)
    if not self.plugin.api or not book_id then return nil end
    local nb, err, code = self.plugin.api:get_next_book(book_id)
    if nb then self:cacheNextChapter(book_id, nb) end
    return nb, err, code
end

function Sync:cacheNextChapter(book_id, next_book)
    local desc = next_descriptor(next_book)
    if not book_id or not desc then return end
    local cache = self.plugin.settings.next_chapter_cache or {}
    cache[tostring(book_id)] = desc
    self.plugin.settings.next_chapter_cache = cache
    self.plugin:saveSettings()
end

--- Called from the end-of-book hook when the reader turns past the last
-- page of a linked chapter. Marks the chapter finished in KOReader, records
-- it as read on Uchiyomi (buffered when that is not possible right now) and
-- offers the next chapter of the series. Returns true when we showed our own
-- dialog, false to let KOReader's end-of-document action run.
function Sync:promptNextChapter(ui, show_native)
    if not ui or not ui.document then return false, "no document" end
    local filepath = ui.document.file
    local book_id = filepath and self:getOrMatchBook(filepath)
    if not book_id then return false, "not linked" end
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local NetworkMgr = require("ui/network/manager")
    local lfs = require("libs/libkoreader-lfs")

    -- 1. Finished: mark it so in KOReader (book status "finished") ...
    self:markOpenDocComplete(ui)
    -- 2. ... and on Uchiyomi. A failed push is buffered like an offline one so
    --    it is retried on the next flush instead of being lost.
    local total = page_count(ui)
    self.plugin.last_pushed_page = total
    local online = NetworkMgr:isOnline() and self.plugin.api ~= nil
    local pushed = false
    if online then
        local ok, err = self.plugin.api:put_progress(book_id, total, true, false)
        if ok then pushed = true else logger.warn("kouchiyomi: completion push failed:", tostring(err)) end
    end
    if not pushed then self:bufferOfflineProgress(book_id, total, total, true) end

    local function open_path(path)
        UIManager:nextTick(function()
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            filemanagerutil.openFile(ui, path)
        end)
    end

    -- Runs once the server is reachable again: record the finished chapter,
    -- ask which chapter is next, download it if needed and open it.
    local function fetch_and_open_next()
        if not self.plugin.api then
            self.plugin:notify(_("Uchiyomi is not configured."), "error")
            return
        end
        self:flushOfflineProgress(false)
        local nb, err2, code2 = self:cacheNextChapterFor(book_id)
        if not nb then
            if code2 == 404 then
                self.plugin:notify(_("This was the last chapter on the server."), "info")
                return
            end
            local cached = self.plugin.settings.next_chapter_cache and self.plugin.settings.next_chapter_cache[tostring(book_id)]
            if not cached then
                self.plugin:notify(T(_("Could not fetch the next chapter: %1"), tostring(err2)), "error")
                return
            end
            nb = cached
        end
        local p = self:getBookLocalPath(nb, nb.seriesTitle)
        if p and lfs.attributes(p, "mode") == "file" then
            open_path(p)
        else
            self:downloadBook(nb, nb.seriesTitle, open_path)
        end
    end

    -- 3. Next chapter without the server. Only the chapter Uchiyomi itself
    --    named as next (cached while online) is ever opened: a later file
    --    that happens to be on the device would skip chapters. Anything else
    --    is reported, with an offer to reconnect and fetch the right one.
    local function offline_dialog(reason)
        local cached = self.plugin.settings.next_chapter_cache and self.plugin.settings.next_chapter_cache[tostring(book_id)]
        local path, title
        if cached then
            title = book_title(cached)
            local p = self:getBookLocalPath(cached, cached.seriesTitle)
            if p and lfs.attributes(p, "mode") == "file" then path = p end
        end
        local text
        if path then
            text = T(_("%1 Next chapter is on this device: %2"), reason, title)
        elseif cached then
            text = T(_("%1 The next chapter (%2) is not on this device."), reason, title)
        else
            text = T(_("%1 Which chapter comes next is not known without the server."), reason)
        end
        local dialog
        local buttons = {}
        if path then
            table.insert(buttons, { { text = _("Open next chapter"), is_enter_default = true,
                callback = function() UIManager:close(dialog); open_path(path) end } })
        else
            table.insert(buttons, { { text = online and _("Try again") or _("Turn on Wi-Fi and fetch it"), is_enter_default = true,
                callback = function() UIManager:close(dialog); NetworkMgr:runWhenOnline(fetch_and_open_next) end } })
        end
        table.insert(buttons, {
            { text = _("Default action"), callback = function() UIManager:close(dialog); if show_native then show_native() end end },
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
        })
        dialog = ButtonDialog:new{ title = text, buttons = buttons }
        UIManager:show(dialog)
    end

    if not online then
        offline_dialog(_("Offline."))
        return true
    end

    local next_book, err, code = self.plugin.api:get_next_book(book_id)
    if not next_book then
        if code == 404 or code == nil then
            self.plugin:notify(_("Chapter marked read. This was the last chapter on the server."), "info")
            return false, "last chapter on the server"
        end
        -- Server unreachable or unhappy: behave as if offline rather than
        -- silently dropping the reader into KOReader's own dialog.
        offline_dialog(T(_("Uchiyomi did not answer (%1)."), tostring(err)))
        return true
    end
    self:cacheNextChapter(book_id, next_book)
    local local_path = self:getBookLocalPath(next_book, next_book.seriesTitle)
    local downloaded = local_path and lfs.attributes(local_path, "mode") == "file"
    local title = book_title(next_book)
    local mode = self.plugin.settings.open_mode or "download"
    local dialog
    local buttons = {}
    if downloaded then
        table.insert(buttons, { { text = _("Open next chapter"), is_enter_default = true,
            callback = function() UIManager:close(dialog); open_path(local_path) end } })
    else
        if mode ~= "stream" then
            table.insert(buttons, { { text = _("Download & open"), is_enter_default = mode == "download",
                callback = function() UIManager:close(dialog); self:downloadBook(next_book, next_book.seriesTitle, open_path) end } })
        end
        if mode ~= "download" or self.plugin.settings.offer_stream then
            table.insert(buttons, { { text = _("Stream next chapter"), is_enter_default = mode == "stream",
                callback = function() UIManager:close(dialog); self.plugin.stream:open(next_book) end } })
        end
    end
    table.insert(buttons, {
        { text = _("Default action"), callback = function() UIManager:close(dialog); if show_native then show_native() end end },
        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
    })
    dialog = ButtonDialog:new{
        title = downloaded and T(_("Chapter marked read.\nNext chapter is ready: %1"), title)
            or T(_("Chapter marked read.\nNext chapter: %1"), title),
        buttons = buttons,
    }
    UIManager:show(dialog)
    return true
end

-- ---------------------------------------------------------------------------
-- Offline library (downloaded chapters, no network)
-- ---------------------------------------------------------------------------

local BOOK_EXTS = { cbz = true, cbr = true, cb7 = true, cbt = true, zip = true, pdf = true, epub = true }

local function is_book_file(name)
    local ext = name:match("%.([%a%d]+)$")
    return ext ~= nil and BOOK_EXTS[ext:lower()] == true
end

function Sync:scanDownloadedFiles(dir, out, depth)
    depth = depth or 0
    if depth > 5 then return end
    local lfs = require("libs/libkoreader-lfs")
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iter then return end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "directory" then
                if not name:match("%.sdr$") then self:scanDownloadedFiles(path, out, depth + 1) end
            elseif mode == "file" and is_book_file(name) then
                table.insert(out, path)
            end
        end
    end
end

--- Local-only info about a downloaded chapter.
function Sync:getOfflineBookInfo(filepath)
    local info = { path = filepath }
    info.book_id = self.plugin.settings.matched_books_cache[filepath] or Sidecar.readBookId(filepath)
    local doc_props, custom_props = {}, {}
    local ds = Sidecar.openDocSettings(filepath, false)
    if ds then
        doc_props = ds:readSetting("doc_props") or {}
        custom_props = ds:readSetting("custom_props") or {}
        info.series_id = ds:readSetting("uchiyomi_series_id")
    end
    if not next(doc_props) and not next(custom_props) then
        local cm = Sidecar.loadCustomMetadata(filepath)
        if cm then
            doc_props = cm.doc_props or doc_props
            custom_props = cm.custom_props or custom_props
            info.series_id = info.series_id or cm.uchiyomi_series_id
        end
    end
    info.series = (custom_props.series ~= "" and custom_props.series) or (doc_props.series ~= "" and doc_props.series) or nil
    info.series_index = tonumber(custom_props.series_index) or tonumber(doc_props.series_index)
    info.title = (custom_props.title ~= "" and custom_props.title) or (doc_props.title ~= "" and doc_props.title)
        or filepath:match("([^/\\]+)$") or filepath
    local prog = Sidecar.readLocalProgress(filepath) or {}
    info.page = prog.page
    info.page_count = prog.page_count
    info.percent = prog.percent
    info.finished = prog.finished or false
    if info.book_id then
        local buffered = self.plugin.settings.offline_progress_buffer and self.plugin.settings.offline_progress_buffer[tostring(info.book_id)]
        if buffered and buffered.completed then info.finished = true end
    end
    info.in_progress = not info.finished and ((info.percent or 0) > 0)
    return info
end

function Sync:getDownloadedBookInfos()
    local lfs = require("libs/libkoreader-lfs")
    local seen, candidates = {}, {}
    local function add(path)
        if path and not seen[path] and lfs.attributes(path, "mode") == "file" then
            seen[path] = true
            table.insert(candidates, path)
        end
    end
    local dir = self.plugin.settings.download_dir
    if not dir or dir == "" then dir = G_reader_settings and G_reader_settings:readSetting("home_dir") end
    if dir and dir ~= "" then
        local files = {}
        self:scanDownloadedFiles(dir, files, 0)
        for _i, p in ipairs(files) do add(p) end
    end
    for path in pairs(self.plugin.settings.downloaded_books or {}) do add(path) end
    local infos = {}
    for _i, path in ipairs(candidates) do
        local info = self:getOfflineBookInfo(path)
        if info.book_id then table.insert(infos, info) end
    end
    return infos
end

function Sync:getOfflineSeriesList()
    local by_key, order = {}, {}
    for _i, info in ipairs(self:getDownloadedBookInfos()) do
        local key = info.series or info.title or info.path
        local grp = by_key[key]
        if not grp then
            grp = { series = info.series, key = key, books = {} }
            by_key[key] = grp
            table.insert(order, grp)
        end
        table.insert(grp.books, info)
    end
    for _i, grp in ipairs(order) do
        table.sort(grp.books, function(a, b)
            local ai, bi = a.series_index or math.huge, b.series_index or math.huge
            if ai == bi then return (a.path or "") < (b.path or "") end
            return ai < bi
        end)
        grp.total, grp.unread = 0, 0
        for _i, b in ipairs(grp.books) do
            grp.total = grp.total + 1
            if not b.finished then grp.unread = grp.unread + 1 end
        end
    end
    table.sort(order, function(a, b) return (a.key or ""):lower() < (b.key or ""):lower() end)
    return order
end

return Sync
