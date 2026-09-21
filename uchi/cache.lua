--[[
    Cover-art cache for the Uchiyomi browser. Covers live under
    <koreader data dir>/kouchiyomi_covers/<type>_<id>.img
--]]

local logger = require("logger")

local Cache = {}

function Cache:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

function Cache.coversDir()
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/kouchiyomi_covers"
end

local COVER_EXTS = { "jpg", "png", "webp", "gif" }

local function base_path(type_label, id)
    return Cache.coversDir() .. "/" .. type_label .. "_" .. tostring(id)
end

--- Path of the cached cover if one exists (any supported extension), else nil.
function Cache.existingCoverPath(type_label, id)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then return nil end
    local base = base_path(type_label, id)
    for _i, ext in ipairs(COVER_EXTS) do
        local p = base .. "." .. ext
        if lfs.attributes(p, "mode") == "file" then return p end
    end
    return nil
end

--- Path the widgets should try: the existing file, or the .jpg name when none is cached.
-- KOReader's ImageWidget picks its decoder from the extension, so the
-- extension must reflect the real image type (see sniff_ext).
function Cache.coverPath(type_label, id)
    return Cache.existingCoverPath(type_label, id) or (base_path(type_label, id) .. ".jpg")
end

local function sniff_ext(data)
    if data:sub(1, 4) == "\137PNG" then return "png" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 3) == "GIF" then return "gif" end
    return "jpg"
end

function Cache:write_file(filepath, content)
    local f = io.open(filepath, "wb")
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

function Cache:ensureStructure()
    if not self.plugin.settings.library_metadata_cache then
        self.plugin.settings.library_metadata_cache = {}
    end
    local cache = self.plugin.settings.library_metadata_cache
    if not cache.covers then cache.covers = {} end
end

function Cache:clear()
    self.plugin.settings.library_metadata_cache = {}
    self:ensureStructure()
    self.plugin:saveSettings()
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local dir = Cache.coversDir()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
        end
    end)
    logger.info("kouchiyomi: cover cache cleared")
end

-- Uchiyomi has no per-series lastModified for covers; we key freshness on a
-- version string when one is present (artVersion) and otherwise keep the
-- first copy until the user clears the cache.
function Cache:cacheThumbnail(type_label, id, version, force)
    if not force and not self.plugin.settings.cache_covers then return nil end
    if not self.plugin.api then return nil end
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    local cache_key = type_label .. "_" .. tostring(id)
    local util = require("util")
    util.makePath(Cache.coversDir() .. "/")
    local existing = Cache.existingCoverPath(type_label, id)
    if existing then
        if self.plugin.settings.never_update_covers or version == nil or cache.covers[cache_key] == version then
            return existing
        end
    end

    local img_data
    if type_label == "series" then
        img_data = self.plugin.api:download_series_thumbnail(id)
    else
        img_data = self.plugin.api:download_book_thumbnail(id)
    end
    if img_data and type(img_data) == "string" and #img_data > 0 then
        local local_path = base_path(type_label, id) .. "." .. sniff_ext(img_data)
        if existing and existing ~= local_path then os.remove(existing) end
        if self:write_file(local_path, img_data) then
            cache.covers[cache_key] = version or true
            self.plugin:saveSettings()
            return local_path
        end
    end
    return nil
end

--- Download missing covers for a list of series/books before rendering a page.
function Cache:prefetchCovers(item_list, type_label)
    if not item_list or #item_list == 0 then return end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache

    local to_download = {}
    for _i, item in ipairs(item_list) do
        if item and item.id then
            local cache_key = type_label .. "_" .. tostring(item.id)
            local version = item.artVersion
            local exists = Cache.existingCoverPath(type_label, item.id) ~= nil
            local needs = true
            if exists then
                if self.plugin.settings.never_update_covers or version == nil or cache.covers[cache_key] == version then
                    needs = false
                end
            end
            if needs then table.insert(to_download, { id = item.id, version = version }) end
        end
    end
    if #to_download == 0 then return end

    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local message = InfoMessage:new{ text = T(_("Fetching %1 covers..."), #to_download) }
    UIManager:show(message)
    UIManager:forceRePaint()
    for _i, item in ipairs(to_download) do
        self:cacheThumbnail(type_label, item.id, item.version, true)
    end
    UIManager:close(message)
end

return Cache
