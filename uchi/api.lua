--[[
    Uchiyomi API connector for KOReader.

    One credential does almost everything: a long-lived Uchiyomi API token
    ("uy_...") sent as `Authorization: Bearer`. It is accepted by the native
    /api/* routes, by the Komga-compatible /api/v1/* routes (thumbnails, page
    images) and by /img/*.

    The only exception is whole-chapter CBZ download, which Uchiyomi serves
    over OPDS (/opds/book/{id}/file) behind HTTP Basic auth with the account
    username and a separate OPDS token. When no OPDS token is configured the
    plugin falls back to fetching the pages one by one and building a CBZ
    locally (core/zip.lua).
--]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local url_utils = require("socket.url")
local logger = require("logger")
local JSON = require("json")

local function encode_base64(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((data:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return b:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

local UchiyomiAPI = {}
UchiyomiAPI.__index = UchiyomiAPI

-- Uchiyomi API token names start with this prefix; we use it to tell an API
-- token from a short-lived session JWT when validating settings.
UchiyomiAPI.TOKEN_PREFIX = "uy_"

local function perform_request(args)
    local response_body = {}
    local request_params = {
        url = args.url,
        method = args.method or "GET",
        headers = args.headers or {},
        sink = args.sink or ltn12.sink.table(response_body),
        timeout = args.timeout or 15,
        redirect = false,
    }
    if args.post_data then
        request_params.source = ltn12.source.string(args.post_data)
        request_params.headers["Content-Length"] = tostring(#args.post_data)
    end
    -- KOReader's socket stack honours a global timeout; set it for slow links.
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil and socketutil.set_timeout then
        local block = args.timeout or 15
        local total = args.total_timeout or math.max(60, block * 4)
        pcall(socketutil.set_timeout, socketutil, block, total)
    end

    local res, code, headers, status
    if args.url:find("https://") == 1 then
        res, code, headers, status = https.request(request_params)
    else
        res, code, headers, status = http.request(request_params)
    end
    if ok_su and socketutil and socketutil.reset_timeout then
        pcall(socketutil.reset_timeout, socketutil)
    end

    logger.dbg("kouchiyomi API", request_params.method, args.url, "->", tostring(code))
    if not res then
        logger.warn("kouchiyomi API request failed:", tostring(code), args.url)
        return nil, code or "Network request failed"
    end
    return {
        code = tonumber(code) or code,
        body = not args.sink and table.concat(response_body) or nil,
        headers = headers,
        status = status,
    }
end

local function escape(str)
    return url_utils.escape(tostring(str))
end

--- Create a connector.
-- opts = { api_token=, username=, opds_token=, show_adult=, session_token= }
function UchiyomiAPI:new(base_url, opts)
    local o = setmetatable({}, self)
    opts = opts or {}
    if type(base_url) == "string" then
        o.base_url = base_url:gsub("/+$", "")
    else
        o.base_url = ""
    end
    o.api_token = opts.api_token
    o.session_token = opts.session_token
    o.username = opts.username
    o.opds_token = opts.opds_token
    o.show_adult = opts.show_adult and true or false
    return o
end

function UchiyomiAPI:isConfigured()
    return self.base_url ~= "" and ((self.api_token and self.api_token ~= "") or (self.session_token and self.session_token ~= ""))
end

function UchiyomiAPI:hasOpds()
    return self.username and self.username ~= "" and self.opds_token and self.opds_token ~= ""
end

function UchiyomiAPI:get_headers(accept)
    local headers = {
        ["Accept"] = accept or "application/json",
        ["Content-Type"] = "application/json",
        ["User-Agent"] = "kouchiyomi/KOReader",
    }
    local tok = (self.api_token and self.api_token ~= "") and self.api_token or self.session_token
    if tok and tok ~= "" then
        headers["Authorization"] = "Bearer " .. tok
    end
    return headers
end

-- Append ?adult=1 (or &adult=1) when the user opted in to 18+ libraries.
function UchiyomiAPI:withAdult(path)
    if not self.show_adult then return path end
    if path:find("%?") then return path .. "&adult=1" end
    return path .. "?adult=1"
end

--- JSON request. Returns decoded table (or true for empty 2xx), else nil, err, code.
function UchiyomiAPI:request(path, method, body, opts)
    opts = opts or {}
    local url = self.base_url .. path
    local post_data = body and JSON.encode(body) or nil
    local headers = self:get_headers()
    -- Uchiyomi rejects an empty body when a JSON content type is declared.
    if not post_data then headers["Content-Type"] = nil end
    local res, err = perform_request({
        url = url,
        method = method or "GET",
        headers = headers,
        post_data = post_data,
        timeout = opts.timeout or 15,
    })
    if not res then return nil, err end
    if res.code < 200 or res.code >= 300 then
        local msg = "Server returned status " .. tostring(res.code)
        if res.body and res.body ~= "" then
            local ok, parsed = pcall(JSON.decode, res.body)
            if ok and type(parsed) == "table" then
                if parsed.message then msg = tostring(parsed.message)
                elseif parsed.error then msg = tostring(parsed.error) end
            end
        end
        logger.warn("kouchiyomi API bad status", tostring(res.code), url, msg)
        return nil, msg, res.code
    end
    if res.code == 204 or not res.body or res.body == "" then return true end
    local ok, parsed = pcall(JSON.decode, res.body)
    if not ok then
        return nil, "JSON parsing failed: " .. tostring(parsed)
    end
    return parsed
end

--- Binary GET (images, files). Returns body string, or nil, err.
function UchiyomiAPI:request_raw(path, opts)
    opts = opts or {}
    local url = path:find("^https?://") and path or (self.base_url .. path)
    local headers = self:get_headers(opts.accept or "*/*")
    headers["Content-Type"] = nil
    local sink, file
    if opts.dest_path then
        local err
        file, err = io.open(opts.dest_path, "wb")
        if not file then return nil, "Failed to open file for writing: " .. tostring(err) end
        sink = ltn12.sink.file(file)
    end
    local res, err = perform_request({
        url = url,
        method = "GET",
        headers = headers,
        sink = sink,
        timeout = opts.timeout or 30,
        total_timeout = opts.total_timeout,
    })
    if file then pcall(file.close, file) end
    if not res then
        if opts.dest_path then os.remove(opts.dest_path) end
        return nil, err
    end
    if res.code < 200 or res.code >= 300 then
        if opts.dest_path then os.remove(opts.dest_path) end
        return nil, "Server error " .. tostring(res.code), res.code
    end
    return opts.dest_path and true or res.body
end

-- ---------------------------------------------------------------------------
-- Auth / setup
-- ---------------------------------------------------------------------------

--- Log in with username/password (+ optional TOTP). Stores a session token
-- on this connector so create_api_token() can be called next.
function UchiyomiAPI:login(username, password, totp)
    local saved = self.api_token
    self.api_token = nil
    local body = { username = username, password = password }
    if totp and totp ~= "" then
        -- The server reads the one-time code from `code` (its OpenAPI file says
        -- `totp`; send both). Spaces people type between digit groups are dropped.
        local clean = tostring(totp):gsub("%s+", "")
        body.code = clean
        body.totp = clean
    end
    local res, err, code = self:request("/auth/login", "POST", body)
    self.api_token = saved
    if not res or type(res) ~= "table" or not res.accessToken then
        if code == 429 then err = "Too many login attempts, wait a few minutes"
        elseif err == "totp_required" then err = "This account has 2FA enabled: enter the current 6-digit code"
        elseif err == "totp_invalid" or err == "Incorrect authentication code." then err = "The 2FA code was rejected; codes expire every 30 seconds, try a fresh one"
        elseif err == "invalid_credentials" then err = "Wrong username or password"
        elseif code == 423 then err = "Account temporarily locked after too many failed attempts; wait 15 minutes"
        end
        return nil, err or "Login failed"
    end
    self.session_token = res.accessToken
    self.username = username
    return res
end

--- Mint a long-lived API token (needs a session or API token). Returns the
-- secret string.
function UchiyomiAPI:create_api_token(name, show_adult, expires_in_days)
    local body = { name = name, scopes = { "read", "write" }, showAdult = show_adult and true or false }
    if expires_in_days then body.expiresInDays = expires_in_days end
    local res, err = self:request("/api/tokens", "POST", body)
    if not res or type(res) ~= "table" or not res.token then
        return nil, err or "Token creation failed"
    end
    return res.token, res.id
end

function UchiyomiAPI:get_opds_token_status()
    return self:request("/api/opds/token")
end

--- Issue (or rotate!) the account's OPDS token. Returns the secret.
function UchiyomiAPI:create_opds_token()
    local res, err = self:request("/api/opds/token", "POST")
    if not res or type(res) ~= "table" or not res.token then
        return nil, err or "OPDS token creation failed"
    end
    return res.token
end

function UchiyomiAPI:ping()
    local me, err = self:request("/auth/me")
    if not me then return false, err end
    if type(me) == "table" and me.username then self.username = me.username end
    return true, me
end

-- ---------------------------------------------------------------------------
-- Library browsing
-- ---------------------------------------------------------------------------

function UchiyomiAPI:get_libraries()
    return self:request(self:withAdult("/api/libraries"))
end

--- Paged series search.
-- condition follows Uchiyomi's (Komga-like) predicate form, e.g.
--   { libraryId = { operator = "is", value = "lib" } }
--   { readStatus = { operator = "is", value = "IN_PROGRESS" } }
-- sort is "field,dir" with field in updated|added|title|author|unread|favorites|random.
function UchiyomiAPI:search_series(query, page, size, condition, sort)
    local body = { page = page or 0, size = size or 40 }
    if query and query ~= "" then body.query = query end
    if condition then body.condition = condition end
    if sort then body.sort = sort end
    return self:request(self:withAdult("/api/series/search"), "POST", body)
end

function UchiyomiAPI:get_series(series_id)
    return self:request(self:withAdult("/api/series/" .. escape(series_id)))
end

--- Chapters of a series in reading order, paged. Each book carries readProgress.
function UchiyomiAPI:get_series_books(series_id, page, size)
    local path = "/api/series/" .. escape(series_id) .. "/books?page=" .. tostring(page or 0) .. "&size=" .. tostring(size or 40)
    return self:request(self:withAdult(path))
end

--- Every chapter of a series (loops server pages). Returns a plain array.
function UchiyomiAPI:get_all_series_books(series_id)
    local out = {}
    local page = 0
    while true do
        local res, err = self:get_series_books(series_id, page, 100)
        if not res or type(res) ~= "table" then return #out > 0 and out or nil, err end
        local content = res.content or res
        for _i, b in ipairs(content) do table.insert(out, b) end
        if res.last == nil or res.last == true or #content == 0 then break end
        page = page + 1
        if page > 200 then break end
    end
    return out
end

function UchiyomiAPI:get_book(book_id)
    return self:request(self:withAdult("/api/books/" .. escape(book_id)))
end

function UchiyomiAPI:get_book_pages(book_id)
    return self:request(self:withAdult("/api/books/" .. escape(book_id) .. "/pages"))
end

--- The chapter after this one, or nil (404) when it is the last.
function UchiyomiAPI:get_next_book(book_id)
    local res, err, code = self:request(self:withAdult("/api/books/" .. escape(book_id) .. "/next"))
    if not res then return nil, err, code end
    if type(res) == "table" and res.id then return res end
    if type(res) == "table" and type(res.next) == "table" then return res.next end
    return nil
end

-- How many chapters one page of a series' chapter list holds while looking for
-- a neighbour. Big enough that most series are one request, small enough that
-- One Piece does not pull a megabyte of JSON onto a Kobo.
local SERIES_PAGE_SIZE = 100

local function chapter_number(book)
    if type(book) ~= "table" then return nil end
    local m = book.metadata or {}
    return tonumber(m.numberSort) or tonumber(m.number) or tonumber(book.number)
end

--- The entry before `book_id` in an ordered chapter list. Returns the chapter
-- (nil when `book_id` is the first one) plus whether `book_id` was in the list
-- at all, which is what tells "there is nothing before it" from "look further".
local function preceding(list, book_id)
    local prev
    for _i, b in ipairs(list or {}) do
        if tostring(b.id) == tostring(book_id) then return prev, true end
        -- A tombstone is listed but has no pages behind it (lib/chapterCleanup),
        -- so it is not a chapter to go back to -- the server's own /next skips
        -- these the same way.
        if not b.pruned then prev = b end
    end
    return nil, false
end

--[[
    The chapter before this one: the counterpart of get_next_book.

    Uchiyomi has no /previous route -- the server implements it (`bookPrevious`
    in lib/ownedCatalog.ts) but nothing is routed to it, and the request 404s as
    an unknown route -- so this reads the series' own chapter list, which comes
    back in exactly the order adjacency is defined in there: chapter number
    ascending, then file name.

    Returns the chapter, or nil when this is the first chapter of the series,
    or nil plus an error when the question could not be answered.
--]]
function UchiyomiAPI:get_previous_book(book_id)
    local book, berr, bcode = self:get_book(book_id)
    if type(book) ~= "table" or not book.seriesId then
        return nil, berr or "chapter not found", bcode
    end
    local series_id = book.seriesId
    local number = chapter_number(book)

    local pages = {}
    local function fetch(p)
        if p < 0 then return nil end
        if pages[p] ~= nil then return pages[p] end
        local res, err, code = self:get_series_books(series_id, p, SERIES_PAGE_SIZE)
        if type(res) ~= "table" then return nil, err, code end
        local content = res.content or res
        pages[p] = content
        return content, nil, nil, res
    end

    local first, ferr, fcode, meta = fetch(0)
    if not first then return nil, ferr or "no chapter list", fcode end
    local total_pages = tonumber(meta and meta.totalPages) or 1

    -- Which page of the list our chapter is on. The list is sorted by number, so
    -- it is the last page that does not already start past us. (One request for
    -- a series that fits on one page, four for a 1,200-chapter One Piece.)
    local page = 0
    if total_pages > 1 and number then
        local lo, hi = 0, total_pages - 1
        while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            local content = fetch(mid)
            if not content or #content == 0 then break end
            local n = chapter_number(content[1])
            if n and n <= number then lo = mid else hi = mid - 1 end
        end
        page = lo
    end

    -- The page before it too: our chapter may be the first entry on its page,
    -- and then the answer is the last entry of the one before.
    local window = {}
    for _i, b in ipairs(fetch(page - 1) or {}) do table.insert(window, b) end
    for _i, b in ipairs(fetch(page) or {}) do table.insert(window, b) end
    local prev, found = preceding(window, book_id)
    if found then return prev end

    -- Not where the numbers said it would be: two files can share a chapter
    -- number (the " (2)" copies in this library do), and the tie is broken by a
    -- file name we do not have here. Rare and worth one slow walk of the series.
    local all = self:get_all_series_books(series_id)
    if type(all) ~= "table" then return nil, "chapter not found in its series" end
    prev, found = preceding(all, book_id)
    if not found then return nil, "chapter not found in its series" end
    return prev
end

function UchiyomiAPI:get_read_progress(book_id)
    local book, err = self:get_book(book_id)
    if not book then return nil, err end
    return book.readProgress or false, nil, book
end

--- Record progress. silent=true writes exactly what is given (may move
-- backwards) without touching history; otherwise the server only moves forward.
function UchiyomiAPI:put_progress(book_id, page, completed, silent)
    local body = { page = page, completed = completed and true or false }
    if silent then body.silent = true end
    return self:request("/api/books/" .. escape(book_id) .. "/progress", "PUT", body)
end

function UchiyomiAPI:get_history(limit)
    return self:request(self:withAdult("/api/history?limit=" .. tostring(limit or 50)))
end

--- Favourited series with unseen new chapters: { content = { { series=, newCount=, latestAt= } } }
function UchiyomiAPI:get_updates()
    return self:request(self:withAdult("/api/updates"))
end

--- The home screen: { onDeck = { book... }, updated = { series... }, new = { series... } }.
-- onDeck is Uchiyomi's "Keep reading" rail: per recently read series, the
-- chapter you are part-way through or, if you finished it, the next unread one.
function UchiyomiAPI:get_home()
    return self:request(self:withAdult("/api/home"))
end

function UchiyomiAPI:get_favorites()
    return self:request(self:withAdult("/api/favorites"))
end

function UchiyomiAPI:add_favorite(series_id)
    return self:request("/api/favorites", "POST", { seriesId = series_id })
end

function UchiyomiAPI:remove_favorite(series_id)
    return self:request("/api/favorites/" .. escape(series_id), "DELETE")
end

--- All of the caller's page bookmarks:
-- { content = { { book_id=, series_id=, page=, note=, created_at=, book_title=, number=, series_title= } } }
function UchiyomiAPI:get_bookmarks()
    return self:request(self:withAdult("/api/bookmarks"))
end

function UchiyomiAPI:add_bookmark(book_id, page)
    return self:request("/api/bookmarks/" .. escape(book_id) .. "/" .. tostring(page), "PUT")
end

function UchiyomiAPI:remove_bookmark(book_id, page)
    return self:request("/api/bookmarks/" .. escape(book_id) .. "/" .. tostring(page), "DELETE")
end

-- ---------------------------------------------------------------------------
-- Images & files
-- ---------------------------------------------------------------------------

function UchiyomiAPI:download_series_thumbnail(series_id)
    return self:request_raw("/api/v1/series/" .. escape(series_id) .. "/thumbnail", { accept = "image/*" })
end

function UchiyomiAPI:download_book_thumbnail(book_id)
    return self:request_raw("/api/v1/books/" .. escape(book_id) .. "/thumbnail", { accept = "image/*" })
end

--- One page image (1-based). Returns bytes.
function UchiyomiAPI:download_page(book_id, n)
    return self:request_raw("/api/v1/books/" .. escape(book_id) .. "/pages/" .. tostring(n), { accept = "image/*", timeout = 30 })
end

function UchiyomiAPI:page_url(book_id, n)
    return self.base_url .. "/api/v1/books/" .. escape(book_id) .. "/pages/" .. tostring(n)
end

--- Whole chapter as CBZ via OPDS (requires username + OPDS token).
function UchiyomiAPI:download_book_opds(book_id, dest_path)
    if not self:hasOpds() then return nil, "No OPDS token configured" end
    local url = self.base_url .. "/opds/book/" .. escape(book_id) .. "/file"
    local file, ferr = io.open(dest_path, "wb")
    if not file then return nil, "Failed to open file for writing: " .. tostring(ferr) end
    local res, err = perform_request({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "*/*",
            ["Authorization"] = "Basic " .. encode_base64(self.username .. ":" .. self.opds_token),
            ["User-Agent"] = "kouchiyomi/KOReader",
        },
        sink = ltn12.sink.file(file),
        timeout = 60,
        total_timeout = 900,
    })
    pcall(file.close, file)
    if not res then os.remove(dest_path); return nil, err end
    if res.code < 200 or res.code >= 300 then
        os.remove(dest_path)
        return nil, "Server error " .. tostring(res.code), res.code
    end
    return true
end

--- Download a chapter to dest_path. Uses OPDS when configured, otherwise
-- assembles a CBZ from the individual pages. progress_cb(done, total) optional.
function UchiyomiAPI:download_book(book_id, dest_path, progress_cb)
    if self:hasOpds() then
        local ok, err, code = self:download_book_opds(book_id, dest_path)
        if ok then return true end
        logger.warn("kouchiyomi: OPDS download failed, falling back to page assembly:", tostring(err))
        if code == 401 or code == 403 then
            -- credentials are wrong: do not hide that behind the fallback
            return nil, "OPDS token rejected (" .. tostring(code) .. "). Re-run server setup."
        end
    end
    local pages, err = self:get_book_pages(book_id)
    if type(pages) ~= "table" then return nil, err or "Could not list pages" end
    if #pages == 0 then return nil, "Chapter has no pages" end
    local Zip = require("uchi/zip")
    local zw, zerr = Zip.open(dest_path)
    if not zw then return nil, zerr end
    for i, p in ipairs(pages) do
        local n = p.number or i
        local bytes, perr = self:download_page(book_id, n)
        if not bytes then
            zw:abort()
            return nil, "Page " .. tostring(n) .. ": " .. tostring(perr)
        end
        local ext = (p.fileName and p.fileName:match("%.(%w+)$")) or "jpg"
        zw:add(string.format("%04d.%s", n, ext), bytes)
        if progress_cb then progress_cb(i, #pages) end
    end
    return zw:close()
end

return UchiyomiAPI
