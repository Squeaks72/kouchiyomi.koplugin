--[[
    Libraries this device leaves out of everything it lists.

    A preference of this device, not of the server: the other Uchiyomi apps and every by-id read are untouched, so a
    chapter already open, its next chapter and progress sync all carry on. What goes is search, the catalogue views,
    the home screen, favourites, lists, bookmarks and the BookOrbit widgets. Downloaded chapters stay listed under
    Downloaded chapters, because that is the only place left to open or delete them.

    A search can say "not in this library" and the server pages the answer properly. The other listings cannot, and
    some of what they return does not name a library: a chapter carries only seriesId and a bookmark only series_id. So
    the hidden libraries' series ids are read once and kept, and those listings are cut here.
--]]

local Hidden = {}

-- How long the series ids of the hidden libraries are trusted. A series carrying its libraryId never depends on them.
Hidden.TTL = 6 * 3600

--- The hidden libraries: id -> name.
function Hidden.libraries(plugin)
    local libs = plugin.settings.hidden_libraries
    return type(libs) == "table" and libs or {}
end

function Hidden.any(plugin)
    return next(Hidden.libraries(plugin)) ~= nil
end

function Hidden.isLibrary(plugin, library_id)
    return library_id ~= nil and Hidden.libraries(plugin)[tostring(library_id)] ~= nil
end

--- Is this series hidden? `dto`, when there is one and it names its library, decides: it is newer than the kept ids.
function Hidden.isSeries(plugin, series_id, dto)
    if not Hidden.any(plugin) then return false end
    if type(dto) == "table" and dto.libraryId then return Hidden.isLibrary(plugin, dto.libraryId) end
    local ids = plugin.settings.hidden_series
    return series_id ~= nil and type(ids) == "table" and ids[tostring(series_id)] == true
end

--- Read the hidden libraries' series ids if they have gone stale (or `force`). A failure keeps what was known and is
-- tried again next time. Returns false only when the ids could not be read.
function Hidden.refresh(plugin, force)
    local s = plugin.settings
    if not Hidden.any(plugin) then
        s.hidden_series, s.hidden_series_at = {}, 0
        return true
    end
    local age = os.time() - (tonumber(s.hidden_series_at) or 0)
    if not force and age < Hidden.TTL then return true end
    if not plugin.api then return false end
    local ids = {}
    for id in pairs(Hidden.libraries(plugin)) do table.insert(ids, id) end
    table.sort(ids)
    local found = plugin.api:series_ids_in(ids)
    if not found then
        s.hidden_series_at = 0
        return false
    end
    s.hidden_series, s.hidden_series_at = found, os.time()
    plugin:saveSettings()
    return true
end

--- A series search condition that also leaves the hidden libraries out.
function Hidden.condition(plugin, condition)
    local ids = {}
    for id in pairs(Hidden.libraries(plugin)) do table.insert(ids, id) end
    if #ids == 0 then return condition end
    table.sort(ids)
    local all = {}
    if condition then all[1] = condition end
    for _i, id in ipairs(ids) do
        table.insert(all, { libraryId = { operator = "isNot", value = id } })
    end
    return { allOf = all }
end

--- `list` (an array, or a response holding one in `content` or `items`) without the entries `hide` picks, in the same shape.
local function without(list, hide)
    if type(list) ~= "table" then return list end
    local key = (type(list.content) == "table" and "content") or (type(list.items) == "table" and "items") or nil
    local out = {}
    for _i, entry in ipairs(key and list[key] or list) do
        if not hide(entry) then table.insert(out, entry) end
    end
    if not key then return out end
    local copy = {}
    for k, v in pairs(list) do copy[k] = v end
    copy[key] = out
    return copy
end

function Hidden.withoutLibraries(plugin, list)
    if not Hidden.any(plugin) then return list end
    return without(list, function(lib) return type(lib) == "table" and Hidden.isLibrary(plugin, lib.id) end)
end

function Hidden.withoutSeries(plugin, list)
    if not Hidden.any(plugin) then return list end
    return without(list, function(series) return type(series) == "table" and Hidden.isSeries(plugin, series.id, series) end)
end

--- Chapters: `seriesId`. Bookmarks: `series_id`.
function Hidden.withoutChapters(plugin, list)
    if not Hidden.any(plugin) then return list end
    return without(list, function(entry)
        return type(entry) == "table" and Hidden.isSeries(plugin, entry.seriesId or entry.series_id)
    end)
end

--- Hide or show a library, and take what is already on the device with it. Returns false when hiding took effect but
-- the series ids could not be read, so chapters and bookmarks from it may still be listed until they can.
function Hidden.set(plugin, library_id, name, hide)
    local s = plugin.settings
    if type(s.hidden_libraries) ~= "table" then s.hidden_libraries = {} end
    s.hidden_libraries[tostring(library_id)] = hide and (name or tostring(library_id)) or nil
    local ok = Hidden.refresh(plugin, true)
    plugin._home_cache, plugin._scope_cache = nil, nil
    if type(s.home_rows) == "table" then
        for field, row in pairs(s.home_rows) do s.home_rows[field] = Hidden.withoutChapters(plugin, row) end
    end
    plugin:saveSettings()
    return ok
end

return Hidden
