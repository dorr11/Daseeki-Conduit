--[[
    Daseeki Conduit — network.lua

    OPTIONAL integration with the Daseeki alt registry (the addon formerly named
    Daseeki-Network, being renamed to Daseeki-Nexus). This is a soft-guarded
    adapter: when neither addon exposes a global roster, every function here
    no-ops cleanly and Conduit works exactly as a standalone (recipients are just
    typed names). If a future Nexus build exposes a roster global, the recipient
    picker in the settings editor gains a dropdown of known alt names for free.

    We probe BOTH the future name (_G.DaseekiNexus) and the current one
    (_G.DaseekiNetwork), and several plausible accessor shapes, without ever
    hard-depending on any of them. Nothing here errors when the registry is
    absent — that is the whole point of OptionalDeps.
--]]

local ADDON, ns = ...

local Network = {}
ns.Network = Network

-- Return the alt-registry table if one is exposed globally, else nil.
local function registry()
    return _G.DaseekiNexus or _G.DaseekiNetwork or nil
end

-- True when an alt registry is present and queryable.
function Network.Available()
    local reg = registry()
    if type(reg) ~= "table" then return false end
    -- Any of the accessor shapes we know how to read counts as available.
    if type(reg.GetCharacters) == "function" then return true end
    if type(reg.GetRoster) == "function" then return true end
    if type(reg.roster) == "table" then return true end
    return false
end

-- Normalize a roster entry (string or { name=/character= }) to a character name.
local function entryName(entry)
    if type(entry) == "string" then return entry end
    if type(entry) == "table" then
        return entry.name or entry.character or entry.charName or nil
    end
    return nil
end

-- Return a sorted list of known alt character names (excluding the current player),
-- or an empty table when no registry is available. Never errors.
function Network.GetAltNames()
    local out = {}
    if not Network.Available() then return out end

    local reg = registry()
    local list
    -- pcall every probe: a third-party registry must never be able to break us.
    if type(reg.GetCharacters) == "function" then
        local ok, res = pcall(reg.GetCharacters, reg)
        if ok and type(res) == "table" then list = res end
    end
    if not list and type(reg.GetRoster) == "function" then
        local ok, res = pcall(reg.GetRoster, reg)
        if ok and type(res) == "table" then list = res end
    end
    if not list and type(reg.roster) == "table" then
        list = reg.roster
    end
    if type(list) ~= "table" then return out end

    local me = ns.Rules and ns.Rules.BaseName(UnitName and UnitName("player") or "") or ""
    local seen = {}
    for _, entry in pairs(list) do
        local name = entryName(entry)
        if name and name ~= "" then
            local base = ns.Rules and ns.Rules.BaseName(name) or name
            if base:lower() ~= me:lower() and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
    end
    table.sort(out)
    return out
end
