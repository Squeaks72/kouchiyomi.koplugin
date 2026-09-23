--[[
    Helpers for binding a downloaded chapter file to its Uchiyomi book id and
    for reading/writing KOReader sidecar metadata without opening the document.

    The binding is stored twice for robustness:
      * in KOReader's own sidecar (DocSettings) under `uchiyomi_book_id`
      * in <file>.sdr/custom_metadata.lua (also read by KOReader's book info)
--]]

local logger = require("logger")

local Sidecar = {}

--[[
    KOReader doc settings to seed into a freshly downloaded chapter -- `inverse_reading_order` for the
    right-to-left page turning manga wants, `kopt_page_scroll`, `kopt_trim_page`, `kopt_hw_dithering`,
    `invert_ui_layout`.
    main.lua fills this in from the plugin's settings (see Plugin:docDefaults). It may be a function of
    the book, since the view mode can differ per series.

    Seeding them here rather than applying them after opening is what keeps the first paint right:
    KOReader reads these in ReaderView/ReaderZooming onReadSettings (readerview.lua ~L980), so a file
    that arrives with them set opens correctly with no toggle, no re-render and no notification.
--]]
Sidecar.doc_defaults = nil

local function custom_metadata_paths(filepath)
    local sdr1 = filepath:gsub("%.%w+$", "") .. ".sdr"
    local sdr2 = filepath .. ".sdr"
    return sdr1 .. "/custom_metadata.lua", sdr2 .. "/custom_metadata.lua"
end

local function serialize(v, indent_level)
    indent_level = indent_level or 1
    local indent = string.rep("    ", indent_level)
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "table" then
        local parts = { "{\n" }
        for k2, v2 in pairs(v) do
            local key_str = type(k2) == "string" and string.format("[%q]", k2) or string.format("[%s]", tostring(k2))
            local val_str = serialize(v2, indent_level + 1)
            if val_str then
                table.insert(parts, string.format("%s    %s = %s,\n", indent, key_str, val_str))
            end
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    end
    return nil
end

function Sidecar.loadCustomMetadata(filepath)
    local p1, p2 = custom_metadata_paths(filepath)
    for _i, path in ipairs({ p1, p2 }) do
        local f = io.open(path, "r")
        if f then
            f:close()
            local func = loadfile(path)
            if func then
                local ok, data = pcall(func)
                if ok and type(data) == "table" then return data, path end
            end
        end
    end
    return nil
end

function Sidecar.saveCustomMetadata(filepath, key_or_table, value)
    local p1 = custom_metadata_paths(filepath)
    local data, found = Sidecar.loadCustomMetadata(filepath)
    data = data or {}
    if found then p1 = found end
    if type(key_or_table) == "table" then
        for k, v in pairs(key_or_table) do data[k] = v end
    else
        data[key_or_table] = value
    end
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.makePath then
        local dir = p1:match("(.*)/[^/]+")
        if dir then pcall(util.makePath, dir .. "/") end
    end
    local f, err = io.open(p1, "w")
    if not f then
        logger.warn("kouchiyomi: cannot write custom_metadata.lua:", tostring(err))
        return false
    end
    f:write("return {\n")
    for k, v in pairs(data) do
        local s = serialize(v, 1)
        if s then f:write(string.format("    [%q] = %s,\n", k, s)) end
    end
    f:write("}\n")
    f:close()
    return true
end

--- Open the sidecar DocSettings for a file without creating it, or nil.
function Sidecar.openDocSettings(filepath, create)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return nil end
    if not create and DocSettings.hasSidecarFile then
        local ok2, has = pcall(DocSettings.hasSidecarFile, DocSettings, filepath)
        if ok2 and not has then return nil end
    end
    local ok3, ds = pcall(DocSettings.open, DocSettings, filepath)
    if ok3 and ds then return ds end
    return nil
end

--- Read the Uchiyomi book id bound to a file (sidecar first, then custom_metadata).
function Sidecar.readBookId(filepath)
    local ds = Sidecar.openDocSettings(filepath, false)
    if ds then
        local id = ds:readSetting("uchiyomi_book_id")
        if id and id ~= "" then return id end
    end
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.openSettingsFile then
        local ok2, cds = pcall(DocSettings.openSettingsFile, DocSettings, filepath)
        if ok2 and cds then
            local id = cds:readSetting("uchiyomi_book_id")
            if id and id ~= "" then return id end
        end
    end
    local cm = Sidecar.loadCustomMetadata(filepath)
    if cm and cm.uchiyomi_book_id and cm.uchiyomi_book_id ~= "" then
        return cm.uchiyomi_book_id
    end
    return nil
end

--- Persist the book binding plus display metadata for a downloaded file.
function Sidecar.saveBookMetadata(filepath, book, series_title, series)
    if not filepath or not book then return end
    local ok, DocSettings = pcall(require, "docsettings")
    local cds = ok and DocSettings and DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath) or nil

    local custom_props, doc_props = {}, {}
    if cds then
        custom_props = cds:readSetting("custom_props") or {}
        doc_props = cds:readSetting("doc_props") or {}
    end
    local title = (book.metadata and book.metadata.title) or book.name
    if title and title ~= "" then
        custom_props.title = title
        doc_props.title = title
    end
    local number = (book.metadata and (book.metadata.number or book.metadata.numberSort)) or book.number
    if number ~= nil then
        custom_props.series_index = tostring(number)
        doc_props.series_index = tostring(number)
    end
    local s_title = series_title or book.seriesTitle
    if s_title and s_title ~= "" then
        custom_props.series = s_title
        doc_props.series = s_title
    end
    local author = series and series.metadata and series.metadata.author
    if author and author ~= "" then
        custom_props.authors = author
        doc_props.authors = author
    end
    local summary = series and series.metadata and series.metadata.summary
    if summary and summary ~= "" then
        custom_props.description = summary
        doc_props.description = summary
    end

    local direction = series and series.metadata and series.metadata.readingDirection or nil
    if cds then
        cds:saveSetting("uchiyomi_book_id", book.id)
        cds:saveSetting("uchiyomi_series_id", book.seriesId)
        if direction then cds:saveSetting("uchiyomi_reading_direction", direction) end
        -- Only keys the file has no opinion on yet: KOReader writes its own back on every document it
        -- closes (ReaderView/ReaderKoptListener onSaveSettings), so overwriting them would undo a page
        -- turn direction or a view mode chosen by hand on a chapter that has already been read.
        local defaults = Sidecar.doc_defaults
        if type(defaults) == "function" then
            local ok, out = pcall(defaults, book, series)
            defaults = ok and out or nil
        end
        for key, value in pairs(defaults or {}) do
            if not (cds.has and cds:has(key)) then cds:saveSetting(key, value) end
        end
        cds:saveSetting("custom_props", custom_props)
        cds:saveSetting("doc_props", doc_props)
        if cds.flushCustomMetadata then
            cds:flushCustomMetadata(filepath)
        elseif cds.flush then
            cds:flush()
        end
    end
    Sidecar.saveCustomMetadata(filepath, {
        uchiyomi_book_id = book.id,
        uchiyomi_series_id = book.seriesId,
        uchiyomi_reading_direction = direction,
        custom_props = custom_props,
        doc_props = doc_props,
    })
end

function Sidecar.clearBookId(filepath)
    pcall(function()
        local ok, DocSettings = pcall(require, "docsettings")
        local cds = ok and DocSettings and DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath) or nil
        if cds then
            cds:saveSetting("uchiyomi_book_id", nil)
            cds:saveSetting("uchiyomi_series_id", nil)
            if cds.flush then cds:flush() end
        end
        Sidecar.saveCustomMetadata(filepath, { uchiyomi_book_id = nil, uchiyomi_series_id = nil })
    end)
end

--- Local reading state of a closed document from its sidecar:
-- { page, page_count, percent, finished }
function Sidecar.readLocalProgress(filepath)
    local ds = Sidecar.openDocSettings(filepath, false)
    if not ds then return nil end
    local summary = ds:readSetting("summary")
    local out = {
        page = ds:readSetting("last_page"),
        percent = ds:readSetting("percent_finished"),
        page_count = ds:readSetting("doc_pages"),
        finished = type(summary) == "table" and summary.status == "complete" or false,
    }
    if type(out.percent) == "number" and out.percent >= 1 then out.finished = true end
    return out
end

--- Write server-side progress into a closed document's sidecar so KOReader
-- opens it at that page and lists it with the right status.
function Sidecar.writeLocalProgress(filepath, page, page_count, completed)
    local ds = Sidecar.openDocSettings(filepath, true)
    if not ds then return false end
    if page and page > 0 then ds:saveSetting("last_page", page) end
    if page_count and page_count > 0 then
        ds:saveSetting("doc_pages", page_count)
        if page and page > 0 then
            ds:saveSetting("percent_finished", math.min(1, page / page_count))
        end
    end
    local summary = ds:readSetting("summary") or {}
    if completed then
        summary.status = "complete"
        summary.modified = os.date("%Y-%m-%d", os.time())
        if page_count and page_count > 0 then ds:saveSetting("percent_finished", 1) end
    elseif summary.status == "complete" then
        summary.status = "reading"
        summary.modified = os.date("%Y-%m-%d", os.time())
    end
    ds:saveSetting("summary", summary)
    if ds.flush then ds:flush() end
    pcall(function()
        local BookList = require("ui/widget/booklist")
        if BookList and BookList.setBookInfoCacheProperty then
            BookList.setBookInfoCacheProperty(filepath, "status", completed and "complete" or "reading")
            if page_count and page_count > 0 and page then
                BookList.setBookInfoCacheProperty(filepath, "percent_finished", completed and 1 or math.min(1, page / page_count))
            end
        end
    end)
    return true
end

--- Page bookmarks stored in a closed document's sidecar: returns { [page]=true }.
function Sidecar.readLocalBookmarks(filepath)
    local ds = Sidecar.openDocSettings(filepath, false)
    if not ds then return nil end
    local ann = ds:readSetting("annotations")
    local out = {}
    if type(ann) == "table" then
        for _i, item in ipairs(ann) do
            if type(item) == "table" and not item.drawer and type(item.page) == "number" then
                out[item.page] = true
            end
        end
    end
    return out
end

return Sidecar
