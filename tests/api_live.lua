-- Live integration test of uchi/api.lua against a running Uchiyomi.
-- Run from KOReader's install dir with its luajit:
--   UCHI_URL=... UCHI_TOKEN=uy_... UCHI_USER=... UCHI_OPDS=... ./luajit /path/to/tests/api_live.lua
require("setupkoenv")
local plugin_dir = os.getenv("KOUCHIYOMI_DIR")
package.path = plugin_dir .. "/?.lua;" .. package.path

local API = require("uchi/api")
local url = assert(os.getenv("UCHI_URL"), "UCHI_URL")
local token = assert(os.getenv("UCHI_TOKEN"), "UCHI_TOKEN")
local api = API:new(url, { api_token = token, username = os.getenv("UCHI_USER"), opds_token = os.getenv("UCHI_OPDS"), show_adult = false })

local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, extra or "") end
end

local ok, me = api:ping()
check("ping /auth/me", ok and type(me) == "table" and me.username, tostring(me))

local libs = api:get_libraries()
check("libraries", type(libs) == "table" and #libs > 0)

local res = api:search_series("blame", 0, 5)
check("search_series", type(res) == "table" and res.content and #res.content >= 1)
local series = res.content[1]

local cond = api:search_series(nil, 0, 3, { libraryId = { operator = "is", value = "lib" } }, "updated,desc")
check("search_series condition+sort", type(cond) == "table" and cond.content and #cond.content == 3, tostring(cond))

local rs = api:search_series(nil, 0, 3, { readStatus = { operator = "is", value = "IN_PROGRESS" } })
check("search_series readStatus", type(rs) == "table" and rs.content ~= nil, tostring(rs))

local s = api:get_series(series.id)
check("get_series", type(s) == "table" and s.id == series.id and s.booksCount)

local books = api:get_series_books(series.id, 0, 2)
check("get_series_books paged", type(books) == "table" and #books.content == 2 and books.totalPages > 1)
local all = api:get_all_series_books(series.id)
check("get_all_series_books", type(all) == "table" and #all == s.booksCount, tostring(all and #all) .. " vs " .. tostring(s.booksCount))

local b1 = all[1]
local book = api:get_book(b1.id)
check("get_book", type(book) == "table" and book.media and book.media.pagesCount)
local pages = api:get_book_pages(b1.id)
check("get_book_pages", type(pages) == "table" and #pages == book.media.pagesCount)
local nxt = api:get_next_book(b1.id)
check("get_next_book", type(nxt) == "table" and nxt.id == all[2].id)
local last = api:get_next_book(all[#all].id)
check("get_next_book on last -> nil", last == nil)

local progress, _, pb = api:get_read_progress(b1.id)
check("get_read_progress", pb ~= nil and (progress == false or type(progress) == "table"))

-- bookmarks round trip on a page that is unlikely to be bookmarked
local before = api:get_bookmarks()
check("get_bookmarks", type(before) == "table" and before.content)
check("add_bookmark", api:add_bookmark(b1.id, 3))
local mid = api:get_bookmarks()
local found = false
for _, bm in ipairs(mid.content) do if bm.book_id == b1.id and bm.page == 3 then found = true end end
check("bookmark visible after add", found)
check("remove_bookmark", api:remove_bookmark(b1.id, 3))
local after = api:get_bookmarks()
found = false
for _, bm in ipairs(after.content) do if bm.book_id == b1.id and bm.page == 3 then found = true end end
check("bookmark gone after remove", not found)

check("history", type(api:get_history(5)) == "table")
check("updates", type(api:get_updates()) == "table")
check("home", type(api:get_home()) == "table")
check("favorites", type(api:get_favorites()) == "table")

local thumb = api:download_series_thumbnail(series.id)
check("series thumbnail bytes", type(thumb) == "string" and #thumb > 1000)
local bthumb = api:download_book_thumbnail(b1.id)
check("book thumbnail bytes", type(bthumb) == "string" and #bthumb > 1000)
local page1 = api:download_page(b1.id, 1)
check("page 1 bytes (jpeg)", type(page1) == "string" and page1:sub(1, 2) == "\255\216", page1 and #page1)

-- silent progress write that does not change state: write back what is there
local cur = type(progress) == "table" and progress or { page = 0, completed = false }
check("put_progress silent no-op", api:put_progress(b1.id, cur.page or 0, cur.completed, true))

-- downloads: OPDS path (if configured) and page-assembly fallback
local tmp = os.getenv("TMPDIR") or "/tmp"
if api:hasOpds() then
    local ok1, err1 = api:download_book_opds(b1.id, tmp .. "/kouchi_opds.cbz")
    check("download_book_opds", ok1, tostring(err1))
end
local api_noopds = API:new(url, { api_token = token })
local n = 0
local ok2, err2 = api_noopds:download_book(b1.id, tmp .. "/kouchi_pages.cbz", function(done, total) n = done end)
check("download_book page assembly", ok2 and n == #pages, tostring(err2))

print(string.format("== %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
