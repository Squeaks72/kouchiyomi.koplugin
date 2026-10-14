-- Double-page spreads a source cut in two. The server compares the edges of neighbouring pages and flags the first
-- page of a pair whose picture runs across the seam (`join` on the page list); `/img/lib/books/{id}/spread/{n}` is
-- the two stitched into one wide image. KOReader's rotation (uchi/rotation) then does what it does for any wide page.
local Spreads = {}

--- The pages that start a joined pair, as a set {[n] = true}. Each pair is two consecutive pages; a flagged page
-- that would overlap the pair before it, a placeholder, or the last page is left alone.
function Spreads.joins(pages)
    local set, count = {}, 0
    if type(pages) ~= "table" then return set, 0 end
    local i = 1
    while i < #pages do
        local p, nxt = pages[i], pages[i + 1]
        if type(p) == "table" and p.join and type(nxt) == "table" and not p.missing and not nxt.missing then
            set[tonumber(p.number) or i] = true
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

return Spreads
