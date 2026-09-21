--[[
    Minimal localisation helper for kouchiyomi.

    `_`  returns the string unchanged unless a translation for the active
         KOReader language exists in `translations` below.
    `T`  is KOReader's positional template helper: T("Page %1 of %2", a, b).
--]]

local translations = {
    -- ["fr"] = { ["Uchiyomi Browser"] = "Navigateur Uchiyomi" },
}

local function current_lang()
    local ok, lang = pcall(function()
        return G_reader_settings and G_reader_settings:readSetting("language")
    end)
    if ok and type(lang) == "string" and lang ~= "" then return lang end
    return "en"
end

local function _(text)
    local lang = current_lang()
    local tbl = translations[lang]
    if tbl and tbl[text] then return tbl[text] end
    local short = lang:match("^(%a%a)")
    if short and translations[short] and translations[short][text] then
        return translations[short][text]
    end
    return text
end

local ok, util = pcall(require, "ffi/util")
local T
if ok and util and util.template then
    T = util.template
else
    T = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d+)", function(n) return tostring(args[tonumber(n)] or "") end))
    end
end

return { _ = _, T = T, translations = translations }
