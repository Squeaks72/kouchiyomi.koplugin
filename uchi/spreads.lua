-- Double-page spreads a source cut in two. The server compares the edges of neighbouring pages and flags the first
-- page of a pair whose picture runs across the seam (`join` on the page list, asked for with `?spreads=1`: 'rtl' when
-- the page after it sits on the LEFT, 'ltr' when on the right). Uchiyomi does not stitch the pair itself -- its own
-- reader lays the two pages side by side -- so `Spreads.stitch` does it here, into the one wide image KOReader's rotation
-- (uchi/rotation) then treats like any other wide page.
local Spreads = {}

--- The pages that start a joined pair, as a set {[n] = "rtl" | "ltr"} (true when the server named no side). Each pair is two consecutive pages; a flagged page
-- that would overlap the pair before it, a placeholder, or the last page is left alone.
function Spreads.joins(pages)
    local set, count = {}, 0
    if type(pages) ~= "table" then return set, 0 end
    local i = 1
    while i < #pages do
        local p, nxt = pages[i], pages[i + 1]
        local side = type(p) == "table" and (p.join == "rtl" or p.join == "ltr" or p.join == true) and p.join or nil
        if side and type(nxt) == "table" and not p.missing and not nxt.missing then
            set[tonumber(p.number) or i] = side
            count = count + 1
            i = i + 2
        else
            i = i + 1
        end
    end
    return set, count
end

--- The page shown after `n` when turning forward: a joined pair is one screen, so its second page is skipped.
function Spreads.next_shown(joins, n)
    return joins[n] and n + 2 or n + 1
end

--- The page shown before `n` when turning back: lands on the first page of a pair, never on its hidden second.
function Spreads.prev_shown(joins, n)
    if joins[n - 2] then return n - 2 end
    return n - 1
end

--- A page number from outside (a saved position) as one that can be shown: the second page of a pair is its first.
function Spreads.snap(joins, n)
    if joins[n - 1] then return n - 1 end
    return n
end

--- Which of the pair goes on the left: 'rtl' puts the second page there, anything else the first.
function Spreads.left_first(dir)
    return dir ~= "rtl"
end

--- The size of the stitched image and the scale each half is drawn at: both halves take the height of the taller, so a
-- pair a pixel or two apart in size still lines up along the seam. Returns total_w, h, wa, wb (widths as drawn).
function Spreads.layout(wa, ha, wb, hb)
    local h = math.max(ha, hb)
    local sa, sb = h / ha, h / hb
    local dwa, dwb = math.floor(wa * sa + 0.5), math.floor(wb * sb + 0.5)
    return dwa + dwb, h, dwa, dwb
end

--- Two page images (raw bytes, the page and the one after it) as one wide image. Returns bytes, extension; nil, reason
-- when a page cannot be decoded. Needs KOReader, so it is required lazily and the pure parts above stay testable.
function Spreads.stitch(first_bytes, second_bytes, dir)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    local BB = ok and select(2, pcall(require, "ffi/blitbuffer")) or nil
    if not ok or type(BB) ~= "table" then return nil, "no image support" end
    local a = RenderImage:renderImageData(first_bytes, #first_bytes, false)
    local b = a and RenderImage:renderImageData(second_bytes, #second_bytes, false)
    local function free(...) for _i, x in ipairs({ ... }) do if x and x.free then pcall(x.free, x) end end end
    if not (a and b) then free(a, b); return nil, "page would not decode" end
    local left, right = a, b
    if not Spreads.left_first(dir) then left, right = b, a end
    local total_w, h, wl, wr = Spreads.layout(left:getWidth(), left:getHeight(), right:getWidth(), right:getHeight())
    local out = BB.new(total_w, h, a:getType())
    out:fill(BB.COLOR_WHITE)
    local function put(src, x, w)
        local drawn = src
        if src:getWidth() ~= w or src:getHeight() ~= h then
            drawn = RenderImage:scaleBlitBuffer(src, w, h, false)
        end
        out:blitFrom(drawn, x, 0, 0, 0, w, h)
        if drawn ~= src then free(drawn) end
    end
    put(left, 0, wl)
    put(right, wl, wr)
    free(a, b)
    local DataStorage = require("datastorage")
    local base = DataStorage:getDataDir() .. "/cache/kouchiyomi-spread-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
    local bytes, ext
    for _i, fmt in ipairs({ "jpg", "png" }) do
        local path = base .. "." .. fmt
        local wrote = pcall(out.writeToFile, out, path, fmt, 90)
        local f = wrote and io.open(path, "rb")
        if f then bytes = f:read("*a"); f:close() end
        os.remove(path)
        if bytes and #bytes > 0 then ext = fmt; break end
        bytes = nil
    end
    free(out)
    if not bytes then return nil, "could not encode" end
    return bytes, ext
end

return Spreads
