local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local History = require("uchi/history")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local ours = { ["/k/A/c3.cbz"] = 1, ["/k/A/c2.cbz"] = 1, ["/k/A/c1.cbz"] = 1, ["/k/B/c9.cbz"] = 1, ["/k/B/c8.cbz"] = 1 }
local function is_ours(p) return ours[p] ~= nil end
local hist = {
    { file = "/k/A/c2.cbz" }, { file = "/books/novel.epub" }, { file = "/k/B/c9.cbz" },
    { file = "/k/A/c3.cbz" }, { file = "/books/other.epub" }, { file = "/k/B/c8.cbz" }, { file = "/k/A/c1.cbz" },
}
local d = History.redundant(hist, is_ours)
check("newest chapter of each series stays", table.concat(d, ",") == "4,6,7", table.concat(d, ","))
check("other books never dropped", not (function() for _, i in ipairs(d) do if hist[i].file:find("/books/") then return true end end end)())
check("one chapter per series: nothing to drop", #History.redundant({ { file = "/k/A/c1.cbz" } }, is_ours) == 0)
check("empty / nil history", #History.redundant({}, is_ours) == 0 and #History.redundant(nil, is_ours) == 0)
check("not ours: same folder untouched", #History.redundant({ { file = "/x/a.cbz" }, { file = "/x/b.cbz" } }, is_ours) == 0)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
