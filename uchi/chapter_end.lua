--[[
    The one "chapter finished" dialog, shared by the downloaded-file and the
    streaming paths: the next chapter's cover when it is cached, what was
    just finished, what comes next and in which state, and the actions the
    caller passes in.
--]]

local UIManager = require("ui/uimanager")
local Labels = require("uchi/labels")
local Cache = require("uchi/cache")

local ChapterEnd = {}

--- opts = {
--    plugin       = the plugin,
--    current      = book-like table of the finished chapter (nil = unknown),
--    series_title = series title when `current` has none,
--    next_book    = book-like table of the next chapter (nil when none/unknown),
--    state        = "ready" | "downloading" | "missing" | "last" | "unknown",
--    note         = optional extra line ("Offline.", an error...),
--    buttons      = ButtonDialog rows; the caller closes the returned dialog,
-- }
-- Returns the dialog, already shown.
function ChapterEnd.show(opts)
    local plugin = opts.plugin
    local _ = plugin.i18n._
    local T = plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local series = opts.series_title
        or (opts.current and opts.current.seriesTitle)
        or (opts.next_book and opts.next_book.seriesTitle) or ""

    local lines = {}
    if opts.current then
        table.insert(lines, T(_("Finished: %1"), Labels.display(opts.current, true, series)))
    else
        table.insert(lines, _("Chapter finished"))
    end
    local state_text = {
        ready = _("ready on this device"),
        downloading = _("downloading in the background"),
        missing = _("not on this device"),
    }
    if opts.state == "last" then
        table.insert(lines, _("This was the last chapter on the server."))
    elseif opts.state == "unknown" or not opts.next_book then
        table.insert(lines, _("Next chapter: unknown without the server"))
    else
        table.insert(lines, T(_("Next: %1 (%2)"), Labels.chapter(opts.next_book), state_text[opts.state] or tostring(opts.state)))
        local sub = Labels.subtitle(opts.next_book, series)
        if sub then table.insert(lines, sub) end
    end
    if opts.note and opts.note ~= "" then table.insert(lines, opts.note) end

    local dialog = ButtonDialog:new{ title = table.concat(lines, "\n"), buttons = opts.buttons }

    -- Cover of the next chapter, else of the series, when one is cached.
    pcall(function()
        if plugin.settings.show_covers == false then return end
        local cover
        if opts.next_book and opts.next_book.id then cover = Cache.existingCoverPath("book", opts.next_book.id) end
        local sid = (opts.next_book and opts.next_book.seriesId) or (opts.current and opts.current.seriesId)
        if not cover and sid then cover = Cache.existingCoverPath("series", sid) end
        if not cover then return end
        local ImageWidget = require("ui/widget/imagewidget")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local Screen = require("device").screen
        local w = dialog:getAddedWidgetAvailableWidth()
        local h = math.floor(Screen:getHeight() * 0.22)
        if not w or w <= 0 then return end
        local img = ImageWidget:new{ file = cover, width = w, height = h, scale_factor = 0, file_do_cache = false }
        dialog:addWidget(CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, img })
    end)

    UIManager:show(dialog)
    return dialog
end

return ChapterEnd
