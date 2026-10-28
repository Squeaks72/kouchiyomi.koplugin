--[[ Download file names and the "already downloaded" check with a series-led title. Plain Lua 5.1, stubs KOReader: lua5.1 tests/series_prefix_paths.lua (from the plugin folder). --]]
package.path = "./?.lua;" .. package.path
local real = { ["uchi/labels"] = true }
local dummy = setmetatable({}, { __index = function() return function() end end, __call = function() return {} end })
table.insert(package.searchers or package.loaders, 2, function(name)
    if real[name] then return nil end
    if name:match("^uchi/") and name ~= "uchi/sync" then return function() return dummy end end
    if name ~= "uchi/sync" then
        if name == "libs/libkoreader-lfs" then return function() return LFS end end
        return function() return dummy end
    end
end)
local made = {}
LFS = { attributes = function(path, mode) return made[path] and "file" or nil end }
local Sync = require("uchi/sync")
local plugin = { settings = { download_to_subfolder = true }, getDownloadDir = function() return "/dl" end }
local s = setmetatable({ plugin = plugin }, { __index = Sync })
local book = { metadata = { title = "Blue Box - Chapter 211", number = 211 }, seriesTitle = "Blue Box" }
local p, name = s:getBookLocalPath(book)
assert(p == "/dl/Blue Box/Chapter 211.cbz" and name == "Chapter 211.cbz", p)
made["/dl/Blue Box/Blue Box - Chapter 211.cbz"] = true
p, name = s:getBookLocalPath(book)
assert(p == "/dl/Blue Box/Blue Box - Chapter 211.cbz", "an existing full-name download is found: " .. tostring(p))
made["/dl/Blue Box/Chapter 211.cbz"] = true
p = s:getBookLocalPath(book)
assert(p == "/dl/Blue Box/Chapter 211.cbz", "the short name wins when it exists")
assert(Sync.book_title(book) == "Chapter 211")
print("sync path checks passed")
