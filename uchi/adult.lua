--[[
    Which series are 18+, and therefore never to leave a trace on the device.

    Uchiyomi's own rule (bff/src/lib/visibility.ts) has two halves, and the split
    is the whole design:

      * `visible()`   -- by-id resolvers, page bytes, the chapter list,
                         next/previous, the progress write path. NO 18+ filter,
                         because "that filter is about what appears unasked and
                         this is asked for".
      * `browsable()` -- anything that LISTS series: the library grid, search,
                         the home rails, OPDS feeds. Hides 18+ unless the
                         request carries `adult=1`.

    So the plugin does not have to filter its own home: it simply stops asking
    to be shown 18+ on the listing endpoints and the server keeps them out,
    while a series opened by id still reads normally. That is uchi/api's job.

    What the plugin does have to work out for itself is whether the chapter in
    front of it is 18+, because that decides whether it may be written to disk
    at all (see Sync:downloadBook). The server has three signals; two of them
    travel in data the plugin already holds:

      1. the library's age rating -- `adult` on each entry of /api/libraries,
      2. the series' own age rating -- `metadata.ageRating`, which is the
         admin's per-series override of the above,
      3. genres an admin has named as adult, which lives only in the server's
         `server_settings` table and is not exposed by any endpoint.

    (3) is out of reach, so a series whose ONLY claim to being 18+ is a genre in
    that list is not caught here. Worth knowing, but the libraries are the axis
    this library is actually organised on.
--]]

local Adult = {}

--- ADULT_RATING in bff/src/lib/visibility.ts.
Adult.RATING = 18

--- How long the list of which libraries are 18+ is trusted. Libraries are
-- created by hand and almost never change, and the answer has to survive being
-- offline, so it is kept in the settings file rather than in memory.
local LIBRARIES_TTL = 24 * 60 * 60

--- The rule itself, over the two signals that reach the client.
-- `library_adult` and `age_rating` may each be nil (not known); nil for both is
-- "nothing says this is 18+", which is how an unrated series in an unrated
-- library reads -- the same way the server treats NULL.
function Adult.decide(library_adult, age_rating)
    if library_adult == true then return true end
    local n = tonumber(age_rating)
    if n and n >= Adult.RATING then return true end
    return false
end

--[[
    Which library ids are 18+.

    /api/libraries answers this without `adult=1` and always has: the list is
    filtered by the viewer's age cap only, and carries `adult` per entry
    precisely so a client can know an 18+ shelf EXISTS without being shown what
    is in it (owned.libraries in bff/src/lib/ownedCatalog.ts).

    Returns a set of ids, from the settings cache when it is fresh or the server
    is out of reach. An empty set is a valid answer and a stale one is better
    than none, so a failed refresh keeps whatever was known.
--]]
function Adult.libraryIds(plugin, force)
    local s = plugin.settings
    local cached = s.adult_libraries
    local age = os.time() - (tonumber(s.adult_libraries_at) or 0)
    if not force and type(cached) == "table" and age < LIBRARIES_TTL then return cached end
    if not plugin.api then return type(cached) == "table" and cached or {} end
    local libs = plugin.api:get_libraries()
    local content = type(libs) == "table" and (libs.content or libs) or nil
    if type(content) ~= "table" then return type(cached) == "table" and cached or {} end
    local set = {}
    for _i, lib in ipairs(content) do
        if type(lib) == "table" and lib.id and lib.adult then set[tostring(lib.id)] = true end
    end
    s.adult_libraries = set
    s.adult_libraries_at = os.time()
    plugin:saveSettings()
    return set
end

--- Is this series 18+? `series` is a series DTO.
function Adult.isSeries(plugin, series)
    if type(series) ~= "table" then return nil end
    local lib_adult
    if series.libraryId then
        lib_adult = Adult.libraryIds(plugin)[tostring(series.libraryId)] == true
    end
    local rating = series.metadata and series.metadata.ageRating
    local verdict = Adult.decide(lib_adult, rating)
    if series.id then
        local cache = plugin.settings.adult_series_cache or {}
        local key = tostring(series.id)
        -- Only when it changes: the sweep asks this of every downloaded chapter,
        -- and a settings write per chapter would be the slowest thing it does.
        if cache[key] ~= verdict then
            cache[key] = verdict
            plugin.settings.adult_series_cache = cache
            plugin:saveSettings()
        end
    end
    return verdict
end

--- What is already known about a series, without asking the server: the answer
-- from a previous look. This is what makes the question answerable offline.
function Adult.knownSeries(plugin, series_id)
    if not series_id then return nil end
    local cache = plugin.settings.adult_series_cache
    if type(cache) ~= "table" then return nil end
    return cache[tostring(series_id)]
end

--[[
    Is the chapter in front of us 18+?

    `series` is used when the caller already has it (Sync:downloadBook fetches
    the series for the download path anyway), then the remembered answer, then
    the server. Returns nil only when nothing could say -- offline, first sight
    of the series, no series id -- which callers read as "not 18+": the
    alternative is refusing every download the moment the server is unreachable,
    and a chapter cannot be downloaded without the server in the first place.
--]]
function Adult.isBook(plugin, book, series)
    if type(series) == "table" then return Adult.isSeries(plugin, series) end
    local series_id = type(book) == "table" and (book.seriesId or book.series_id) or nil
    local known = Adult.knownSeries(plugin, series_id)
    if known ~= nil then return known end
    if not series_id or not plugin.api then return nil end
    local s = plugin.api:get_series(series_id)
    if type(s) ~= "table" then return nil end
    return Adult.isSeries(plugin, s)
end

--- Is the open document's chapter 18+? The sidecar holds the series id, so this
-- is answerable for a downloaded chapter without the server.
function Adult.isPath(plugin, filepath)
    if not filepath then return nil end
    local Sidecar = require("uchi/sidecar")
    local sid
    local ds = Sidecar.openDocSettings(filepath, false)
    if ds then sid = ds:readSetting("uchiyomi_series_id") end
    if not sid then
        local cm = Sidecar.loadCustomMetadata(filepath)
        sid = cm and cm.uchiyomi_series_id
    end
    if not sid then return nil end
    local known = Adult.knownSeries(plugin, sid)
    if known ~= nil then return known end
    if not plugin.api then return nil end
    local s = plugin.api:get_series(sid)
    if type(s) ~= "table" then return nil end
    return Adult.isSeries(plugin, s)
end

return Adult
