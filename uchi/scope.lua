--[[
    Browse only the series of one list.

    The browser's catalogue views (All series, Recently updated, a library, search) ask the server for pages of
    every series it holds. With a "browse scope" set to a list -- the built-in Favourites, or any of the user's
    own lists -- they show only that list's series instead. The server has no "in this list" predicate on its
    series search, so the list is fetched once (a list is one request, never paged) and these views are cut from
    it here: filtered by library or search text, ordered, and served a page at a time in the same shape the
    server's own pages have.
--]]

local Scope = {}

Scope.FAVORITES = "favorites"

local function name_of(s)
    return (s.metadata and s.metadata.title) or s.name or ""
end

--- The newest date a series carries: its latest chapter, else when it entered the library.
local function updated_of(s)
    return s.latestChapterAt or s.created or ""
end

--- Keep the series that match. `opts.library_id` and `opts.query` (a case-insensitive substring of the title).
function Scope.filter(items, opts)
    opts = opts or {}
    local want = opts.query and opts.query ~= "" and opts.query:lower() or nil
    local out = {}
    for _i, s in ipairs(items or {}) do
        local keep = true
        if opts.library_id and tostring(s.libraryId) ~= tostring(opts.library_id) then keep = false end
        if keep and want and not name_of(s):lower():find(want, 1, true) then keep = false end
        if keep then out[#out + 1] = s end
    end
    return out
end

--- Order like the server's `sort` parameter ("title,asc" | "updated,desc"); anything else leaves the list's own order.
function Scope.sort(items, sort)
    local field, dir = tostring(sort or ""):match("^(%a+),?(%a*)$")
    local copy = {}
    for i, s in ipairs(items or {}) do copy[i] = s end
    local key
    if field == "title" or field == "name" then
        key = function(s) return name_of(s):lower() end
    elseif field == "updated" then
        key = updated_of
    else
        return copy
    end
    local desc = dir == "desc"
    -- Position breaks ties so the order is stable, which table.sort is not.
    local pos = {}
    for i, s in ipairs(copy) do pos[s] = i end
    table.sort(copy, function(a, b)
        local ka, kb = key(a), key(b)
        if ka == kb then return pos[a] < pos[b] end
        if desc then return ka > kb end
        return ka < kb
    end)
    return copy
end

--- A page of `items`, shaped like the server's own (content, totalPages, totalElements, last).
function Scope.page(items, page, size)
    items = items or {}
    page, size = tonumber(page) or 0, math.max(1, tonumber(size) or 40)
    local content = {}
    for i = page * size + 1, math.min(#items, (page + 1) * size) do content[#content + 1] = items[i] end
    local pages = math.max(1, math.ceil(#items / size))
    return { content = content, totalPages = pages, totalElements = #items, number = page, last = page + 1 >= pages }
end

return Scope
