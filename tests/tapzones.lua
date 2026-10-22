local plugin_dir = os.getenv("KOUCHIYOMI_DIR") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path
local T = require("uchi/tapzones")
local pass, fail = 0, 0
local function check(name, cond, extra)
    if cond then pass = pass + 1; print("PASS", name) else fail = fail + 1; print("FAIL", name, tostring(extra)) end
end
local near = function(a, b) return math.abs(a - b) < 1e-9 end
check("natural: rtl is left, ltr is right", T.side({}, true) == "left" and T.side({}, false) == "right")
check("auto is natural", T.side({ tap_next_side_rtl = "auto" }, true) == "left")
check("rtl can be put on the right", T.side({ tap_next_side_rtl = "right" }, true) == "right")
check("ltr can be put on the left", T.side({ tap_next_side_ltr = "left" }, false) == "left")
check("styles are independent", T.side({ tap_next_side_rtl = "right" }, false) == "right" and T.side({ tap_next_side_ltr = "left" }, true) == "left")
check("nothing chosen is not customised", not T.customised({}, true) and not T.customised({ tap_next_side_rtl = "auto" }, true))
check("a side makes it customised, for that style only", T.customised({ tap_next_side_rtl = "right" }, true) and not T.customised({ tap_next_side_rtl = "right" }, false))
check("a width customises both", T.customised({ tap_next_width = 0.5 }, true) and T.customised({ tap_next_width = 0.5 }, false))
local f, b = T.zones({ tap_next_side_rtl = "right" }, true)
check("rtl, next on the right: 3/4 on the right", near(f.ratio_x, 0.25) and near(f.ratio_w, 0.75) and near(b.ratio_x, 0) and near(b.ratio_w, 0.25))
f, b = T.zones({}, true)
check("rtl natural: next on the left", near(f.ratio_x, 0) and near(f.ratio_w, 0.75) and near(b.ratio_x, 0.75) and near(b.ratio_w, 0.25))
f, b = T.zones({ tap_next_width = 0.5 }, false)
check("half and half, ltr", near(f.ratio_x, 0.5) and near(f.ratio_w, 0.5) and near(b.ratio_x, 0) and near(b.ratio_w, 0.5))
f, b = T.zones({ tap_next_width = 5 }, false)
check("a silly width is clamped", near(f.ratio_w, 0.9))
check("zones cover the whole width", near(f.ratio_w + b.ratio_w, 1))
check("stream default: thirds, rtl follows the direction", T.streamTarget({}, true, 0.1) == "next" and T.streamTarget({}, true, 0.9) == "prev" and T.streamTarget({}, true, 0.5) == "middle")
check("stream default: thirds, ltr", T.streamTarget({}, false, 0.1) == "prev" and T.streamTarget({}, false, 0.9) == "next" and T.streamTarget({}, false, 0.5) == "middle")
check("stream: manga with next on the right (right hand)", T.streamTarget({ tap_next_side_rtl = "right" }, true, 0.9) == "next" and T.streamTarget({ tap_next_side_rtl = "right" }, true, 0.1) == "prev")
check("stream: a width gives the whole screen to two zones", T.streamTarget({ tap_next_width = 0.66 }, false, 0.5) == "next" and T.streamTarget({ tap_next_width = 0.66 }, false, 0.2) == "prev" and T.streamTarget({ tap_next_width = 0.66 }, false, 0.34) == "next")
-- the wrapper
local view = { inverse_reading_order = true }
view.getTapZones = function() return "kf", "kb" end
view.setupTouchZones = function(v) v.set_up = (v.set_up or 0) + 1 end
local plugin = { current_book_id = "b", settings = {} }
T.install(plugin, { view = view })
local a, c = view:getTapZones()
check("hook: nothing chosen returns KOReader's own zones", a == "kf" and c == "kb")
check("hook: zones registered again through it", view.set_up == 1)
plugin.settings.tap_next_side_rtl = "right"
a, c = view:getTapZones()
check("hook: a choice is used", type(a) == "table" and near(a.ratio_x, 0.25))
view.inverse_reading_order = false
a, c = view:getTapZones()
check("hook: the other style is untouched", a == "kf")
plugin.current_book_id = nil
view.inverse_reading_order = true
check("hook: not an Uchiyomi chapter, not touched", view:getTapZones() == "kf")
check("hook is installed once", (function() T.install(plugin, { view = view }); return view.set_up == 1 end)())
print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
