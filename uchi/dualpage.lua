--[[
    Two pages on a landscape screen.

    Turn the device on its side and the page you are on gets the page after it
    beside it, like an open book -- whether or not the source ever scanned them
    as a spread. (uchi/rotation turns the screen FOR a spread; this is what a
    screen that is already landscape does with ordinary pages.)

    The pairing is anchored on the page you are on and not on an odd/even rule:
    the page on screen is the first of the two, so the page you were reading
    never swaps places with the one after it, and a wrong guess at the cover is
    cured by turning back one page. Turning forward skips the two on screen;
    turning back from the first of a pair lands two pages earlier.

    A page that is already wide (a spread) is never paired -- it has the screen
    to itself, and so does the page before it.

    Everything KOReader-specific is required inside a function, so the rules can
    be read (and tested) on a plain Lua.
--]]

local Rotation = require("uchi/rotation")

local Dual = {}

--- Is a page of this width/height ratio a spread on its own? (nil = unknown)
function Dual.isWide(aspect)
    if aspect == nil then return nil end
    return aspect >= Rotation.WIDE_PAGE_RATIO
end

--[[
    How many pages are on screen when the reader is on `page`.

    `wide(p)` answers whether page p is a spread (nil = it will not say). A page
    the document cannot describe is shown alone: guessing there would pair a
    page with something that may not be a page at all.
--]]
function Dual.span(page, count, wide)
    if not page or not count or page >= count then return 1 end
    local a, b = wide(page), wide(page + 1)
    if a == nil or b == nil or a or b then return 1 end
    return 2
end

--- The page to land on turning forward. Past the last page it is count + 1,
-- which is exactly the number that makes KOReader announce the end of the book.
function Dual.forwardTarget(page, count, wide)
    return page + Dual.span(page, count, wide)
end

--[[
    The page to land on turning back, or nil on the first page (the caller then
    leaves the turn to KOReader, which is what opens the previous chapter).

    `came_from` is the screen the reader turned forward from to get here, when
    that is known and still makes sense: it is the only thing that retraces a
    path exactly, because where a pair begins depends on where the reading
    began (pairs 1-2, 3-4 ... or 2-3, 4-5 ...) and the page number alone cannot
    say. Without it this guesses -- a pair two back, or just the page behind if
    that one stands alone -- and what it guarantees is only that the page right
    behind the reader is on the screen it lands on.
--]]
function Dual.backTarget(page, wide, came_from)
    if not page or page <= 1 then return nil end
    if came_from and came_from < page then return came_from end
    if page == 2 then return 1 end
    if wide(page - 1) == true then return page - 1 end
    if wide(page - 2) == true then return page - 1 end
    return page - 2
end

--[[
    One zoom for both pages, so they read as one printed spread: as large as
    lets the pair fit the area side by side. `a` and `b` are {w=,h=} at zoom 1.
--]]
function Dual.zoom(avail_w, avail_h, a, b)
    local w = (a.w or 0) + (b.w or 0)
    local h = math.max(a.h or 0, b.h or 0)
    if w <= 0 or h <= 0 or avail_w <= 0 or avail_h <= 0 then return nil end
    return math.min(avail_w / w, avail_h / h)
end

--[[
    Where the two pages go, left then right, as {x=,y=} for each. The pair is
    one block, touching at the gutter and centred in the area; each page is
    centred up and down on its own.
--]]
function Dual.place(avail_w, avail_h, left, right)
    local block = left.w + right.w
    local x0 = math.floor((avail_w - block) / 2)
    return {
        x = x0,
        y = math.floor((avail_h - left.h) / 2),
    }, {
        x = x0 + left.w,
        y = math.floor((avail_h - right.h) / 2),
    }
end

--- Is the screen on its side right now?
function Dual.isLandscape()
    local ok, Screen = pcall(function() return require("device").screen end)
    if not ok or not Screen then return false end
    return Screen:getWidth() > Screen:getHeight()
end

local function wide_fn(doc)
    return function(p) return Dual.isWide(Rotation.pageAspect(doc, p)) end
end

--[[
    Is the two-page view in force for the open document?

    Landscape, page mode (a webtoon read as one long strip has no pages to pair),
    a document that is actually a set of pages, and a screen that is on its side
    because the reader put it there: when uchi/rotation turned it for a spread
    (`rotation_base` is set) the next single page turns it back, and pairing
    would fight that.
--]]
function Dual.enabled(plugin)
    if not plugin or not plugin.settings then return false end
    if plugin.settings.dual_page_landscape == false then return false end
    if not (plugin.is_active and plugin.current_book_id) then return false end
    local ui = plugin.ui
    if not (ui and ui.paging and ui.document and ui.view and ui.view.state) then return false end
    if ui.view.page_scroll then return false end
    if (ui.view.state.rotation or 0) ~= 0 then return false end
    if plugin.rotation_base ~= nil then return false end
    return Dual.isLandscape()
end

--- How many pages are on screen for this plugin's document right now (1 when
-- the two-page view is off or the page stands alone).
function Dual.shown(plugin, page)
    if not Dual.enabled(plugin) then return 1 end
    local doc = plugin.ui.document
    page = page or plugin.ui.view.state.page
    local count = doc.getPageCount and doc:getPageCount()
    return Dual.span(page, count, wide_fn(doc))
end

--- Pages beyond the first on screen: what "have I seen the last page?" has to add.
function Dual.extraPages(plugin)
    local ok, n = pcall(Dual.shown, plugin)
    return ok and n and (n - 1) or 0
end

--[[
    Paint the current page and the one after it. Returns true when it did; false
    leaves the reader's own single-page drawing to run.

    The geometry is ReaderView's own where it can be: page areas come from
    `view:getPageArea`, so a page cropped to its content stays cropped here.
--]]
function Dual.draw(plugin, view, bb, x, y)
    if not Dual.enabled(plugin) then return false end
    local doc = plugin.ui.document
    local page = view.state.page
    if not page or Dual.shown(plugin, page) < 2 then return false end

    local Geom = require("ui/geometry")
    local first, second = page, page + 1
    if view.inverse_reading_order then first, second = second, first end -- right to left: the later page is on the left

    local area_w, area_h = view.dimen.w, view.dimen.h
    if view.footer_visible and view.footer and view.footer.settings and not view.footer.settings.reclaim_height then
        area_h = area_h - view.footer:getHeight()
    end

    local a1, b1 = view:getPageArea(first, 1, 0), view:getPageArea(second, 1, 0)
    local zoom = Dual.zoom(area_w, area_h, a1, b1)
    if not zoom then return false end
    local a, b = view:getPageArea(first, zoom, 0), view:getPageArea(second, zoom, 0)
    if a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0 then return false end

    local pa, pb = Dual.place(area_w, area_h, a, b)
    bb:paintRect(x, y, view.dimen.w, view.dimen.h, view.outer_page_color)
    local function paint(p, area, at)
        doc:drawPage(bb, x + at.x, y + at.y,
            Geom:new{ x = area.x, y = area.y, w = area.w, h = area.h },
            p, zoom, 0, view.state.gamma, view.state.saturation)
    end
    paint(first, a, pa)
    paint(second, b, pb)
    return true
end

--- The setting changed: redraw what is on screen the way the new setting wants it.
function Dual.refresh(plugin)
    pcall(function() require("uchi/stream").refreshCurrent() end)
    local ui = plugin and plugin.ui
    if ui and ui.paging and ui.view and ui.view.dialog then
        require("ui/uimanager"):setDirty(ui.view.dialog, "partial")
    end
end

--[[
    Wrap the reader so it paints two pages and turns two at a time. Called once
    per document; each wrapper asks `Dual.enabled` every time, so switching
    the setting or the screen's orientation needs nothing re-installed.
--]]
function Dual.install(plugin, ui)
    if not ui or not ui.paging or not ui.view then return end
    local view, module = ui.view, ui.paging
    if not view._kouchiyomi_dual_hooked then
        view._kouchiyomi_dual_hooked = true
        local orig_draw = view.drawSinglePage
        view.drawSinglePage = function(this, bb, x, y, ...)
            local ok, painted = pcall(Dual.draw, plugin, this, bb, x, y)
            if ok and painted then return end
            if not ok then require("logger").warn("kouchiyomi: two-page draw failed:", tostring(painted)) end
            return orig_draw(this, bb, x, y, ...)
        end
    end
    if not module._kouchiyomi_dual_turn_hooked and type(module.onGotoViewRel) == "function" then
        module._kouchiyomi_dual_turn_hooked = true
        local orig = module.onGotoViewRel
        module.onGotoViewRel = function(this, diff, no_page_turn, ...)
            -- ReaderSearch asking "would this turn a page?" is not a reader turning one,
            -- and only a single step forward or back is a page turn in the first place.
            if no_page_turn ~= true and (diff == 1 or diff == -1) and Dual.enabled(plugin) then
                local ok, handled = pcall(Dual.turn, plugin, this, diff)
                if ok and handled then return true end
                if not ok then require("logger").warn("kouchiyomi: two-page turn failed:", tostring(handled)) end
            end
            return orig(this, diff, no_page_turn, ...)
        end
    end
end

--[[
    A page turn in the two-page view. Returns true when handled; false hands the
    turn back to KOReader, which is right for the one case it must still own:
    turning back from the first page (the previous chapter).
--]]
function Dual.turn(plugin, module, diff)
    local doc = plugin.ui.document
    local page = module.current_page
    local count = module.number_of_pages
    if not (page and count) then return false end
    local wide = wide_fn(doc)
    -- Where each screen was reached from, so turning back retraces the way forward went.
    local trail = plugin.dual_trail
    if not trail then trail = {}; plugin.dual_trail = trail end
    if diff > 0 then
        local target = Dual.forwardTarget(page, count, wide)
        if target > count then
            plugin.ui:handleEvent(require("ui/event"):new("EndOfBook"))
        else
            trail[target] = page
            module:_gotoPage(target)
        end
    else
        local from = trail[page]
        -- Only while it still describes this screen: pages may have been read one at a time since.
        if from and Dual.forwardTarget(from, count, wide) ~= page then from = nil end
        local target = Dual.backTarget(page, wide, from)
        if not target then return false end
        module:_gotoPage(target)
    end
    module:setPagePosition(module:getTopPage(), module:getTopPosition())
    return true
end

return Dual
