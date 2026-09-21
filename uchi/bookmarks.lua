--[[
    Two-way page-bookmark sync between KOReader and Uchiyomi.

    Uchiyomi keeps page bookmarks per chapter (book id + page). KOReader keeps
    "dogear" bookmarks as annotation items without a highlight (`drawer`).
    For paged documents (CBZ) an annotation's `page` is the page number, so
    the mapping is one-to-one.

    Reconciliation is a three-way merge against the last agreed state per
    chapter (settings.bookmark_snapshots[book_id]):
      * on KOReader only, not in snapshot  -> added here      -> PUT to server
      * in snapshot, gone from KOReader    -> removed here    -> DELETE on server
      * on server only, not in snapshot    -> added on server -> add locally
      * in snapshot, gone from server      -> removed there   -> remove locally
    The first sync of a chapter has no snapshot, so it unions both sides and
    never deletes anything.

    Notes attached to bookmarks are not synced (Uchiyomi's API has no write
    path for them).
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Sidecar = require("uchi/sidecar")

local Bookmarks = {}

function Bookmarks:new(plugin)
    local o = { plugin = plugin, _guard = false }
    return setmetatable(o, { __index = self })
end

local function is_paging(ui)
    return ui and ui.paging ~= nil
end

local function set_from_list(list)
    local s = {}
    for _i, p in ipairs(list or {}) do s[p] = true end
    return s
end

local function list_from_set(set)
    local l = {}
    for p in pairs(set or {}) do table.insert(l, p) end
    table.sort(l)
    return l
end

-- ---------------------------------------------------------------------------
-- Snapshots & offline ops
-- ---------------------------------------------------------------------------

function Bookmarks:_snapshot(book_id)
    local snaps = self.plugin.settings.bookmark_snapshots or {}
    return set_from_list(snaps[tostring(book_id)]), snaps[tostring(book_id)] ~= nil
end

function Bookmarks:_saveSnapshot(book_id, set)
    self.plugin.settings.bookmark_snapshots = self.plugin.settings.bookmark_snapshots or {}
    self.plugin.settings.bookmark_snapshots[tostring(book_id)] = list_from_set(set)
    self.plugin:saveSettings()
end

function Bookmarks:_queueOp(book_id, page, op)
    self.plugin.settings.offline_bookmark_ops = self.plugin.settings.offline_bookmark_ops or {}
    local ops = self.plugin.settings.offline_bookmark_ops
    ops[tostring(book_id)] = ops[tostring(book_id)] or {}
    ops[tostring(book_id)][tostring(page)] = op
    self.plugin:saveSettings()
end

function Bookmarks:countOffline()
    local n = 0
    for _i, ops in pairs(self.plugin.settings.offline_bookmark_ops or {}) do
        for _i in pairs(ops) do n = n + 1 end
    end
    return n
end

--- Push queued add/delete operations recorded while offline.
function Bookmarks:flushOffline()
    local ops = self.plugin.settings.offline_bookmark_ops
    if not ops or not next(ops) or not self.plugin.api then return end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then return end
    for book_id, pages in pairs(ops) do
        for page, op in pairs(pages) do
            local ok
            if op == "add" then
                ok = self.plugin.api:add_bookmark(book_id, tonumber(page))
            else
                ok = self.plugin.api:remove_bookmark(book_id, tonumber(page))
            end
            if ok then
                pages[page] = nil
                local snap = self:_snapshot(book_id)
                if op == "add" then snap[tonumber(page)] = true else snap[tonumber(page)] = nil end
                self:_saveSnapshot(book_id, snap)
            end
        end
        if not next(pages) then ops[book_id] = nil end
    end
    self.plugin:saveSettings()
end

-- ---------------------------------------------------------------------------
-- Server side
-- ---------------------------------------------------------------------------

--- All server bookmarks grouped by book id: { [book_id] = { [page] = true } }, or nil.
function Bookmarks:fetchServerBookmarks()
    if not self.plugin.api then return nil end
    local res, err = self.plugin.api:get_bookmarks()
    if type(res) ~= "table" then
        logger.warn("kouchiyomi: could not fetch bookmarks:", tostring(err))
        return nil
    end
    local out = {}
    for _i, bm in ipairs(res.content or res) do
        local bid = bm.book_id or bm.bookId
        local page = tonumber(bm.page)
        if bid and page then
            out[bid] = out[bid] or {}
            out[bid][page] = true
        end
    end
    return out
end

function Bookmarks:_serverOp(book_id, page, op)
    local NetworkMgr = require("ui/network/manager")
    if not self.plugin.api or not NetworkMgr:isOnline() then
        self:_queueOp(book_id, page, op)
        return false
    end
    local ok
    if op == "add" then ok = self.plugin.api:add_bookmark(book_id, page)
    else ok = self.plugin.api:remove_bookmark(book_id, page) end
    if not ok then self:_queueOp(book_id, page, op) end
    return ok and true or false
end

-- ---------------------------------------------------------------------------
-- Local side: open document
-- ---------------------------------------------------------------------------

function Bookmarks:localPagesFromOpenDoc(ui)
    local set = {}
    if not ui or not ui.annotation or not ui.annotation.annotations then return set end
    for _i, item in ipairs(ui.annotation.annotations) do
        if not item.drawer and type(item.page) == "number" then
            set[item.page] = true
        end
    end
    return set
end

function Bookmarks:_addLocalOpen(ui, page)
    if not ui.annotation or not ui.bookmark then return end
    if ui.bookmark:isPageBookmarked(page) then return end
    self._guard = true
    pcall(function()
        local Event = require("ui/event")
        local item = { page = page }
        local index = ui.annotation:addItem(item)
        ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index }))
    end)
    self._guard = false
end

function Bookmarks:_removeLocalOpen(ui, page)
    if not ui.annotation or not ui.bookmark then return end
    self._guard = true
    pcall(function()
        local index = ui.bookmark:getDogearBookmarkIndex(page)
        if index then ui.bookmark:removeItemByIndex(index) end
    end)
    self._guard = false
end

function Bookmarks:_refreshDogear(ui)
    pcall(function()
        if ui.bookmark and ui.bookmark.setDogearVisibility then
            ui.bookmark:setDogearVisibility(ui.bookmark:getCurrentPageNumber())
        end
        if ui.view and ui.view.footer and ui.view.footer.maybeUpdateFooter then
            ui.view.footer:maybeUpdateFooter()
        end
        UIManager:setDirty(ui.dialog or ui.view and ui.view.dialog, "ui")
    end)
end

--- Reconcile the open document's bookmarks with the server (three-way).
function Bookmarks:syncOpenDocument(ui, is_manual)
    if not self.plugin.settings.sync_bookmarks then return false end
    if not self.plugin.api or not ui or not ui.document or not is_paging(ui) then return false end
    local filepath = ui.document.file
    local book_id = filepath and self.plugin.sync:getOrMatchBook(filepath)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not book_id then
        if is_manual then self.plugin:notify(_("This book is not linked to Uchiyomi."), "error") end
        return false
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then self.plugin:notify(_("Offline: bookmarks will sync when reconnected."), "info") end
        return false
    end
    self:flushOffline()
    local all = self:fetchServerBookmarks()
    if not all then return false end
    local S = all[book_id] or {}
    local L = self:localPagesFromOpenDoc(ui)
    local P = self:_snapshot(book_id)
    local added_local, removed_local, added_remote, removed_remote = 0, 0, 0, 0
    for page in pairs(L) do
        if not S[page] then
            if P[page] then
                self:_removeLocalOpen(ui, page); removed_local = removed_local + 1
            else
                if self:_serverOp(book_id, page, "add") then added_remote = added_remote + 1 end
            end
        end
    end
    for page in pairs(S) do
        if not L[page] then
            if P[page] then
                if self:_serverOp(book_id, page, "del") then removed_remote = removed_remote + 1 end
            else
                self:_addLocalOpen(ui, page); added_local = added_local + 1
            end
        end
    end
    self:_saveSnapshot(book_id, self:localPagesFromOpenDoc(ui))
    if added_local + removed_local > 0 then self:_refreshDogear(ui) end
    if is_manual then
        self.plugin:notify(T(_("Bookmarks synced: +%1/-%2 here, +%3/-%4 on Uchiyomi"), added_local, removed_local, added_remote, removed_remote), "info")
    end
    return true
end

--- Event from ReaderBookmark/ReaderHighlight when the user changes annotations.
function Bookmarks:onAnnotationsModified(ui, items)
    if self._guard then return end
    if not self.plugin.settings.sync_bookmarks then return end
    if not ui or not ui.document or not is_paging(ui) then return end
    if type(items) ~= "table" or type(items[1]) ~= "table" then return end
    local item = items[1]
    if item.drawer then return end                  -- highlights are not page bookmarks
    if type(item.page) ~= "number" then return end
    local idx = items.index_modified
    if idx == nil then return end                    -- note edit only
    local book_id = self.plugin.current_book_id or self.plugin.sync:getOrMatchBook(ui.document.file)
    if not book_id then return end
    local op = idx > 0 and "add" or "del"
    self:_serverOp(book_id, item.page, op)
    local snap = self:_snapshot(book_id)
    if op == "add" then snap[item.page] = true else snap[item.page] = nil end
    self:_saveSnapshot(book_id, snap)
end

-- ---------------------------------------------------------------------------
-- Local side: closed document (sidecar edit)
-- ---------------------------------------------------------------------------

--- Three-way merge for a downloaded chapter that is not open. Returns true if
-- the sidecar changed.
function Bookmarks:syncClosedDocument(filepath, book_id, server_set)
    local L = Sidecar.readLocalBookmarks(filepath) or {}
    local P = self:_snapshot(book_id)
    local to_add_local, to_del_local = {}, {}
    for page in pairs(L) do
        if not server_set[page] then
            if P[page] then table.insert(to_del_local, page)
            else self:_serverOp(book_id, page, "add") end
        end
    end
    for page in pairs(server_set) do
        if not L[page] then
            if P[page] then self:_serverOp(book_id, page, "del")
            else table.insert(to_add_local, page) end
        end
    end
    local changed = false
    if #to_add_local + #to_del_local > 0 then
        local ds = Sidecar.openDocSettings(filepath, true)
        if ds then
            local ann = ds:readSetting("annotations") or {}
            local del = set_from_list(to_del_local)
            local kept = {}
            for _i, item in ipairs(ann) do
                if not (type(item) == "table" and not item.drawer and del[item.page]) then table.insert(kept, item) end
            end
            for _i, page in ipairs(to_add_local) do
                table.insert(kept, { page = page, datetime = os.date("%Y-%m-%d %H:%M:%S") })
            end
            table.sort(kept, function(a, b)
                local ap = type(a.page) == "number" and a.page or 0
                local bp = type(b.page) == "number" and b.page or 0
                if ap == bp then return (a.drawer == nil) and (b.drawer ~= nil) end
                return ap < bp
            end)
            ds:saveSetting("annotations", kept)
            ds:saveSetting("annotations_externally_modified", true)
            if ds.flush then ds:flush() end
            changed = true
        end
    end
    local final = Sidecar.readLocalBookmarks(filepath) or {}
    self:_saveSnapshot(book_id, final)
    return changed
end

return Bookmarks
