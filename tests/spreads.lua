local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local S = require("uchi/spreads")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local function pages(flags)
    local out = {}
    for i, j in ipairs(flags) do out[i] = { number = i, join = j or nil } end
    return out
end
local j, n = S.joins(pages({ false, false, "rtl", false, false, false }))
check("one pair found", n == 1 and j[3] and not j[4])
j, n = S.joins(pages({ "rtl", false, false }))
check("page one can start a pair", n == 1 and j[1])
j, n = S.joins(pages({ "rtl", "rtl", false, false }))
check("a flag inside the pair before it is ignored", n == 1 and j[1] and not j[2])
j, n = S.joins(pages({ false, false, "rtl" }))
check("the last page has nothing to join", n == 0)
local ps = pages({ false, "rtl", false })
ps[3].missing = true
j, n = S.joins(ps)
check("a placeholder is never joined", n == 0)
check("no pages", select(2, S.joins(nil)) == 0 and select(2, S.joins({})) == 0)
j = S.joins(pages({ false, false, "rtl", false, false, false }))
check("forward skips the second page", S.next_shown(j, 2) == 3 and S.next_shown(j, 3) == 5 and S.next_shown(j, 5) == 6)
check("back lands on the first page", S.prev_shown(j, 5) == 3 and S.prev_shown(j, 3) == 2 and S.prev_shown(j, 6) == 5)
check("a saved position inside a pair snaps to its first page", S.snap(j, 4) == 3 and S.snap(j, 3) == 3 and S.snap(j, 5) == 5)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
