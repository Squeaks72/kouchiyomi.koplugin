--[[
    The series catch-up prompt and what it leaves to the page-level pull. Plain Lua 5.1, stubs KOReader:
      lua5.1 tests/series_catchup.lua     (from the plugin folder)

    What it is guarding: being several chapters behind Uchiyomi offering the last page of the open chapter.
--]]
package.path = "./?.lua;" .. package.path
local real = { ["uchi/labels"] = true, ["uchi/sync"] = true, ["uchi/api"] = true }
local shown, opened = {}, {}
local UIManager = {
    show = function(_self, w) table.insert(shown, w) end,
    isWidgetShown = function(_self, w) for _i, s in ipairs(shown) do if s == w then return true end end return false end,
    nextTick = function(_self, fn) fn() end,
}
local stubs = {
    ["ui/uimanager"] = UIManager,
    ["ui/network/manager"] = { isOnline = function() return true end },
    ["ui/widget/confirmbox"] = { new = function(_self, o) return o end },
    ["libs/libkoreader-lfs"] = { attributes = function() return "file" end },
    ["apps/filemanager/filemanagerutil"] = { openFile = function(_ui, path) table.insert(opened, path) end },
}
local dummy = setmetatable({}, { __index = function() return function() end end, __call = function() return {} end })
table.insert(package.loaders, 2, function(name)
    if real[name] then return nil end
    local stub = stubs[name] or dummy
    return function() return stub end
end)
local Sync = require("uchi/sync")

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end

local function chapter(n, progress)
    return { id = "b" .. n, seriesId = "s1", seriesTitle = "Stub", name = "Chapter " .. n,
             metadata = { title = "Chapter " .. n, number = tostring(n), numberSort = n },
             media = { pagesCount = 20 }, readProgress = progress }
end

--- A fresh device with chapter `open_n` open and the server at `target`.
local function device(open_n, target, source, settings)
    shown = {}
    local pulled = 0
    local s = setmetatable({}, { __index = Sync })
    s.plugin = {
        settings = settings or { sync_progress = true, sync_series_catchup = "prompt" },
        i18n = { _ = function(t) return t end, T = function(t, a, b, c)
            return (t:gsub("%%1", tostring(a)):gsub("%%2", tostring(b)):gsub("%%3", tostring(c))) end },
        notify = function() end,
        api = {
            get_book = function(_a, id) return chapter(tonumber(id:sub(2)), { page = 20, completed = true }) end,
            get_read_progress = function(_a, id)
                local b = chapter(tonumber(id:sub(2)), { page = 20, completed = true })
                return b.readProgress, nil, b
            end,
            get_series_position = function(_a, _sid, current)
                s.asked_with = current
                return target, source
            end,
        },
    }
    s.getOrMatchBook = function() return "b" .. open_n end
    s.getBookLocalPath = function(_s, b) return "/dl/" .. b.id .. ".cbz" end
    s.isDownloading = function() return false end
    s.pullProgress = function() pulled = pulled + 1 end
    local ui = { document = { file = "/dl/b" .. open_n .. ".cbz" } }
    return s, ui, function() return pulled end
end

Sync.catchup_declined = {}

-- 1. The report: several chapters behind, the prompt names the far chapter and the end-of-chapter pull never runs.
local s, ui, pulled = device(230, chapter(235, { page = 8, completed = false }), "furthest")
s:syncOnOpen(ui)
check("one prompt", #shown == 1, #shown)
check("it names the chapter reached", shown[1] and shown[1].text:find("Ch. 235, page 8 of 20", 1, true), shown[1] and shown[1].text)
check("the page-level pull is not reached", pulled() == 0, pulled())
check("the open chapter limits the search", s.asked_with and s.asked_with.id == "b230")

-- 2. Going there opens that chapter at that page.
Sync.pending_goto_page = nil
opened = {}
shown[1].ok_callback()
check("opens the chapter", opened[1] == "/dl/b235.cbz", opened[1])
check("at the page", Sync.pending_goto_page == 8, Sync.pending_goto_page)
Sync.pending_goto_page = nil

-- 3. Asked again while that dialog is still up (Wi-Fi came up after the chapter opened): no second dialog.
s:syncOnOpen(ui)
check("no second dialog on top of the first", #shown == 1, #shown)
check("nor the pull behind it", pulled() == 0, pulled())

-- 4. Stay here holds: not asked again, from this chapter or the next, and no end-of-chapter prompt instead.
shown[1].cancel_callback()
s, ui, pulled = device(230, chapter(235, { page = 8, completed = false }), "furthest")
s:syncOnOpen(ui)
check("not asked again", #shown == 0, #shown)
check("no end-of-chapter prompt in its place", pulled() == 0, pulled())
s, ui, pulled = device(231, chapter(235, { page = 8, completed = false }), "furthest")
s:syncOnOpen(ui)
check("nor from the next chapter", #shown == 0 and pulled() == 0, #shown)

-- 5. A new position asks again.
s, ui, pulled = device(231, chapter(236, { page = 2, completed = false }), "furthest")
s:syncOnOpen(ui)
check("a new position asks", #shown == 1 and shown[1].text:find("Ch. 236", 1, true), shown[1] and shown[1].text)
Sync.catchup_declined = {}

-- 6. The end of the series: the last chapter, at its last page.
s, ui, pulled = device(230, chapter(251, { page = 3, completed = true }), "series finished")
s:syncOnOpen(ui)
check("the finished last chapter is offered at its end", shown[1] and shown[1].text:find("Ch. 251, page 20 of 20", 1, true), shown[1] and shown[1].text)
check("and the pull stays out of it", pulled() == 0, pulled())

-- 7. The chapter that is open IS the position: its page is pullProgress's job.
s, ui, pulled = device(235, chapter(235, { page = 8, completed = false }), "furthest")
s:syncOnOpen(ui)
check("same chapter falls to the pull", #shown == 0 and pulled() == 1, pulled())

-- 8. Nothing ahead: also the pull's.
s, ui, pulled = device(235, nil, "nothing ahead")
s:syncOnOpen(ui)
check("nothing ahead falls to the pull", #shown == 0 and pulled() == 1, pulled())

-- 9. Asked by hand there is no floor, so an earlier position can be named.
s, ui = device(230, chapter(100, { page = 2, completed = false }), "furthest")
s:promptSeriesCatchUp(ui, true)
check("a manual ask searches the whole series", s.asked_with == nil, s.asked_with and s.asked_with.id)
check("and does not jump backwards", #shown == 0, #shown)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
