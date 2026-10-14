--[[
    Whole chapter numbers that lie between a finished chapter and the next one
    the server names -- the ones the reader is about to skip over.
--]]

local Gap = {}

local function number_of(book)
    if type(book) ~= "table" then return nil end
    local m = book.metadata or {}
    return tonumber(m.numberSort) or tonumber(m.number) or tonumber(book.number)
end

--- { first =, last = } for the missing whole numbers, or nil when there are
-- none, either number is unknown, or the order does not run forward (a copy
-- of the same number, a special placed out of order).
function Gap.between(current, next_book)
    local a, b = number_of(current), number_of(next_book)
    if not a or not b or b <= a then return nil end
    local first, last = math.floor(a) + 1, math.ceil(b) - 1
    if first > last then return nil end
    return { first = first, last = last, next = b }
end

local function fmt(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return tostring(n)
end

--- The warning line, or nil. `_` is the plugin's gettext, `T` its formatter.
function Gap.text(current, next_book, _, T)
    local g = Gap.between(current, next_book)
    if not g then return nil end
    if g.first == g.last then
        return T(_("Chapter %1 is missing here. This continues at chapter %2."), fmt(g.first), fmt(g.next))
    end
    return T(_("Chapters %1-%2 are missing here. This continues at chapter %3."), fmt(g.first), fmt(g.last), fmt(g.next))
end

return Gap
