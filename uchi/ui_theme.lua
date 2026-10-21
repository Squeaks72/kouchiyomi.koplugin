--[[
    Bridge to BookOrbit's UI toolkit (bookorbit.koplugin), an optional visual
    enhancement: when BookOrbit is installed, kouchiyomi's browser/chapter
    list is drawn with its primitives, type scale and ink palette instead of
    stock KOReader widgets. Every require here goes through pcall, and
    Theme.available is the single flag every caller checks before touching
    any of these modules, so kouchiyomi works exactly as before -- plainer,
    never broken -- on a device that does not have BookOrbit installed.
--]]

local Theme = {}

local function tryRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end

local Metrics = tryRequire("bookorbit_board_metrics")
local UI = tryRequire("bookorbit_board_ui")
local MenuPage = tryRequire("bookorbit_menu_page")
local MenuUI = tryRequire("bookorbit_menu_ui")
local DialogUI = tryRequire("bookorbit_dialog_ui")
local BToast = tryRequire("bookorbit_toast")

Theme.available = Metrics ~= nil and UI ~= nil and MenuPage ~= nil and MenuUI ~= nil and DialogUI ~= nil and BToast ~= nil

Theme.Metrics = Metrics
Theme.UI = UI
Theme.MenuPage = MenuPage
Theme.MenuUI = MenuUI
Theme.DialogUI = DialogUI
Theme.Toast = BToast

-- Re-exported only when available; callers must not touch these unless
-- Theme.available is true.
Theme.INK = Metrics and Metrics.INK or nil
Theme.px = Metrics and Metrics.px or nil
Theme.lh1 = Metrics and Metrics.lh1 or nil
Theme.lh = Metrics and Metrics.lh or nil

return Theme
