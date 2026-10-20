local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
-- The browser is a KOReader widget; its catalogue-scoping methods need none of that, so the UI modules are stubs.
local stub = setmetatable({}, { __index = function() return function() end end })
local function cls()
    local c = { _recalculateDimen = function() end, updateItems = function() end }
    c.extend = function() return cls() end
    return setmetatable(c, { __index = function() return function() end end })
end
for _, m in ipairs({ "ui/widget/menu", "uchi/list_menu", "uchi/grid_menu" }) do package.loaded[m] = cls() end
for _, m in ipairs({ "ui/uimanager", "logger", "uchi/labels" }) do package.loaded[m] = stub end
local B = require("uchi/browser")

local pass, fail = 0, 0
local function check(name, cond) if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name) end end
local calls = {}
local function s(id, t, lib) return { id = id, libraryId = lib, metadata = { title = t } } end
local api = {
  get_favorites = function(_, rev) calls[#calls+1] = "fav"; return { content = { s("1","Zed","m"), s("2","Abe","w"), s("3","Mia","m") } } end,
  get_collection = function(_, id) calls[#calls+1] = "col:" .. id; return { items = { s("9","Only","m") } } end,
  search_series = function() calls[#calls+1] = "server"; return { content = {} } end,
}
local self = setmetatable({ plugin = { settings = { browse_scope = "favorites", browse_scope_name = "Favourites" }, api = api } }, { __index = B })
local r = self:_scoped(api.search_series, { sort = "title,asc" })(0, 2)
check("all series: first page of the list, by title", r.content[1].metadata.title == "Abe" and r.content[2].metadata.title == "Mia" and r.totalElements == 3 and r.last == false)
r = self:_scoped(api.search_series, { library_id = "m", sort = "title,asc" })(0, 40)
check("a library shows only its series of the list", #r.content == 2 and r.content[1].metadata.title == "Mia")
r = self:_scoped(api.search_series, { query = "ab" })(0, 40)
check("search matches inside the list", #r.content == 1 and r.content[1].metadata.title == "Abe")
check("the list is fetched once, the server never asked", table.concat(calls, ",") == "fav")
check("title names the list", self:_scopedTitle("All series") == "All series (Favourites)")
self.plugin._scope_off = true
check("switched off: the plain fetch and title", self:_scoped(api.search_series, {}) == api.search_series and self:_scopedTitle("All series") == "All series")
self.plugin._scope_off = nil; self.plugin.settings.browse_scope = "abc"; self.plugin._scope_cache = nil
r = self:_scoped(api.search_series, {})(0, 40)
check("another list is read by its id", r.content[1].metadata.title == "Only" and calls[#calls] == "col:abc")
self.plugin.settings.browse_scope = nil
check("no scope: untouched", self:_scoped(api.search_series, {}) == api.search_series)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
