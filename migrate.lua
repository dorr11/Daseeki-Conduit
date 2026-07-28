--[[
    Daseeki Conduit — migrate.lua

    One-time, idempotent, non-destructive import of Daseeki Raid Prep's
    "Send Consumes" mail settings into Conduit rules.

    Raid Prep stored its mail config in its OWN SavedVariables (DaseekiPrepDB):
      * mailTo      = { Alliance = "Name", Horde = "Name" }  -- per-faction recipient
                      (legacy builds used a bare string; handled too)
      * classes     = { CLASS = { { itemID=, required=, name= }, ... }, ... }
      * mailExtra   = { [itemID] = true }   -- manually added items
      * mailIgnored = { [itemID] = true }   -- excluded items
    Raid Prep's effective mail item set was: the union of every class checklist's
    itemIDs, PLUS mailExtra, MINUS mailIgnored — exactly its Prep:GetMailItemSet.

    Conduit's rule model carries ONE recipient per rule, so each non-empty faction
    recipient becomes its own "Send Consumes" list-mode rule seeded with that item
    set. Both factions set => two rules, "Send Consumes (Alliance)" and
    "Send Consumes (Horde)"; a single faction => one plain "Send Consumes". The item
    selection is faction-independent in Raid Prep, so every produced rule gets its
    own fresh copy of the same set.

    Everything above the runtime wrapper is PURE (no WoW API at call time), so
    selftest.lua exercises it headless. DaseekiPrepDB is read STRICTLY READ-ONLY —
    nothing Raid Prep owns is ever written. A marker in DaseekiConduitDB
    (migratedRaidPrep) makes the import run at most once, the first time Conduit
    loads on a client where Raid Prep's data is present.
--]]

local ADDON, ns = ...

local Migrate = {}
ns.Migrate = Migrate

-- Faction scan order — Alliance before Horde, so rule creation is deterministic
-- (matters for the self-test and for stable rule ordering in the UI).
local FACTION_ORDER = { "Alliance", "Horde" }

-- trim (pure).
local function trim(s)
    return (tostring(s or "")):match("^%s*(.-)%s*$")
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE LOGIC  (self-test targets — no WoW API here)
-- ════════════════════════════════════════════════════════════════════════════

-- Effective mail item set from a Raid-Prep-shaped DB (read-only). Mirrors Raid
-- Prep's Prep:GetMailItemSet: union(all class itemIDs) + mailExtra - mailIgnored.
-- Returns { [itemID] = true }.
function Migrate.ComputeItemSet(prepDB)
    local set = {}
    if type(prepDB) ~= "table" then return set end
    if type(prepDB.classes) == "table" then
        for _, list in pairs(prepDB.classes) do
            if type(list) == "table" then
                for _, entry in ipairs(list) do
                    if type(entry) == "table" and entry.itemID then
                        set[entry.itemID] = true
                    end
                end
            end
        end
    end
    if type(prepDB.mailExtra) == "table" then
        for itemID in pairs(prepDB.mailExtra) do set[itemID] = true end
    end
    if type(prepDB.mailIgnored) == "table" then
        for itemID in pairs(prepDB.mailIgnored) do set[itemID] = nil end
    end
    return set
end

-- Per-faction recipients from prepDB.mailTo. Accepts the per-faction table shape
-- and the legacy bare-string shape. Returns an ordered array of
-- { faction = <"Alliance"|"Horde"|nil>, recipient = <name> } for non-empty
-- recipients only, Alliance before Horde.
function Migrate.FactionRecipients(prepDB)
    local out = {}
    if type(prepDB) ~= "table" then return out end
    local mt = prepDB.mailTo
    if type(mt) == "string" then
        local r = trim(mt)
        if r ~= "" then out[#out + 1] = { faction = nil, recipient = r } end
        return out
    end
    if type(mt) ~= "table" then return out end
    for _, fac in ipairs(FACTION_ORDER) do
        local r = trim(mt[fac])
        if r ~= "" then out[#out + 1] = { faction = fac, recipient = r } end
    end
    return out
end

-- Build the Send Consumes rule(s) from a Raid-Prep-shaped DB. `allocId` is a
-- function returning the next stable rule id (injected so this stays pure and
-- deterministic under the self-test harness). Returns an array of rule tables in
-- Conduit's rule shape. Empty when there is nothing to migrate (no recipient).
function Migrate.BuildConsumesRules(prepDB, allocId)
    local rules = {}
    local recips = Migrate.FactionRecipients(prepDB)
    if #recips == 0 then return rules end

    local itemSet = Migrate.ComputeItemSet(prepDB)
    local multi = #recips > 1

    for _, rc in ipairs(recips) do
        -- A fresh items copy per rule — no shared table between produced rules.
        local items = {}
        for itemID in pairs(itemSet) do items[itemID] = true end

        local name = "Send Consumes"
        if multi and rc.faction then
            name = name .. " (" .. rc.faction .. ")"
        end

        rules[#rules + 1] = {
            id        = allocId(),
            name      = name,
            enabled   = true,
            kind      = "items",
            recipient = rc.recipient,
            filter    = { mode = "list", classID = 7, subClasses = {}, items = items },
        }
    end
    return rules
end

-- Apply the migration to a Conduit-shaped db (pure: no WoW API). Idempotent via
-- the db.migratedRaidPrep marker; non-destructive to prepDB (read-only). Returns
-- the number of rules added.
--   * Already migrated                    -> 0, no change.
--   * prepDB absent / not a table         -> 0, marker NOT set (a later Raid Prep
--                                            install can still migrate).
--   * prepDB present                      -> append any produced rules, set the
--                                            marker (Raid Prep's data has been
--                                            seen), return the count (may be 0 when
--                                            no recipient was ever configured).
function Migrate.Apply(db, prepDB)
    if type(db) ~= "table" then return 0 end
    if db.migratedRaidPrep then return 0 end
    if type(prepDB) ~= "table" then return 0 end

    db.rules = db.rules or {}
    db.nextRuleId = db.nextRuleId or 1
    local function allocId()
        local id = db.nextRuleId
        db.nextRuleId = id + 1
        return id
    end

    local newRules = Migrate.BuildConsumesRules(prepDB, allocId)
    for _, r in ipairs(newRules) do
        db.rules[#db.rules + 1] = r
    end
    db.migratedRaidPrep = true
    return #newRules
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME  (in-game only)
-- ════════════════════════════════════════════════════════════════════════════

-- Runs once at PLAYER_LOGIN, when every addon's SavedVariables are loaded (so Raid
-- Prep's DaseekiPrepDB, if the addon is installed, is available to read).
function Migrate.Run()
    local db = ns.db
    if not db then return end
    if db.migratedRaidPrep then return end
    local prepDB = _G.DaseekiPrepDB
    if type(prepDB) ~= "table" then return end   -- Raid Prep not installed / no data

    local added = Migrate.Apply(db, prepDB)
    if added > 0 then
        ns:Print(("imported %d Send Consumes rule(s) from Raid Prep — open /conduit settings to review the recipient(s)."):format(added))
        if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
        if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
    end
end

ns:RegisterEvent("PLAYER_LOGIN", function() ns:SafeCall(Migrate.Run) end)
