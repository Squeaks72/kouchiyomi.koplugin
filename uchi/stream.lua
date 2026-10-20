--[[
    Streaming reader: shows a chapter page by page straight from the server,
    without downloading a file. Built on KOReader's ImageViewer (the same
    widget the OPDS plugin uses for OPDS-PSE streaming), with:
      * resume from the server's reading position
      * progress pushed to Uchiyomi as you turn pages (debounced) and on close
      * the next page prefetched in the background
      * turning past the last page marks the chapter read on Uchiyomi and
        offers the next chapter (also offered when the viewer is closed on
        the last page)

    Bookmarks are not available while streaming: ImageViewer is not a
    document, so KOReader has nothing to attach them to. Download the chapter
    for the full experience.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local ImageViewer = require("ui/widget/imageviewer")
local RenderImage = require("ui/renderimage")
local Labels = require("uchi/labels")
local ChapterEnd = require("uchi/chapter_end")
local Spreads = require("uchi/spreads")
local Dual = require("uchi/dualpage")

local Stream = {}

-- The viewer on screen, if any. On the class, not an instance: the rotation event arrives at whichever
-- plugin instance the UI it was sent to owns, which need not be the one that opened the viewer.
Stream.current_viewer = nil

function Stream:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

local StreamViewer = ImageViewer:extend{
    stream = nil,      -- Stream instance
    book = nil,
    book_id = nil,
    page_count = 0,
    _last_pushed = 0,
}

function StreamViewer:switchToImageNum(n)
    ImageViewer.switchToImageNum(self, n)
    if self.stream then self.stream:onPageShown(self, n) end
end

-- ImageViewer silently ignores "next" on the last image; that is the end of
-- the chapter for us.
function StreamViewer:onShowNextImage()
    -- A screen may stand for two pages (a joined spread, or a landscape pair): turning forward skips the lot.
    local st = self.st
    local to = self._images_list_cur + ((st and st.consumed[self._images_list_cur]) or 1)
    if to > self._images_list_nb then
        if self.stream then self.stream:onEndReached(self) end
        return true
    end
    if st then st.trail[to] = self._images_list_cur end
    self:switchToImageNum(to)
    return true
end

-- The same at the other end: ImageViewer ignores "previous" on the first
-- image, and that is the start of the chapter for us.
function StreamViewer:onShowPrevImage()
    if self._images_list_cur <= 1 then
        if self.stream then self.stream:onStartReached(self) end
        return true
    end
    self:switchToImageNum(Stream.backTarget(self.st, self._images_list_cur, self.stream and self.stream:_dualOn()))
    return true
end

--- The screen turned, or the two-page setting changed: a landscape screen shows two pages where a portrait one
-- shows one, and ImageViewer cannot be told its screen changed.
function StreamViewer:refreshScreen()
    if self.stream then self.stream:rebuild(self) end
end

function StreamViewer:onClose()
    if self.stream then self.stream:onViewerClose(self) end
    return ImageViewer.onClose(self)
end

--- Fetch and decode page n (1-based) as a blitbuffer, with a small cache.
function Stream:_pageBB(book_id, n, cache, joins)
    if cache[n] then
        local bb = cache[n]
        cache[n] = nil
        return bb
    end
    local data
    if joins and joins[n] then data = self.plugin.api:download_spread(book_id, n, joins[n]) end
    if not (type(data) == "string" and #data > 0) then data = self.plugin.api:download_page(book_id, n) end
    if type(data) == "string" and #data > 0 then
        local bb = RenderImage:renderImageData(data, #data, false)
        if bb then return bb end
    end
    logger.warn("kouchiyomi: could not fetch page", n)
    return RenderImage:renderImageFile("resources/koreader.png", false)
end

--- Is the two-page view on for the screen as it is now?
function Stream:_dualOn()
    return self.plugin.settings.dual_page_landscape ~= false and Dual.isLandscape()
end

local function aspect_of(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    if w <= 0 or h <= 0 then return nil end
    return w / h
end

--- Two pages as one image, side by side. `rtl` puts the first page on the right. Both inputs are consumed.
function Stream.compose(first, second, rtl)
    local Blitbuffer = require("ffi/blitbuffer")
    local left, right = first, second
    if rtl then left, right = second, first end
    local w = left:getWidth() + right:getWidth()
    local h = math.max(left:getHeight(), right:getHeight())
    local kind = left:getType() == right:getType() and left:getType() or Blitbuffer.TYPE_BBRGB32
    local out = Blitbuffer.new(w, h, kind)
    out:fill(Blitbuffer.COLOR_WHITE)
    out:blitFrom(left, 0, math.floor((h - left:getHeight()) / 2), 0, 0, left:getWidth(), left:getHeight())
    out:blitFrom(right, left:getWidth(), math.floor((h - right:getHeight()) / 2), 0, 0, right:getWidth(), right:getHeight())
    left:free()
    right:free()
    return out
end

--- Which page the reader lands on turning back from `cur`. A joined spread two back is one screen starting
-- there; otherwise a landscape screen goes back over the pair it came forward over.
function Stream.backTarget(st, cur, dual)
    if cur <= 1 then return 1 end
    local joins = st and st.joins
    if joins and cur > 2 and joins[cur - 2] then return cur - 2 end
    if not dual then return cur - 1 end
    local wide = st and st.wide or {}
    -- Retrace the way forward went while that still holds (a screen is reached from the one before it).
    local from = st and st.trail[cur]
    if from and ((st.consumed[from] or 1) + from ~= cur or from >= cur) then from = nil end
    return Dual.backTarget(cur, function(p) return wide[p] or (joins and joins[p]) or nil end, from) or 1
end

--[[
    The image for the screen that starts at page n: that page alone, or in a landscape it with the page after it
    beside it. Records in `st` how many pages the screen covers (`consumed`) -- turning forward needs it -- and
    which pages turned out to be wide, which turning back needs.

    A page that is wide stands alone, and so does the one before it; a joined spread is already one wide image.
--]]
function Stream:_screenBB(st, n)
    local joins = st.joins
    if not self:_dualOn() or n >= st.count or (joins and (joins[n] or joins[n + 1])) then
        st.consumed[n] = (joins and joins[n]) and 2 or 1
        return self:_pageBB(st.book_id, n, st.cache, joins)
    end
    local a = self:_pageBB(st.book_id, n, st.cache, joins)
    st.wide[n] = Dual.isWide(aspect_of(a)) or false
    if st.wide[n] then
        st.consumed[n] = 1
        return a
    end
    local b = self:_pageBB(st.book_id, n + 1, st.cache, joins)
    st.wide[n + 1] = Dual.isWide(aspect_of(b)) or false
    if st.wide[n + 1] then
        -- Its own screen next: keep what was fetched so it is not fetched twice.
        st.cache[n + 1] = b
        st.consumed[n] = 1
        return a
    end
    st.consumed[n] = 2
    return Stream.compose(a, b, st.rtl)
end

function Stream:_prefetch(viewer, n, n2)
    local want = { [n] = true, [n2 or n] = true }
    viewer._want = want
    if n < 1 or n > viewer.page_count then return end
    if viewer._prefetching then return end
    viewer._prefetching = true
    UIManager:scheduleIn(0.2, function()
        viewer._prefetching = false
        if viewer._closed then return end
        -- keep the cache tiny; the reader only ever needs the next screen's pages
        for k, old in pairs(viewer._cache) do
            if not viewer._want[k] then
                if old.free then old:free() end
                viewer._cache[k] = nil
            end
        end
        for p in pairs(viewer._want) do
            if p >= 1 and p <= viewer.page_count and not viewer._cache[p] then
                local data
                if viewer.joins and viewer.joins[p] then data = self.plugin.api:download_spread(viewer.book_id, p, viewer.joins[p]) end
                if not (type(data) == "string" and #data > 0) then data = self.plugin.api:download_page(viewer.book_id, p) end
                if type(data) == "string" and #data > 0 then
                    local bb = RenderImage:renderImageData(data, #data, false)
                    if bb then viewer._cache[p] = bb end
                end
            end
        end
    end)
end

function Stream:onPageShown(viewer, n, no_push)
    local st = viewer.st
    local nxt = n + ((st and st.consumed[n]) or 1)
    -- On a landscape screen the screen after this one is two pages.
    self:_prefetch(viewer, nxt, self:_dualOn() and nxt + 1 <= viewer.page_count and nxt + 1 or nil)
    if not no_push then self:_schedulePush(viewer, n) end
end

function Stream:_schedulePush(viewer, n)
    viewer._pending_page = n
    if viewer._push_fn then UIManager:unschedule(viewer._push_fn) end
    viewer._push_fn = function()
        viewer._push_fn = nil
        self:_push(viewer, viewer._pending_page)
    end
    UIManager:scheduleIn(2, viewer._push_fn)
end

function Stream:_push(viewer, n)
    if not n or not self.plugin.api or not self.plugin.settings.sync_progress then return end
    if n == viewer._last_pushed then return end
    -- the last screen can be a joined or landscape pair, whose first page is not the last page
    local completed = n + ((viewer.st and viewer.st.consumed[n]) or 1) > viewer.page_count
    local ok, err = self.plugin.api:put_progress(viewer.book_id, n, completed, false)
    if ok then
        viewer._last_pushed = n
    else
        logger.warn("kouchiyomi: stream progress push failed:", tostring(err))
        self.plugin.sync:bufferOfflineProgress(viewer.book_id, n, viewer.page_count, completed)
    end
end

--- The reader tried to turn past the last page: the chapter is finished.
-- Push completion right away (no debounce) and offer the next chapter while
-- the viewer stays open underneath.
function Stream:onEndReached(viewer)
    if viewer._end_prompted then return end
    viewer._end_prompted = true
    if viewer._push_fn then UIManager:unschedule(viewer._push_fn); viewer._push_fn = nil end
    self:_push(viewer, viewer.page_count)
    self:promptNext(viewer.book, viewer)
end

--- The reader turned back past the first page: go to the previous chapter,
-- at its last page. Nothing is marked, nothing is finished; this is only
-- reading backwards across a chapter break.
function Stream:onStartReached(viewer)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if viewer._start_busy then return end
    viewer._start_busy = true
    UIManager:nextTick(function() viewer._start_busy = false end)
    if self.plugin.settings.prev_chapter_on_first_page == false then return end
    if not self.plugin.api or not viewer.book then return end
    local sync = self.plugin.sync
    local lfs = require("libs/libkoreader-lfs")

    local prev = sync:knownPreviousChapter(viewer.book_id)
    if not prev then
        local InfoMessage = require("ui/widget/infomessage")
        local msg = InfoMessage:new{ text = _("Looking for the previous chapter...") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local found, err = self.plugin.api:get_previous_book(viewer.book_id)
        UIManager:close(msg)
        if not found then
            self.plugin:notify(err and T(_("Could not fetch the previous chapter: %1"), tostring(err))
                or _("This is the first chapter of the series."), err and "error" or "info")
            return
        end
        prev = found
        sync:cachePreviousChapter(viewer.book_id, found)
    end

    -- A downloaded copy reads better than a streamed one; otherwise stream it,
    -- starting at its last page (Stream:open clamps to the real page count).
    local path = sync:getBookLocalPath(prev, prev.seriesTitle)
    if path and lfs.attributes(path, "mode") == "file" then
        local Sync = require("uchi/sync")
        Sync.pending_goto_last = true
        if not viewer._closed then viewer:onClose() end
        UIManager:nextTick(function()
            require("apps/filemanager/filemanagerutil").openFile(self.plugin.ui, path)
        end)
        return
    end
    if not viewer._closed then viewer:onClose() end
    UIManager:nextTick(function()
        self:open(prev, (prev.media and tonumber(prev.media.pagesCount)) or 99999)
    end)
end

function Stream:onViewerClose(viewer)
    viewer._closed = true
    if Stream.current_viewer == viewer then Stream.current_viewer = nil end
    -- The sleep screen goes back to the reader's own as the chapter leaves it.
    pcall(function() require("uchi/sleepscreen").disarm(self.plugin) end)
    if viewer._push_fn then UIManager:unschedule(viewer._push_fn); viewer._push_fn = nil end
    local n = viewer._images_list_cur or 1
    self:_push(viewer, n)
    for k, bb in pairs(viewer._cache or {}) do
        if bb.free then pcall(bb.free, bb) end
        viewer._cache[k] = nil
    end
    if n + ((viewer.st and viewer.st.consumed[n]) or 1) > viewer.page_count and viewer.page_count > 0
        and not viewer._end_prompted then
        UIManager:nextTick(function() self:promptNext(viewer.book) end)
    end
end

--- The chapter-end dialog for a streamed chapter. `viewer` is the open
-- StreamViewer, if any; it is closed before another chapter opens.
function Stream:promptNext(book, viewer)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not self.plugin.api then return end
    local sync = self.plugin.sync
    local lfs = require("libs/libkoreader-lfs")
    local nxt, err, code = sync:cacheNextChapterFor(book.id)
    local state, note, local_path
    if nxt then
        local_path = sync:getBookLocalPath(nxt, nxt.seriesTitle)
        if local_path and lfs.attributes(local_path, "mode") == "file" then
            state = "ready"
        elseif sync:isDownloading(nxt.id) then
            state = "downloading"
        else
            state = "missing"
        end
        pcall(function() self.plugin.cache:cacheThumbnail("book", nxt.id, nxt.artVersion) end)
    elseif code == 404 or code == nil then
        state = "last"
    else
        state = "unknown"
        note = T(_("Uchiyomi did not answer (%1)."), tostring(err))
    end

    local dialog
    local function close() if dialog then UIManager:close(dialog) end end
    local function leave_viewer()
        if viewer and not viewer._closed then viewer:onClose() end
    end
    local function open_file(path)
        UIManager:nextTick(function()
            require("apps/filemanager/filemanagerutil").openFile(self.plugin.ui, path)
        end)
    end
    local function stream_next()
        close()
        leave_viewer()
        UIManager:nextTick(function() self:open(nxt) end)
    end

    -- Auto-advance: keep going without asking when the next chapter is at hand.
    -- A gap in the numbering is said, never driven through: the dialog names it.
    local gap = nxt and require("uchi/gap").between(book, nxt)
    if self.plugin.settings.auto_advance ~= false and nxt and not gap then
        if state == "ready" then
            leave_viewer()
            open_file(local_path)
            return
        elseif state == "downloading" then
            leave_viewer()
            sync:openWhenReady(nxt, local_path, open_file)
            return
        elseif state == "missing" then
            stream_next()
            return
        end
    end

    local buttons = {}
    if state == "ready" then
        table.insert(buttons, { { text = _("Open next chapter"), is_enter_default = true,
            callback = function() close(); leave_viewer(); open_file(local_path) end } })
        table.insert(buttons, { { text = _("Stream next chapter"), callback = stream_next } })
    elseif state == "downloading" then
        table.insert(buttons, { { text = _("Stream next chapter"), is_enter_default = true, callback = stream_next } })
        table.insert(buttons, { { text = _("Open when downloaded"),
            callback = function() close(); leave_viewer(); sync:openWhenReady(nxt, local_path, open_file) end } })
    elseif state == "missing" then
        table.insert(buttons, { { text = _("Stream next chapter"), is_enter_default = true, callback = stream_next } })
        table.insert(buttons, { { text = _("Download next chapter"),
            callback = function() close(); leave_viewer(); sync:downloadBook(nxt, nxt.seriesTitle, open_file) end } })
    elseif state == "unknown" then
        table.insert(buttons, { { text = _("Try again"), is_enter_default = true,
            callback = function() close(); self:promptNext(book, viewer) end } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function()
        close()
        -- Stay on the last page; asking again later is fine.
        if viewer then viewer._end_prompted = false end
    end } })

    dialog = ChapterEnd.show{
        plugin = self.plugin, current = book, next_book = nxt, state = state, note = note, buttons = buttons,
    }
end

--- Open a chapter for streaming. start_page overrides the server position.
function Stream:open(book, start_page)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not self.plugin.api then
        self.plugin:notify(_("Uchiyomi is not configured."), "error")
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        NetworkMgr:runWhenOnline(function() self:open(book, start_page) end)
        return
    end
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = T(_("Opening %1..."), Labels.display(book, true)) }
    UIManager:show(msg)
    UIManager:forceRePaint()

    -- Before a page is on screen: an 18+ chapter must not be able to reach the
    -- sleep screen, and that has to be arranged in advance (uchi/sleepscreen).
    pcall(function() require("uchi/sleepscreen").forBook(self.plugin, book) end)

    local count = book.media and tonumber(book.media.pagesCount) or 0
    local progress = book.readProgress
    local fresh, _err, fresh_book = self.plugin.api:get_read_progress(book.id)
    if fresh_book then
        progress = fresh
        count = (fresh_book.media and tonumber(fresh_book.media.pagesCount)) or count
        book = fresh_book
    end
    local joins
    if count == 0 or self.plugin.api:joinsSpreads() then
        local pages = self.plugin.api:get_book_pages(book.id, { spreads = self.plugin.api:joinsSpreads() })
        if type(pages) == "table" then
            if count == 0 then count = #pages end
            if self.plugin.api:joinsSpreads() then
                local set, n = Spreads.joins(pages)
                if n > 0 then joins = set end
            end
        end
    end
    UIManager:close(msg)
    if count == 0 then
        self.plugin:notify(_("This chapter has no pages on the server."), "error")
        return
    end

    local start = start_page
    if not start and type(progress) == "table" then
        local p = tonumber(progress.page) or 0
        if progress.completed then
            start = 1
        elseif p > 1 and p < count then
            start = p
        end
    end
    start = math.max(1, math.min(start or 1, count))
    if joins then start = Spreads.snap(joins, start) end

    -- What the screens built so far covered. A screen is a page, a joined spread, or a landscape pair, so
    -- turning needs to know how far each one reached; `wide` is what turning back needs.
    local st = {
        book_id = book.id, count = count, cache = {}, joins = joins,
        consumed = {}, wide = {}, trail = {},
        rtl = self.plugin:wantInverseReadingOrder() == true,
    }
    local viewer = self:_show(book, st, start)
    self:onPageShown(viewer, start)
end

--- Put a viewer on screen at page `start`, built from the state `st` (which outlives any one viewer).
function Stream:_show(book, st, start)
    local page_table = { image_disposable = true }
    local stream = self
    -- ImageViewer asks for image 1 while it is built; the page the reader is on is what it should get.
    st.first = start
    setmetatable(page_table, { __index = function(_, key)
        if type(key) ~= "number" then return RenderImage:renderImageFile("resources/koreader.png", false) end
        if key == 1 and st.first then key = st.first; st.first = nil end
        return stream:_screenBB(st, key)
    end })
    local viewer = StreamViewer:new{
        stream = self,
        book = book,
        book_id = book.id,
        page_count = st.count,
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false,
        images_list_nb = st.count,
        _cache = st.cache,
        joins = st.joins,
        st = st,
    }
    st.first = nil
    viewer._images_list_cur = start
    viewer:update()
    Stream.current_viewer = viewer
    UIManager:show(viewer)
    return viewer
end

--[[
    Build the viewer again for the page it is on, over the same state. ImageViewer fixes its layout when it is
    made, so a screen that has turned (and with it how many pages one screen holds) is a new viewer rather
    than an old one patched; pages already fetched are kept.
--]]
function Stream:rebuild(old)
    if old._closed then return end
    local n = old._images_list_cur
    if old._push_fn then UIManager:unschedule(old._push_fn); old._push_fn = nil end
    local viewer = self:_show(old.book, old.st, n)
    viewer._last_pushed = old._last_pushed
    viewer._end_prompted = old._end_prompted
    -- Closed straight through the UIManager: the viewer's own close is the reader leaving the chapter.
    old._closed = true
    UIManager:close(old)
    self:onPageShown(viewer, n)
end

--- The screen turned (the plugin hears every rotation). The viewer redraws once the new orientation is in
-- place: the event is heard before the screen has actually turned.
function Stream.onRotation()
    local viewer = Stream.current_viewer
    if not viewer or viewer._closed then return end
    if viewer._rotate_fn then UIManager:unschedule(viewer._rotate_fn) end
    viewer._rotate_fn = function()
        viewer._rotate_fn = nil
        if viewer._closed then return end
        local ok, err = pcall(viewer.refreshScreen, viewer)
        if not ok then logger.warn("kouchiyomi: stream rotate failed:", tostring(err)) end
    end
    UIManager:scheduleIn(0.25, viewer._rotate_fn)
end

--- The setting changed: redraw what is on screen.
function Stream.refreshCurrent()
    local viewer = Stream.current_viewer
    if viewer and not viewer._closed then pcall(viewer.refreshScreen, viewer) end
end

return Stream
