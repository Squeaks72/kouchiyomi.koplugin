--[[
    One entry per series in KOReader's history.

    A manga is a folder of chapters, and every chapter read is a book as far as
    KOReader's history is concerned. SimpleUI's home screen (Currently reading,
    Recent books, Cover deck) is nothing but a walk down `ReadHistory.hist`, so a
    handful of chapters of one series fills every slot on it. There is no
    "series" notion in there to switch on, so the history itself is what gets
    tidied: of the chapters in one series folder only the most recently read one
    keeps its entry, which is also the chapter "Continue" should open.

    Only the history list is touched. The chapter files, their sidecars (reading
    position, bookmarks) and the plugin's own records are left alone, so nothing
    is lost -- the chapter just stops being listed. It is deliberately not
    `ReadHistory:removeItemByPath`, which also deletes the history-dir copy of
    the sidecar (the reading position, when KOReader keeps sidecars there).
--]]

local History = {}

local function parent(path)
    return path:match("^(.*)/[^/]*$") or ""
end

--- Indices into `hist` (newest first, KOReader's order) that should go: for each
-- folder holding chapters of ours, every entry but the first.
-- @param hist  array of { file = path }
-- @param is_ours  function(path) -> bool; false leaves the entry untouched
function History.redundant(hist, is_ours)
    local seen, drop = {}, {}
    for i, entry in ipairs(hist or {}) do
        local file = entry and entry.file
        if type(file) == "string" and is_ours(file) then
            local dir = parent(file)
            if seen[dir] then drop[#drop + 1] = i else seen[dir] = true end
        end
    end
    return drop
end

--- Apply it to KOReader's history. Returns how many entries were dropped.
function History.collapse(plugin)
    if plugin.settings.one_history_entry_per_series == false then return 0 end
    local downloaded = plugin.settings.downloaded_books
    if type(downloaded) ~= "table" then return 0 end
    local ReadHistory = require("readhistory")
    local hist = ReadHistory.hist
    if not hist or #hist == 0 then return 0 end
    local drop = History.redundant(hist, function(path) return downloaded[path] ~= nil end)
    if #drop == 0 then return 0 end
    for n = #drop, 1, -1 do table.remove(hist, drop[n]) end
    ReadHistory:_flush()
    return #drop
end

return History
