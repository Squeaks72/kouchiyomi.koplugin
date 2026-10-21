--[[
    The settings tree as a sheet of its own, for the places that are not KOReader's main menu.

    `Menu:createMainMenu()` builds items for KOReader's TouchMenu: submenus are `sub_item_table_func`s resolved when a
    row is tapped, toggles are `keep_menu_open` callbacks that are handed the menu so they can redraw it, and rows are
    ticked by `checked_func`. Tools > Uchiyomi is a TouchMenu, so it all works there. The plain `ui/widget/menu.Menu`
    knows none of it -- it never calls `sub_item_table_func`, so a submenu row did nothing and then the sheet closed,
    and it closes after every leaf as well -- which is what the settings buttons in the browser and in BookOrbit's
    home screen did. They now open this instead: a one-tab TouchMenu in the same container KOReader's own menus use,
    so every row behaves exactly as it does under Tools.
--]]

local Sheet = {}

--- Show the settings. `open_index` (optional) opens that top-level row's submenu straight away.
function Sheet.open(plugin, open_index)
    if not (plugin and plugin.menu and plugin.menu.createMainMenu) then return false end
    -- With BookOrbit installed the settings are drawn in its style (uchi/ui_settings_page); that page needs the
    -- toolkit, and falls back to the plain touch menu below if it cannot be built.
    if require("uchi/ui_theme").available and plugin.settings.bookorbit_settings_style ~= false then
        local ok, opened = pcall(function() return require("uchi/ui_settings_page").open(plugin, open_index) end)
        if ok and opened then return true end
        if not ok then require("logger").warn("kouchiyomi: BookOrbit-styled settings failed:", tostring(opened)) end
    end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen

    local items = plugin.menu:createMainMenu()
    -- A tab is its icon plus the rows as its array part.
    local tab = { icon = "appbar.settings" }
    for i, item in ipairs(items) do tab[i] = item end

    local container = CenterContainer:new{ ignore = "height", dimen = Screen:getSize() }
    local menu = TouchMenu:new{
        width = Screen:getWidth(),
        last_index = 1,
        tab_item_table = { tab },
        show_parent = container,
    }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
    if open_index and items[open_index] then
        pcall(menu.onMenuSelect, menu, items[open_index])
    end
    return true
end

return Sheet
