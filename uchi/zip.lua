--[[
    Minimal ZIP (store-only) writer, used to assemble a CBZ from page images
    when whole-file download over OPDS is not available.

    Pure Lua + LuaJIT bit ops. Store method (no compression) is exactly what
    image archives want anyway.
--]]

local bit = require("bit")

local Zip = {}
Zip.__index = Zip

-- CRC32 (IEEE) lookup table, built lazily.
local crc_table
local function build_crc_table()
    crc_table = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i] = c
    end
end

local function crc32(data)
    if not crc_table then build_crc_table() end
    local c = 0xFFFFFFFF
    local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
    local tbl = crc_table
    local sbyte = string.byte
    for i = 1, #data, 4096 do
        local j = math.min(i + 4095, #data)
        for k = i, j do
            c = bxor(tbl[band(bxor(c, sbyte(data, k)), 0xFF)], rshift(c, 8))
        end
    end
    return band(bxor(c, 0xFFFFFFFF), 0xFFFFFFFF)
end
Zip.crc32 = crc32

local function u16(n)
    n = n % 0x10000
    return string.char(n % 256, math.floor(n / 256))
end

local function u32(n)
    n = n % 0x100000000
    local b1 = n % 256; n = math.floor(n / 256)
    local b2 = n % 256; n = math.floor(n / 256)
    local b3 = n % 256; n = math.floor(n / 256)
    return string.char(b1, b2, b3, n % 256)
end

local function dos_datetime()
    local t = os.date("*t")
    local dos_time = bit.bor(bit.lshift(t.hour, 11), bit.lshift(t.min, 5), math.floor(t.sec / 2))
    local dos_date = bit.bor(bit.lshift(math.max(0, t.year - 1980), 9), bit.lshift(t.month, 5), t.day)
    return dos_time, dos_date
end

--- Open a new archive at path (written through a .part temp file).
function Zip.open(path)
    local tmp = path .. ".zippart"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, "Cannot create archive: " .. tostring(err) end
    local o = setmetatable({ path = path, tmp = tmp, f = f, offset = 0, entries = {} }, Zip)
    return o
end

--- Add one stored entry.
function Zip:add(name, data)
    local crc = crc32(data)
    local size = #data
    local dtime, ddate = dos_datetime()
    local header = table.concat({
        "PK\3\4",
        u16(20),        -- version needed
        u16(0x0800),    -- flags: UTF-8 names
        u16(0),         -- method: store
        u16(dtime), u16(ddate),
        u32(crc), u32(size), u32(size),
        u16(#name), u16(0),
        name,
    })
    self.f:write(header)
    self.f:write(data)
    table.insert(self.entries, { name = name, crc = crc, size = size, offset = self.offset, dtime = dtime, ddate = ddate })
    self.offset = self.offset + #header + size
    return true
end

--- Write the central directory and move the file into place.
function Zip:close()
    local cd_start = self.offset
    local cd_size = 0
    for _i, e in ipairs(self.entries) do
        local rec = table.concat({
            "PK\1\2",
            u16(20), u16(20),
            u16(0x0800), u16(0),
            u16(e.dtime), u16(e.ddate),
            u32(e.crc), u32(e.size), u32(e.size),
            u16(#e.name), u16(0), u16(0),
            u16(0), u16(0), u32(0),
            u32(e.offset),
            e.name,
        })
        self.f:write(rec)
        cd_size = cd_size + #rec
    end
    self.f:write(table.concat({
        "PK\5\6",
        u16(0), u16(0),
        u16(#self.entries), u16(#self.entries),
        u32(cd_size), u32(cd_start),
        u16(0),
    }))
    self.f:close()
    local ok, err = os.rename(self.tmp, self.path)
    if not ok then
        os.remove(self.tmp)
        return nil, "Cannot finalise archive: " .. tostring(err)
    end
    return true
end

function Zip:abort()
    pcall(function() self.f:close() end)
    os.remove(self.tmp)
end

return Zip
