local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local Gap = require("uchi/gap")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local function ch(n) return { metadata = { number = tostring(n) } } end
local g = Gap.between(ch(43), ch(100))
check("43 to 100 skips 44-99", g and g.first == 44 and g.last == 99)
g = Gap.between(ch(100), ch(102))
check("one chapter skipped", g and g.first == 101 and g.last == 101)
check("next number is no gap", Gap.between(ch(43), ch(44)) == nil)
check("half chapter is no gap", Gap.between(ch(10), ch(10.5)) == nil)
check("same number is no gap", Gap.between(ch(5), ch(5)) == nil)
check("backwards is no gap", Gap.between(ch(9), ch(3)) == nil)
check("unknown number cannot say", Gap.between({}, ch(3)) == nil and Gap.between(ch(3), nil) == nil)
local _ = function(s) return s end
local T = function(s, ...) local a = {...}; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end
check("range text", Gap.text(ch(43), ch(100), _, T) == "Chapters 44-99 are missing here. This continues at chapter 100.")
check("single text", Gap.text(ch(100), ch(102), _, T) == "Chapter 101 is missing here. This continues at chapter 102.")
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
