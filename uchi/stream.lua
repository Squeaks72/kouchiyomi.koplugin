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
local ImageViewer = require("ui/widget/imageviewer")
local RenderImage = require("ui/renderimage")

local Stream = {}

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
    if self._images_list_cur >= self._images_list_nb then
        if self.stream then self.stream:onEndReached(self) end
        return true
    end
    return ImageViewer.onShowNextImage(self)
end

function StreamViewer:onClose()
    if self.stream then self.stream:onViewerClose(self) end
    return ImageViewer.onClose(self)
end

--- Fetch and decode page n (1-based) as a blitbuffer, with a small cache.
function Stream:_pageBB(book_id, n, cache)
    if cache[n] then
        local bb = cache[n]
        cache[n] = nil
        return bb
    end
    local data = self.plugin.api:download_page(book_id, n)
    if type(data) == "string" and #data > 0 then
        local bb = RenderImage:renderImageData(data, #data, false)
        if bb then return bb end
    end
    logger.warn("kouchiyomi: could not fetch page", n)
    return RenderImage:renderImageFile("resources/koreader.png", false)
end

function Stream:_prefetch(viewer, n)
    if n < 1 or n > viewer.page_count then return end
    if viewer._cache[n] or viewer._prefetching then return end
    viewer._prefetching = true
    UIManager:scheduleIn(0.2, function()
        viewer._prefetching = false
        if viewer._closed or viewer._cache[n] then return end
        local data = self.plugin.api:download_page(viewer.book_id, n)
        if type(data) == "string" and #data > 0 then
            local bb = RenderImage:renderImageData(data, #data, false)
            if bb then
                -- keep the cache tiny; the reader only ever needs the next page
                for k, old in pairs(viewer._cache) do
                    if k ~= n and old.free then old:free() end
                    viewer._cache[k] = nil
                end
                viewer._cache[n] = bb
            end
        end
    end)
end

function Stream:onPageShown(viewer, n)
    self:_prefetch(viewer, n + 1)
    self:_schedulePush(viewer, n)
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
    local completed = n >= viewer.page_count
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

function Stream:onViewerClose(viewer)
    viewer._closed = true
    if viewer._push_fn then UIManager:unschedule(viewer._push_fn); viewer._push_fn = nil end
    local n = viewer._images_list_cur or 1
    self:_push(viewer, n)
    for k, bb in pairs(viewer._cache or {}) do
        if bb.free then pcall(bb.free, bb) end
        viewer._cache[k] = nil
    end
    if n >= viewer.page_count and viewer.page_count > 0 and not viewer._end_prompted then
        UIManager:nextTick(function() self:promptNext(viewer.book) end)
    end
end

--- Offer the chapter after `book`. `viewer` is the open StreamViewer, if
-- any; it is closed before another chapter opens.
function Stream:promptNext(book, viewer)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not self.plugin.api then return end
    local nxt, err, code = self.plugin.api:get_next_book(book.id)
    if not nxt then
        if code == 404 or code == nil then
            self.plugin:notify(_("Chapter marked read. This was the last chapter on the server."), "info")
        else
            self.plugin:notify(T(_("Chapter marked read. Could not fetch the next chapter: %1"), tostring(err)), "error")
        end
        if viewer then viewer._end_prompted = false end
        return
    end
    self.plugin.sync:cacheNextChapter(book.id, nxt)
    local title = (nxt.metadata and nxt.metadata.title) or nxt.name or ""
    local local_path = self.plugin.sync:getBookLocalPath(nxt, nxt.seriesTitle)
    local lfs = require("libs/libkoreader-lfs")
    local downloaded = local_path and lfs.attributes(local_path, "mode") == "file"
    local function leave_viewer()
        if viewer and not viewer._closed then viewer:onClose() end
    end
    local function open_file(path)
        UIManager:nextTick(function()
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            filemanagerutil.openFile(self.plugin.ui, path)
        end)
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    if downloaded then
        table.insert(buttons, { { text = _("Open next chapter"), is_enter_default = true, callback = function()
            UIManager:close(dialog)
            leave_viewer()
            open_file(local_path)
        end } })
    end
    table.insert(buttons, { { text = _("Stream next chapter"), is_enter_default = not downloaded, callback = function()
        UIManager:close(dialog)
        leave_viewer()
        UIManager:nextTick(function() self:open(nxt) end)
    end } })
    if not downloaded then
        table.insert(buttons, { { text = _("Download next chapter"), callback = function()
            UIManager:close(dialog)
            leave_viewer()
            self.plugin.sync:downloadBook(nxt, nxt.seriesTitle, open_file)
        end } })
    end
    table.insert(buttons, { { text = _("Close"), callback = function()
        UIManager:close(dialog)
        -- Stay on the last page; asking again later is fine.
        if viewer then viewer._end_prompted = false end
    end } })
    dialog = ButtonDialog:new{
        title = downloaded and T(_("Chapter marked read.\nNext chapter is ready: %1"), title)
            or T(_("Chapter marked read.\nNext chapter: %1"), title),
        buttons = buttons,
    }
    UIManager:show(dialog)
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
    local msg = InfoMessage:new{ text = T(_("Opening %1..."), (book.metadata and book.metadata.title) or book.name or "") }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local count = book.media and tonumber(book.media.pagesCount) or 0
    local progress = book.readProgress
    local fresh, _err, fresh_book = self.plugin.api:get_read_progress(book.id)
    if fresh_book then
        progress = fresh
        count = (fresh_book.media and tonumber(fresh_book.media.pagesCount)) or count
        book = fresh_book
    end
    if count == 0 then
        local pages = self.plugin.api:get_book_pages(book.id)
        if type(pages) == "table" then count = #pages end
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

    local cache = {}
    local page_table = { image_disposable = true }
    local stream = self
    local viewer
    setmetatable(page_table, { __index = function(_, key)
        if type(key) ~= "number" then return RenderImage:renderImageFile("resources/koreader.png", false) end
        return stream:_pageBB(book.id, key, cache)
    end })

    viewer = StreamViewer:new{
        stream = self,
        book = book,
        book_id = book.id,
        page_count = count,
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false,
        images_list_nb = count,
        _cache = cache,
    }
    UIManager:show(viewer)
    if start > 1 then
        viewer:switchToImageNum(start)
    else
        self:onPageShown(viewer, 1)
    end
end

return Stream
