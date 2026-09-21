-- End-to-end test of the bookmark three-way merge (uchi/bookmarks.lua) against
-- a live Uchiyomi, with KOReader's UI modules stubbed.
require("setupkoenv")
local plugin_dir = os.getenv("KOUCHIYOMI_DIR")
package.path = plugin_dir .. "/?.lua;" .. package.path

-- ---- stubs for KOReader UI modules -------------------------------------
local online = true
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end, nextTick = function(_, f) f() end,
             scheduleIn = function(_, _, f) f() end, unschedule = function() end, setDirty = function() end,
             broadcastEvent = function() end, forceRePaint = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return online end, runWhenOnline = function(_, f) f() end,
             willRerunWhenOnline = function() return true end, afterWifiAction = function() end }
end
package.preload["ui/event"] = function() return { new = function(_, name, ...) return { name = name, args = { ... } } end } end
package.preload["ui/widget/infomessage"] = function() return { new = function() return {} end } end
-- in-memory DocSettings
local stores = {}
package.preload["docsettings"] = function()
    local DS = {}
    function DS:hasSidecarFile(file) return stores[file] ~= nil end
    function DS:open(file)
        stores[file] = stores[file] or {}
        local st = stores[file]
        return { readSetting = function(_, k) return st[k] end, saveSetting = function(_, k, v) st[k] = v end,
                 flush = function() end, purge = function() stores[file] = nil end }
    end
    return DS
end

local API = require("uchi/api")
local Sync = require("uchi/sync")
local Bookmarks = require("uchi/bookmarks")
local Sidecar = require("uchi/sidecar")

local api = API:new(assert(os.getenv("UCHI_URL")), { api_token = assert(os.getenv("UCHI_TOKEN")) })
local plugin = { settings = { matched_books_cache = {}, sync_bookmarks = true, sync_progress = true, offline_bookmark_ops = {}, bookmark_snapshots = {}, offline_progress_buffer = {} },
                 api = api, i18n = require("uchi/i18n"), notify = function(_, m) print("  notify:", m) end, saveSettings = function() end }
plugin.sync = Sync:new(plugin)
plugin.bookmarks = Bookmarks:new(plugin)

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, extra or "") end
end
local function keys(set) local l = {} for k in pairs(set) do l[#l+1] = k end table.sort(l) return table.concat(l, ",") end

-- pick the LAST chapter of the first search hit so we never touch an in-progress chapter
local series = api:search_series("blame", 0, 1).content[1]
local all = api:get_all_series_books(series.id)
local book = all[#all]
local BOOK, FILE = book.id, "/fake/BLAME/last.cbz"
plugin.settings.matched_books_cache[FILE] = BOOK

local function server_set()
    local s = {}
    for _, bm in ipairs(api:get_bookmarks().content) do if bm.book_id == BOOK then s[bm.page] = true end end
    return s
end
for page in pairs(server_set()) do api:remove_bookmark(BOOK, page) end

-- fake open reader UI ----------------------------------------------------
local ui = { paging = true, document = { file = FILE }, dialog = {} }
ui.annotation = { annotations = {} }
function ui.annotation:addItem(item)
    item.datetime = item.datetime or "now"
    local idx = #self.annotations + 1
    for i, a in ipairs(self.annotations) do if a.page > item.page then idx = i break end end
    table.insert(self.annotations, idx, item)
    return idx
end
ui.bookmark = {}
function ui.bookmark:getDogearBookmarkIndex(page)
    for i, a in ipairs(ui.annotation.annotations) do if not a.drawer and a.page == page then return i end end
end
function ui.bookmark:isPageBookmarked(page) return self:getDogearBookmarkIndex(page) ~= nil end
function ui.bookmark:removeItemByIndex(i) table.remove(ui.annotation.annotations, i) end
function ui.bookmark:setDogearVisibility() end
function ui.bookmark:getCurrentPageNumber() return 1 end
ui.handleEvent = function(_, ev) plugin.bookmarks:onAnnotationsModified(ui, ev.args[1]) end -- KOReader dispatch
local function local_set() return plugin.bookmarks:localPagesFromOpenDoc(ui) end

-- (b) first sync: union, nothing deleted
ui.annotation:addItem({ page = 5 }); ui.annotation:addItem({ page = 9 })
api:add_bookmark(BOOK, 9); api:add_bookmark(BOOK, 20)
plugin.bookmarks:syncOpenDocument(ui, false)
check("first sync unions local", keys(local_set()) == "5,9,20", keys(local_set()))
check("first sync unions server", keys(server_set()) == "5,9,20", keys(server_set()))

-- (c) user removes 5 in KOReader -> server loses 5
local idx = ui.bookmark:getDogearBookmarkIndex(5)
local item = table.remove(ui.annotation.annotations, idx)
ui:handleEvent({ name = "AnnotationsModified", args = { { item, index_modified = -idx } } })
check("local delete propagates", keys(server_set()) == "9,20", keys(server_set()))

-- (d) server removes 20 and adds 30 -> local follows
api:remove_bookmark(BOOK, 20); api:add_bookmark(BOOK, 30)
plugin.bookmarks:syncOpenDocument(ui, false)
check("server delete propagates", not local_set()[20])
check("server add propagates", local_set()[30] == true)
check("state converged", keys(local_set()) == keys(server_set()) and keys(local_set()) == "9,30", keys(local_set()) .. " | " .. keys(server_set()))

-- (e) offline add is queued, then flushed
online = false
local i12 = ui.annotation:addItem({ page = 12 })
ui:handleEvent({ name = "AnnotationsModified", args = { { ui.annotation.annotations[i12], index_modified = i12 } } })
check("offline add queued", plugin.bookmarks:countOffline() == 1)
check("offline add not on server yet", not server_set()[12])
online = true
plugin.bookmarks:flushOffline()
check("flush pushes queued add", server_set()[12] == true and plugin.bookmarks:countOffline() == 0)

-- (f) closed document: sidecar with only page 40; snapshot says 9,12,30 agreed
local FILE2 = "/fake/BLAME/last_copy.cbz"
local ds = require("docsettings"):open(FILE2)
ds:saveSetting("annotations", { { page = 40, datetime = "x" }, { page = 41, drawer = "lighten", datetime = "x" } })
local changed = plugin.bookmarks:syncClosedDocument(FILE2, BOOK, server_set())
local local2 = Sidecar.readLocalBookmarks(FILE2)
check("closed doc: local-only page pushed", server_set()[40] == true)
check("closed doc: snapshot deletions applied to server", keys(server_set()) == "40", keys(server_set()))
check("closed doc: sidecar kept highlight, has 40", local2[40] and #ds:readSetting("annotations") == 2, tostring(#ds:readSetting("annotations")))
check("closed doc: externally_modified flag", ds:readSetting("annotations_externally_modified") == nil or changed)

-- (g) closed doc receives a server-side add
api:add_bookmark(BOOK, 44)
plugin.bookmarks:syncClosedDocument(FILE2, BOOK, server_set())
local ann = ds:readSetting("annotations")
local has44 = false
for _, a in ipairs(ann) do if a.page == 44 and not a.drawer then has44 = true end end
check("closed doc: server add written to sidecar", has44 and ds:readSetting("annotations_externally_modified") == true)

-- cleanup
for page in pairs(server_set()) do api:remove_bookmark(BOOK, page) end
check("cleanup", next(server_set()) == nil)
print(string.format("== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
