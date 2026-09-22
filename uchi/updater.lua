--[[
    Self-updater: pulls the plugin's files from its GitHub repository.

    The repository is read through the GitHub REST API, one file at a time
    (git tree -> raw contents), so no archive handling is needed on the device.
    A private repository needs a token with read access to its contents
    (Settings -> Plugin update -> GitHub token); a public one needs nothing.

    Files are written to a staging folder first and only moved into place once
    every file downloaded, so a dropped connection cannot leave a half-updated
    plugin. The previous files are kept in `.backup/` until the next update.
--]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local JSON = require("json")

local Updater = {}

local API = "https://api.github.com"
local SKIP = { "^tests/", "^%.git", "^%.update%-tmp/", "^%.backup/" }

function Updater:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

local function fetch(url, token, accept)
    local out = {}
    local headers = {
        ["Accept"] = accept or "application/vnd.github+json",
        ["User-Agent"] = "kouchiyomi-updater",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    if token and token ~= "" then headers["Authorization"] = "Bearer " .. token end
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil then pcall(socketutil.set_timeout, socketutil, 20, 120) end
    local req = { url = url, method = "GET", headers = headers, sink = ltn12.sink.table(out), redirect = false }
    local res, code, rheaders = (url:find("^https://") and https or http).request(req)
    if ok_su and socketutil then pcall(socketutil.reset_timeout, socketutil) end
    if not res then return nil, "network: " .. tostring(code) end
    code = tonumber(code) or code
    local body = table.concat(out)
    if code == 302 or code == 301 then
        local loc = rheaders and (rheaders.location or rheaders.Location)
        if loc then return fetch(loc, nil, accept) end
    end
    if code ~= 200 then
        local msg = "HTTP " .. tostring(code)
        if code == 404 then msg = "not found (private repository without a token, or wrong repo/branch)"
        elseif code == 401 then msg = "token rejected"
        elseif code == 403 then msg = "forbidden or rate-limited" end
        return nil, msg
    end
    return body
end

function Updater:repo()
    return self.plugin.settings.update_repo or "Squeaks72/kouchiyomi.koplugin"
end

function Updater:ref()
    return self.plugin.settings.update_ref or "main"
end

function Updater:token()
    return self.plugin.settings.github_token or ""
end

local function parse_version(text)
    return text and text:match('version%s*=%s*"([^"]+)"') or nil
end

local function version_tuple(v)
    local t = {}
    for n in tostring(v or "0"):gmatch("%d+") do table.insert(t, tonumber(n)) end
    return t
end

--- true when a is newer than b
local function newer(a, b)
    local ta, tb = version_tuple(a), version_tuple(b)
    for i = 1, math.max(#ta, #tb) do
        local x, y = ta[i] or 0, tb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
Updater.isNewer = newer

function Updater:localVersion()
    local f = io.open(self.plugin.path .. "/_meta.lua", "r")
    if not f then return "0" end
    local v = parse_version(f:read("*a"))
    f:close()
    return v or "0"
end

--- Ask GitHub for the version on the tracked branch. Returns { current, latest, newer }, or nil, err.
function Updater:check()
    local url = string.format("%s/repos/%s/contents/_meta.lua?ref=%s", API, self:repo(), self:ref())
    local body, err = fetch(url, self:token(), "application/vnd.github.raw+json")
    if not body then return nil, err end
    local latest = parse_version(body)
    if not latest then return nil, "could not read the remote version" end
    local current = self:localVersion()
    local info = { current = current, latest = latest, newer = newer(latest, current) }
    self.plugin.settings.update_last_check = os.time()
    self.plugin.settings.update_latest_seen = latest
    self.plugin:saveSettings()
    return info
end

local function ensure_dir(path)
    local util = require("util")
    util.makePath(path .. "/")
end

local function rm_tree(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "directory" then return end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local p = path .. "/" .. name
            if lfs.attributes(p, "mode") == "directory" then rm_tree(p) else os.remove(p) end
        end
    end
    os.remove(path)
end

local function skipped(path)
    for _i, pat in ipairs(SKIP) do
        if path:match(pat) then return true end
    end
    return false
end

--- Download the tracked branch into place. progress_cb(done, total, path) optional.
-- Returns true, version  or  nil, err.
function Updater:update(progress_cb)
    local lfs = require("libs/libkoreader-lfs")
    local root = self.plugin.path
    local tree_url = string.format("%s/repos/%s/git/trees/%s?recursive=1", API, self:repo(), self:ref())
    local body, err = fetch(tree_url, self:token())
    if not body then return nil, "listing files: " .. tostring(err) end
    local ok, tree = pcall(JSON.decode, body)
    if not ok or type(tree) ~= "table" or type(tree.tree) ~= "table" then return nil, "unexpected tree answer" end
    local files = {}
    for _i, node in ipairs(tree.tree) do
        if node.type == "blob" and not skipped(node.path) then table.insert(files, node.path) end
    end
    if #files == 0 then return nil, "no files in the repository tree" end

    local stage = root .. "/.update-tmp"
    rm_tree(stage)
    ensure_dir(stage)
    local remote_version
    for i, path in ipairs(files) do
        if progress_cb then progress_cb(i, #files, path) end
        local raw_url = string.format("%s/repos/%s/contents/%s?ref=%s", API, self:repo(),
            path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end), self:ref())
        local data, ferr = fetch(raw_url, self:token(), "application/vnd.github.raw+json")
        if not data then
            rm_tree(stage)
            return nil, path .. ": " .. tostring(ferr)
        end
        if path == "_meta.lua" then remote_version = parse_version(data) end
        local dest = stage .. "/" .. path
        ensure_dir(dest:match("(.*)/[^/]+$"))
        local f, werr = io.open(dest, "wb")
        if not f then rm_tree(stage); return nil, "write " .. path .. ": " .. tostring(werr) end
        f:write(data)
        f:close()
    end

    -- Everything downloaded: swap in. Keep one backup of the previous files.
    local backup = root .. "/.backup"
    rm_tree(backup)
    ensure_dir(backup)
    for _i, path in ipairs(files) do
        local cur = root .. "/" .. path
        if lfs.attributes(cur, "mode") == "file" then
            ensure_dir((backup .. "/" .. path):match("(.*)/[^/]+$"))
            os.rename(cur, backup .. "/" .. path)
        end
    end
    for _i, path in ipairs(files) do
        local dest = root .. "/" .. path
        ensure_dir(dest:match("(.*)/[^/]+$"))
        local okr, rerr = os.rename(stage .. "/" .. path, dest)
        if not okr then
            logger.err("kouchiyomi updater: could not place", path, rerr)
            -- roll back what we can
            for _j, p2 in ipairs(files) do
                local b = backup .. "/" .. p2
                if lfs.attributes(b, "mode") == "file" then os.rename(b, root .. "/" .. p2) end
            end
            rm_tree(stage)
            return nil, "install failed at " .. path .. "; previous files restored"
        end
    end
    -- Remove Lua files the repository no longer has (excluding tests/backup/staging).
    local keep = {}
    for _i, path in ipairs(files) do keep[path] = true end
    local function sweep(dir, rel)
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                local p, r = dir .. "/" .. name, (rel and rel .. "/" or "") .. name
                if lfs.attributes(p, "mode") == "directory" then
                    if not skipped(r .. "/") then sweep(p, r) end
                elseif name:match("%.lua$") and not keep[r] and not skipped(r) then
                    os.rename(p, backup .. "/" .. r:gsub("/", "__"))
                end
            end
        end
    end
    pcall(sweep, root, nil)
    rm_tree(stage)
    self.plugin.settings.update_installed_at = os.time()
    self.plugin:saveSettings()
    return true, remote_version
end

--- Interactive flow: check, then offer to install and restart.
function Updater:promptUpdate(is_manual)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then NetworkMgr:runWhenOnline(function() self:promptUpdate(true) end) end
        return
    end
    local info, err = self:check()
    if not info then
        if is_manual then self.plugin:notify(T(_("Update check failed: %1"), tostring(err)), "error") end
        return
    end
    if not info.newer then
        if is_manual then self.plugin:notify(T(_("kouchiyomi %1 is up to date."), info.current), "info") end
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("kouchiyomi %1 is available (you have %2). Install it now? KOReader restarts afterwards."), info.latest, info.current),
        ok_text = _("Install"),
        cancel_text = _("Later"),
        ok_callback = function() self:install() end,
    })
end

function Updater:install()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Downloading update...") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, res = self:update(function(done, total)
            if done % 4 == 0 then
                UIManager:close(msg)
                msg = InfoMessage:new{ text = T(_("Downloading update... %1/%2"), done, total) }
                UIManager:show(msg)
                UIManager:forceRePaint()
            end
        end)
        UIManager:close(msg)
        if not ok then
            self.plugin:notify(T(_("Update failed: %1"), tostring(res)), "error")
            return
        end
        local Device = require("device")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("kouchiyomi %1 installed. Restart KOReader now?"), tostring(res or "")),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function()
                if Device:canRestart() then
                    UIManager:restartKOReader()
                else
                    self.plugin:notify(_("Please restart KOReader to finish the update."), "info")
                end
            end,
        })
    end)
end

--- Background check at most once a day; only notifies when something is new.
function Updater:maybeAutoCheck()
    if self.plugin.settings.update_auto_check == false then return end
    local last = tonumber(self.plugin.settings.update_last_check) or 0
    if os.time() - last < 24 * 3600 then return end
    UIManager:scheduleIn(5, function()
        local info = self:check()
        if info and info.newer then
            local _ = self.plugin.i18n._
            local T = self.plugin.i18n.T
            self.plugin:notify(T(_("kouchiyomi %1 is available. Tools > Uchiyomi > Plugin update."), info.latest), "info")
        end
    end)
end

return Updater
