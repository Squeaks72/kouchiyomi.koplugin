-- Test driver run inside the real KOReader (userpatch, priority "late").
local UIManager = require("ui/uimanager")
local logger = require("logger")
local results = { pass = 0, fail = 0 }
local function check(name, cond, extra)
    if cond then results.pass = results.pass + 1; logger.warn("KTEST PASS", name)
    else results.fail = results.fail + 1; logger.warn("KTEST FAIL", name, tostring(extra)) end
end
local function step(delay, fn)
    UIManager:scheduleIn(delay, function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("KTEST ERROR", tostring(err)); results.fail = results.fail + 1 end
    end)
end
local function paint() UIManager:forceRePaint() end

local ctx = {}
step(5, function()
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.kouchiyomi
    check("plugin registered on FileManager", plugin ~= nil)
    check("api configured", plugin and plugin.api and plugin.api:isConfigured())
    ctx.plugin = plugin
    -- settings menu builders
    local menu = plugin.menu:createMainMenu()
    check("main menu built", type(menu) == "table" and #menu >= 6)
    for _, name in ipairs({ "serverMenu", "readingMenu", "syncMenu", "downloadsMenu", "layoutMenu" }) do
        local t = plugin.menu[name](plugin.menu)
        check("submenu " .. name, type(t) == "table" and #t > 0)
    end
    -- browser
    local Browser = require("uchi/browser")
    local browser = Browser:new{ plugin = plugin }
    ctx.browser = browser
    UIManager:show(browser); paint()
    check("browser home items", #browser.item_table >= 8)
    browser:showAllSeries("title,asc", "All series"); paint()
    check("all series list", browser.item_table[1] and browser.item_table[1].series ~= nil, browser.item_table[1] and browser.item_table[1].text)
    browser:setViewMode("grid"); paint()
    check("grid mode", browser.view_mode == "grid")
    browser:setViewMode("list"); paint()
    local series
    for _, it in ipairs(browser.item_table) do if it.series and it.series.name == "BLAME!" then series = it.series end end
    if not series then series = browser.item_table[1].series end
    ctx.series = series
    browser:showBooksInSeries(series); paint()
    check("chapter list", browser.item_table[1] and browser.item_table[1].book ~= nil)
    ctx.books = {}
    for _, it in ipairs(browser.item_table) do if it.book then table.insert(ctx.books, it.book) end end
    browser:showFilterDialog(series, nil); paint()
    browser:onReturn(); paint()
    browser:showKeepReading(); paint(); check("keep reading view", browser.catalog_title ~= nil); browser:onReturn()
    browser:showBookmarks(); paint(); browser:onReturn()
    browser:showUpdates(); paint(); browser:onReturn()
    browser:showFavorites(); paint(); check("favourites view", browser.item_table[1] ~= nil); browser:onReturn()
    browser:showLibraries(); paint(); check("libraries view", browser.item_table[1] and browser.item_table[1].text); browser:onReturn()
    browser:showOfflineLibrary(); paint(); browser:onReturn()
    browser:onMenuHold(browser.item_table[1]); paint()  -- series hold dialog on the current (all series) view
    browser:onHoldReturn(); paint()
    check("browser navigation survived", #browser.paths == 0)
    UIManager:close(browser); paint()
end)

step(12, function()
    local plugin = ctx.plugin
    -- download the smallest chapter of the chosen series (last chapter) and open it
    local all = plugin.api:get_all_series_books(ctx.series.id)
    local book = all[#all]
    ctx.book = book
    -- reset test state on the server
    plugin.api:put_progress(book.id, 0, false, true)
    for _, bm in ipairs(plugin.api:get_bookmarks().content) do if bm.book_id == book.id then plugin.api:remove_bookmark(book.id, bm.page) end end
    plugin.sync:downloadBook(book, book.seriesTitle, function(path)
        check("download succeeded", path ~= nil, path)
        ctx.path = path
        local FileManager = require("apps/filemanager/filemanager")
        require("apps/filemanager/filemanagerutil").openFile(FileManager.instance, path)
    end, function(err) check("download succeeded", false, err) end, ctx.series)
end)

step(40, function()
    local ReaderUI = require("apps/reader/readerui")
    local rui = ReaderUI.instance
    check("reader opened downloaded chapter", rui ~= nil and rui.document and rui.document.file == ctx.path, rui and rui.document and rui.document.file)
    local rplugin = rui and rui.kouchiyomi
    check("plugin active in reader", rplugin and rplugin.is_active and rplugin.current_book_id == ctx.book.id, rplugin and tostring(rplugin.current_book_id))
    ctx.rui, ctx.rplugin = rui, rplugin
    paint()
    -- user bookmarks page 3 -> server
    rui.bookmark:toggleBookmark(3)
    local found = false
    for _, bm in ipairs(rplugin.api:get_bookmarks().content) do if bm.book_id == ctx.book.id and bm.page == 3 then found = true end end
    check("bookmark pushed to server", found)
    -- server adds page 6 -> local, via manual sync
    rplugin.api:add_bookmark(ctx.book.id, 6)
    rplugin.bookmarks:syncOpenDocument(rui, false)
    check("server bookmark pulled locally", rui.bookmark:isPageBookmarked(6))
    -- user removes page 3 -> server
    rui.bookmark:toggleBookmark(3)
    found = false
    for _, bm in ipairs(rplugin.api:get_bookmarks().content) do if bm.book_id == ctx.book.id and bm.page == 3 then found = true end end
    check("bookmark removal pushed", not found)
    -- progress: go to page 5 and push
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new("GotoPage", 5))
end)

step(46, function()
    local rui, rplugin = ctx.rui, ctx.rplugin
    rplugin.sync:pushProgressForDocument(rui)
    local prog = rplugin.api:get_read_progress(ctx.book.id)
    check("progress pushed (page 5)", type(prog) == "table" and prog.page == 5, prog and prog.page)
    -- server moves ahead to page 8 -> pull jumps (sync_forward = silent)
    rplugin.api:put_progress(ctx.book.id, 8, false, true)
    rplugin.sync:pullProgress(rui, false)
end)

step(50, function()
    local rui = ctx.rui
    check("pull jumped to server page", rui.view.state.page == 8, rui.view.state.page)
    rui:onClose()
end)

step(56, function()
    local plugin = ctx.plugin
    local FileManager = require("apps/filemanager/filemanager")
    check("back in file manager", FileManager.instance ~= nil)
    -- streaming reader
    plugin.stream:open(ctx.book, 2); paint()
    local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
    ctx.viewer = top
    check("stream viewer shown", top ~= nil and top.book_id == ctx.book.id, top and tostring(top.name))
    if top and top.switchToImageNum then top:switchToImageNum(3); paint(); top:onShowNextImage(); paint() end
end)

step(62, function()
    local v = ctx.viewer
    if v and v.onClose then v:onClose() end
    local prog = ctx.plugin.api:get_read_progress(ctx.book.id)
    check("stream progress pushed (page 4)", type(prog) == "table" and prog.page == 4, prog and prog.page)
    -- offline reconcile path
    local n = ctx.plugin.sync:reconcileDownloaded(false)
    check("reconcileDownloaded ran", type(n) == "number")
    -- cleanup server state
    ctx.plugin.api:put_progress(ctx.book.id, 0, false, true)
    for _, bm in ipairs(ctx.plugin.api:get_bookmarks().content) do if bm.book_id == ctx.book.id then ctx.plugin.api:remove_bookmark(ctx.book.id, bm.page) end end
    logger.warn(string.format("KTEST SUMMARY %d passed, %d failed", results.pass, results.fail))
    UIManager:quit()
end)
