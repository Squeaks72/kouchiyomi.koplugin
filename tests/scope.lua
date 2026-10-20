local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local S = require("uchi/scope")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local function ser(id, title, lib, latest) return { id = id, libraryId = lib, metadata = { title = title }, latestChapterAt = latest } end
local items = { ser("a", "Berserk", "m", "2026-01-02"), ser("b", "Akira", "m", "2026-03-01"), ser("c", "Bleach", "w", "2026-02-01"), ser("d", "akame", "w", nil) }
local function ids(l) local t = {} for _, s in ipairs(l) do t[#t + 1] = s.id end return table.concat(t) end
check("no filter keeps all", #S.filter(items) == 4)
check("library filter", ids(S.filter(items, { library_id = "w" })) == "cd")
check("search is a case-insensitive substring", ids(S.filter(items, { query = "AK" })) == "bd")
check("library and search together", ids(S.filter(items, { library_id = "m", query = "ser" })) == "a")
check("title ascending", ids(S.sort(items, "title,asc")) == "dbac", ids(S.sort(items, "title,asc")))
check("title descending", ids(S.sort(items, "title,desc")) == "cabd")
check("updated newest first, undated last", ids(S.sort(items, "updated,desc")) == "bcad", ids(S.sort(items, "updated,desc")))
check("unknown sort keeps list order", ids(S.sort(items, "random")) == "abcd" and ids(S.sort(items, nil)) == "abcd")
check("sort does not touch the original", ids(items) == "abcd")
local p = S.page(items, 0, 3)
check("first page", #p.content == 3 and p.totalPages == 2 and p.totalElements == 4 and p.last == false)
p = S.page(items, 1, 3)
check("last page", #p.content == 1 and p.last == true and p.content[1].id == "d")
p = S.page({}, 0, 40)
check("empty list is one empty page", #p.content == 0 and p.totalPages == 1 and p.last == true)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
