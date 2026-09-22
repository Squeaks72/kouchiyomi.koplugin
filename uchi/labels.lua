--[[
    Chapter labels, mirroring Uchiyomi's web app (web/lib/format.ts):
    "Ch. 944" for chapters, "Vol. 3" for volume-style archives, and the
    raw name when there is no number. Used everywhere a chapter is named
    (lists, dialogs, notifications) so the plugin reads like the same app.
--]]

local Labels = {}

local CHAPTER_MARKS = { "%f[%a]ch%.?%s*%d", "%f[%a]chap%.?%s*%d", "%f[%a]chapter%.?%s*%d", "%f[%a]chapitre%.?%s*%d", "%f[%a]episode%.?%s*%d", "%f[%a]ep%.?%s*%d" }
local VOLUME_MARKS = { "%f[%a]tome%.?%s*%d", "%f[%a]volume%.?%s*%d", "%f[%a]vol%.?%s*%d", "%f[%a][tv]%.?%d", "%f[%a][tv]%.?%s%d" }

local function any(s, patterns)
    for _i, p in ipairs(patterns) do
        if s:find(p) then return true end
    end
    return false
end

--- "Tome 01", "Berserk T41", "v01" are volumes; a chapter marker wins.
function Labels.isVolumeName(name)
    if not name or name == "" then return false end
    local s = tostring(name):lower()
    return not any(s, CHAPTER_MARKS) and any(s, VOLUME_MARKS)
end

local function number_of(book)
    local n = book.metadata and book.metadata.number
    if n == nil or n == "" then n = book.number end
    if n == nil or n == "" then return nil end
    n = tostring(n)
    -- "944.0" -> "944"
    n = n:gsub("%.0+$", "")
    return n
end

function Labels.rawTitle(book)
    return (book.metadata and book.metadata.title ~= "" and book.metadata.title) or book.name or "?"
end

--- "Ch. 944" / "Vol. 3", or the name when there is no number.
function Labels.chapter(book)
    if type(book) ~= "table" then return "?" end
    local n = number_of(book)
    if not n then return Labels.rawTitle(book) end
    local name = book.name or (book.metadata and book.metadata.title)
    return (Labels.isVolumeName(name) and "Vol. " or "Ch. ") .. n
end

--- What the chapter's title says beyond its number ("Ch. 5: The Storm" ->
-- "The Storm"), or nil when the title is just a restatement of the number.
function Labels.subtitle(book, series_title)
    if type(book) ~= "table" then return nil end
    local title = Labels.rawTitle(book)
    local n = number_of(book)
    if not n then return nil end
    local rest = title:match("^%s*[Cc]h%a*%.?%s*[%d%.]+%s*[:%-–—]*%s*(.*)$")
        or title:match("^%s*[Vv]ol%a*%.?%s*[%d%.]+%s*[:%-–—]*%s*(.*)$")
        or title:match("^%s*[Ee]p%a*%.?%s*[%d%.]+%s*[:%-–—]*%s*(.*)$")
    if rest then
        rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
        return rest ~= "" and rest or nil
    end
    -- "One Piece 944", "944" and friends carry nothing beyond the number.
    local stripped = title
    if series_title and series_title ~= "" then
        local st = series_title:gsub("%p", "%%%0")
        stripped = stripped:gsub("^%s*" .. st, "")
    end
    local num = n:gsub("%p", "%%%0")
    stripped = stripped:gsub(num, ""):gsub("[%s%p]+", "")
    if stripped == "" then return nil end
    return title
end

--- "One Piece · Ch. 944" when with_series, else "Ch. 944".
function Labels.display(book, with_series, series_title)
    local label = Labels.chapter(book)
    local st = series_title or (type(book) == "table" and book.seriesTitle)
    if with_series and st and st ~= "" then return st .. " · " .. label end
    return label
end

return Labels
