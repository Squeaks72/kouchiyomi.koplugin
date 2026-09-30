--[[
    Taking 18+ chapters out of KOReader's reading statistics.

    The rest of the 18+ hiding works by there being no file: nothing is written,
    so nothing can be listed (see uchi/adult). KOReader's statistics are the one
    place that outlives the file -- `statistics.sqlite3` keeps a `book` row per
    document ever opened, with its title, author and series, and every reading
    session against it. A chapter read before 0.10.0 is still in there, and
    KOReader's own Statistics menu lists those titles under "Top books".

    (Home-screen plugins are a different matter: SimpleUI reads this database
    for durations and page counts only, never titles. This is about KOReader's
    own statistics screens.)

    Two ways a row is recognised, because the file is usually already gone:

      * its md5 -- `util.partialMD5` of a file the sweep is about to delete,
        which is the same identity the statistics plugin filed it under, and
        is exact;
      * its series -- matched against the series titles of the server's 18+
        libraries. This is the one that reaches chapters deleted long ago, whose
        files cannot be hashed any more.

    A chapter whose sidecar carried no series ("N/A" in the database) and whose
    file is already gone cannot be recognised by either, and is left alone.

    The database is copied once before anything is deleted. Deleting is not
    undoable and it lowers real reading totals and streaks.
--]]

local logger = require("logger")

local Stats = {}

--- Where the statistics plugin keeps its database (plugins/statistics.koplugin).
function Stats.dbPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/statistics.sqlite3"
end

function Stats.backupPath()
    return Stats.dbPath() .. ".kouchiyomi-bkp"
end

--[[
    Does this `book` row belong to an 18+ series?

    `series_titles` is a set of titles. The statistics plugin stores the series
    with its index appended when there is one -- `series .. " #" .. series_index`
    in its main.lua -- so "One Piece #944" has to match "One Piece". The match is
    done here, in Lua, rather than in SQL, so that a title containing `%` or `_`
    cannot turn into a wildcard that deletes somebody else's book.
--]]
function Stats.matches(row, series_titles, md5s)
    if type(row) ~= "table" then return false end
    if row.md5 and type(md5s) == "table" and md5s[row.md5] then return true end
    if type(series_titles) ~= "table" then return false end
    local s = row.series
    -- "N/A" is what the statistics plugin writes when a document has no series,
    -- so it identifies nothing and must never match a title.
    if type(s) ~= "string" or s == "" or s == "N/A" then return false end
    if series_titles[s] then return true end
    local base = s:match("^(.*) #[%d%.]+$")
    return base ~= nil and series_titles[base] == true
end

--- One copy of the database, kept from the first purge onwards. Never
-- overwritten: the useful backup is the one from before the first deletion.
function Stats.backupOnce()
    local lfs = require("libs/libkoreader-lfs")
    local db, bkp = Stats.dbPath(), Stats.backupPath()
    if lfs.attributes(db, "mode") ~= "file" then return false, "no statistics database" end
    if lfs.attributes(bkp, "mode") == "file" then return true end
    local ok, err = pcall(function() require("ffi/util").copyFile(db, bkp) end)
    if not ok then return false, tostring(err) end
    logger.info("kouchiyomi: statistics database backed up as", bkp)
    return true
end

--[[
    Delete the statistics of every 18+ book, and its reading sessions with it.

    Returns how many books were removed, and an error string when the database
    could not be touched at all. `page_stat` is a VIEW over `page_stat_data`, so
    clearing the data table and the book row is the whole of it.
--]]
function Stats.purge(series_titles, md5s)
    local lfs = require("libs/libkoreader-lfs")
    local db = Stats.dbPath()
    if lfs.attributes(db, "mode") ~= "file" then return 0 end
    local ok_backup, backup_err = Stats.backupOnce()
    if not ok_backup then return 0, backup_err end

    local ok, removed_or_err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db)
        local rows = conn:exec("SELECT id, md5, series, title FROM book;")
        local doomed = {}
        if rows ~= nil and rows.id ~= nil then
            for i = 1, #rows.id do
                local row = {
                    id = tonumber(rows.id[i]),
                    md5 = rows.md5[i],
                    series = rows.series[i],
                    title = rows.title[i],
                }
                if row.id and Stats.matches(row, series_titles, md5s) then
                    table.insert(doomed, row)
                end
            end
        end
        for _i, row in ipairs(doomed) do
            -- Sessions first: a book row with no sessions is merely wrong, an
            -- orphaned session pile is wrong AND still counted by the totals.
            local stmt = conn:prepare("DELETE FROM page_stat_data WHERE id_book = ?;")
            stmt:reset():bind(row.id):step()
            stmt:close()
            stmt = conn:prepare("DELETE FROM book WHERE id = ?;")
            stmt:reset():bind(row.id):step()
            stmt:close()
            logger.info("kouchiyomi: purged statistics for", tostring(row.series), tostring(row.title))
        end
        conn:close()
        return #doomed
    end)
    if not ok then
        logger.warn("kouchiyomi: statistics purge failed:", tostring(removed_or_err))
        return 0, tostring(removed_or_err)
    end
    return removed_or_err or 0
end

--- The md5 the statistics plugin would have filed this file under. Called
-- before the sweep deletes it, which is the last moment it can be computed.
function Stats.md5(path)
    local ok, md5 = pcall(function() return require("util").partialMD5(path) end)
    if ok and type(md5) == "string" and md5 ~= "" then return md5 end
    return nil
end

return Stats
