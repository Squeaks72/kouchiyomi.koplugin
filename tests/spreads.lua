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
j = S.joins(pages({ "rtl", false, "ltr", false }))
check("the side the next page is on is kept", j[1] == "rtl" and j[3] == "ltr")
j = S.joins({ { number = 1, join = true }, { number = 2 } })
check("a flag with no side still joins", j[1] == true)
check("rtl puts the second page on the left", S.left_first("rtl") == false and S.left_first("ltr") == true and S.left_first(true) == true)
local w, h, wl, wr = S.layout(700, 1000, 700, 1000)
check("equal pages: twice the width", w == 1400 and h == 1000 and wl == 700 and wr == 700)
w, h, wl, wr = S.layout(700, 1000, 690, 980)
check("a pair a little apart takes the taller height", h == 1000 and wl == 700 and wr == 704 and w == 1404, w .. "x" .. h .. " " .. wl .. "+" .. wr)
check("a null or junk join flag is no join", select(2, S.joins({ { number = 1, join = {} }, { number = 2 }, { number = 3, join = "no" }, { number = 4 } })) == 0)
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
