--[[
    Settings > Reading > Tap zones, as a BookOrbit-styled page with a picture of the zones.

    Two cards, one per reading style (right-to-left manga, left-to-right), each with a drawing of the screen showing
    where a tap goes forward ("Next") and where it goes back ("Back") under the current choice, and a segmented
    control for which side the next page is on. Under them, how much of the screen turns forward. Every choice
    redraws the pictures at once and is applied to the open chapter (uchi/tapzones). Only usable when
    uchi/ui_theme's Theme.available is true; without BookOrbit the same settings are plain radio rows
    (Menu:tapZonesMenu).
--]]

local UIManager = require("ui/uimanager")

local Theme = require("uchi/ui_theme")
local Tap = require("uchi/tapzones")

local Page = {}

local SIDES = { "auto", "left", "right" }

local function indexOf(list, value, fallback)
    for i, v in ipairs(list) do if v == value then return i end end
    return fallback
end

--- The picture: a screen with its zones painted from the same numbers KOReader will use.
local function device(dw, dh, forward, backward)
    local BoardUI, INK, px = Theme.UI, Theme.INK, Theme.px
    local text, hstack, vstack, flex = BoardUI.text, BoardUI.hstack, BoardUI.vstack, BoardUI.flex
    local b = math.max(2, px(2))
    local iw, ih = dw - 2 * b, dh - 2 * b
    local layers = {}
    local function paint(zone, role)
        local x = math.floor(zone.ratio_x * iw + 0.5)
        local zw = math.max(1, math.floor(zone.ratio_w * iw + 0.5))
        if x + zw > iw then zw = iw - x end
        local next_zone = role == "next"
        local label = text(next_zone and "Next" or "Back", {
            s = zw > px(70) and 16 or 12, b = true, col = next_zone and INK.white or INK.black,
        })
        local body = hstack({ w = zw, h = ih }, { flex(0), label, flex(0) })
        layers[#layers + 1] = {
            widget = BoardUI.box({ w = zw, h = ih, bg = next_zone and INK.black or INK.gc }, body),
            x = x, y = 0,
        }
    end
    paint(backward, "back")
    paint(forward, "next")
    -- a hairline where the zones meet, so the edge reads even where black meets grey
    return BoardUI.box({ w = dw, h = dh, border = b, radius = px(10), border_col = INK.black, bg = INK.white },
        BoardUI.overlay(iw, ih, layers))
end

local function styleCard(page, w, rtl)
    local MenuUI, BoardUI, INK, px = Theme.MenuUI, Theme.UI, Theme.INK, Theme.px
    local text, vstack, space = BoardUI.text, BoardUI.vstack, BoardUI.space
    local settings = page.plugin.settings
    local key = rtl and "tap_next_side_rtl" or "tap_next_side_ltr"
    local pad = px(MenuUI.CARD_PAD)
    local iw = w - 2 * pad
    local forward, backward = Tap.zones(settings, rtl)
    local dh = math.min(px(210), math.floor(iw * 0.78))
    local dw = math.floor(dh * 0.74)
    local picture = BoardUI.hstack({ w = iw, h = dh }, { BoardUI.flex(0), device(dw, dh, forward, backward), BoardUI.flex(0) })
    local selected = indexOf(SIDES, settings[key] or "auto", 1)
    local seg = MenuUI.segmented(iw, { page.plugin.i18n._("Natural"), page.plugin.i18n._("Left"), page.plugin.i18n._("Right") }, selected,
        function(index) return { kind = "side", key = key, value = SIDES[index] } end)
    local side = Tap.side(settings, rtl)
    local _ = page.plugin.i18n._
    local summary = side == "left" and _("Next page: tap the left") or _("Next page: tap the right")
    return MenuUI.card(w, {
        vstack({ w = iw, pad = { px(14), 0, px(14), 0 } }, {
            text(rtl and _("Right to left") or _("Left to right"), { s = 17, b = true, w = iw }),
            text(rtl and _("Manga") or _("Western comics, most webtoons"), { s = 13, col = INK.g4, w = iw, data = true }),
            space(nil, px(12)),
            picture,
            space(nil, px(10)),
            text(summary, { s = 14, b = true, w = iw, align = "center" }),
            space(nil, px(12)),
            seg,
        }),
    })
end

local function build(page, sw, sh)
    local MenuUI, BoardUI, INK, px = Theme.MenuUI, Theme.UI, Theme.INK, Theme.px
    local text, vstack, hstack, space, icon = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.space, BoardUI.icon
    local _ = page.plugin.i18n._
    local settings = page.plugin.settings
    local mx = MenuUI.mx()
    local cw = sw - 2 * mx
    local w = math.min(cw, px(900))
    local side = mx + math.floor((cw - w) / 2)

    local items = {
        MenuUI.pageHeader(w, _("Tap zones"), { sub = _("Reading") }),
        space(nil, px(6)),
        text(_("Choose which side of the screen turns the page forward. The pictures show where a tap lands."),
            { s = 14, col = INK.g4, lines = 2, w = w, data = true }),
        space(nil, px(12)),
    }
    local gap = px(14)
    if w >= px(560) then
        local col = math.floor((w - gap) / 2)
        items[#items + 1] = hstack({ w = w, gap = gap, valign = "top" }, { styleCard(page, col, true), styleCard(page, col, false) })
    else
        items[#items + 1] = styleCard(page, w, true)
        items[#items + 1] = space(nil, gap)
        items[#items + 1] = styleCard(page, w, false)
    end
    items[#items + 1] = space(nil, px(18))

    -- width
    local widths = { false }
    local labels = { _("Default") }
    for _i, v in ipairs(Tap.WIDTHS) do
        widths[#widths + 1] = v
        labels[#labels + 1] = string.format("%d%%", math.floor(v * 100 + 0.5))
    end
    local current = tonumber(settings.tap_next_width)
    local selected = 1
    for i, v in ipairs(widths) do if v and current and math.abs(v - current) < 1e-6 then selected = i end end
    local pad = px(MenuUI.CARD_PAD)
    local iw = w - 2 * pad
    items[#items + 1] = MenuUI.card(w, {
        vstack({ w = iw, pad = { px(14), 0, px(14), 0 } }, {
            text(_("Next-page zone width"), { s = 17, b = true, w = iw }),
            text(current and string.format(_("%d%% of the screen turns forward, the rest turns back."), math.floor(current * 100 + 0.5))
                or _("Default: KOReader's own sizes, about three quarters forward."), { s = 13, col = INK.g4, w = iw, data = true }),
            space(nil, px(12)),
            MenuUI.segmented(iw, labels, selected, function(index) return { kind = "width", value = widths[index] or false } end),
        }),
    })
    items[#items + 1] = space(nil, px(14))
    local note_w = w - 2 * pad - px(32)
    items[#items + 1] = MenuUI.card(w, {
        hstack({ w = w - 2 * pad, gap = px(12), valign = "top" }, {
            vstack({}, { space(nil, px(12)), icon("info", px(20), { sw = 2 }) }),
            vstack({ w = note_w, pad = { px(12), 0, px(12), 0 } }, {
                text(_("Streaming keeps a middle third that shows or hides its buttons until you choose a width. Downloaded chapters use KOReader's own zones, so everything else about them is unchanged."),
                    { s = 13, col = INK.g4, lines = 4, w = note_w, data = true, bg = INK.ge }),
            }),
        }),
    }, { fill = true })

    page.panel_rect = require("ui/geometry"):new{ x = 0, y = 0, w = sw, h = sh }
    return vstack({ w = sw, h = sh, pad = { px(6), side, px(12), side } }, items)
end

local function onAction(page, action)
    local settings = page.plugin.settings
    if action.kind == "side" then
        settings[action.key] = action.value
    elseif action.kind == "width" then
        settings.tap_next_width = action.value or nil
    else
        return true
    end
    page.plugin:saveSettings()
    Tap.refresh(page.plugin)
    page:refresh()
    return true
end

function Page.open(plugin)
    if not (Theme.available and plugin) then return false end
    local page = Theme.MenuPage:new{ name = "kouchiyomi_tapzones", build = build, on_action = onAction, plugin = plugin }
    UIManager:show(page, "ui")
    return true
end

return Page
