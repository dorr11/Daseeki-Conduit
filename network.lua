--[[
    Daseeki Conduit — network.lua

    OPTIONAL alt-name source for the rule editor's "Alt" convenience picker
    (options.lua E.altRow). When Daseeki Nexus is installed, the picker lists the
    characters Nexus already knows about on this realm so a recipient can be chosen
    instead of typed. When Nexus is absent the list is empty, the row hides itself,
    and Conduit is exactly what it is standalone: recipients are typed names.

    ── Why the SavedVariables table and not a published global ───────────────────
    Nexus keeps its module tables on its own PRIVATE addon namespace (`local ADDON,
    ns = ...`); the only things it publishes globally are Daseeki.Sync /
    Daseeki.Config from syncns.lua. There is no DaseekiNexus roster object to call —
    an earlier build of this file probed for one and therefore never found anything.
    What DOES exist is a plain SavedVariables table, `DaseekiNexusData`, holding the
    character graph Nexus maintains as its system of record. We READ that table and
    NEVER write it: reading the SV needs nothing published, cannot break when Nexus
    refactors an internal, and is trivially testable headless. Same shape as the
    Bags 2.0 -> Nexus Inventory bridge (Daseeki-Bags2-beta/nexus.lua) and as this
    addon's own syncbridge.lua.

    Conduit's .toc does NOT declare DaseekiNexusData — declaring another addon's
    global would make BOTH addons write the same file. It declares only
    `## OptionalDeps: Daseeki-Nexus`, which is a LOAD-ORDER statement, not a
    dependency: the client loads Daseeki-Nexus first WHEN IT IS PRESENT AND ENABLED,
    so its SavedVariables are attached before our editor is ever built. With Nexus
    absent the line costs nothing.

    ── The Nexus store shape (read off Daseeki-Nexus store.lua) ──────────────────
      DaseekiNexusData = {
        version  = 1,                    -- Store.STORAGE_VERSION
        accounts = {                     -- [aid] = bucket ; "" is the ORPHAN bucket
          [aid] = {
            isSelf     = <bool>,
            characters = { ["Name-Realm"] = record },   -- Store.NewAccountBucket
            homeless   = { ["Name-Realm"] = record },   -- no manifest slot yet
            segments = ..., segmentHashes = ...,        -- not ours
          },
        },
        inventory = {                    -- Store.INVENTORY_SCHEMA area
          schema = 1,
          owners = { ["Name-Realm"] = { rev, updatedAt, data = { faction, ... } } },
        },
        -- timers / caches / notes / social / syncNamespaces / ... : not ours
      }
    A `record` optionally carries `faction` ("Alliance"/"Horde"), classTag, level and
    other wire fields; only `faction` is read here. Owner keys and character keys are
    both "Name-Realm" with the realm's spaces stripped, which is what lets the two
    graphs union by key at all.

    Two areas, two independent version gates. `version` stamps the CHARACTER graph
    (a newer stamp refuses the accounts read only); `inventory.schema` stamps the
    inventory area (a newer stamp refuses that area only). A refused area is a
    silent zero contribution, never an error and never a guess.

    EVERY bucket in `accounts` is one of the owner's OWN accounts — the mesh is a
    personal multi-account registry — so every bucket contributes, including the ""
    orphan bucket and each bucket's `homeless` table (those are real characters that
    simply have no manifest slot yet). `social` (guild / friends lists) is NEVER
    read: those are other people, not alts.

    ── What the picker is allowed to offer ───────────────────────────────────────
      * SAME REALM ONLY. A bare-name recipient is same-realm mail in Classic, and the
        picker writes bare names. Realms compare space-stripped and lowercased —
        Nexus keys already strip realm spaces, GetRealmName() does not.
      * NEVER the current character. Mail to yourself is rejected by the rules
        engine anyway (Rules.ValidateRecipient), so offering it is only a trap.
      * Explicit OTHER-faction entries are dropped. UNKNOWN faction on either side is
        KEPT: a missing field must never hide a target that is probably valid. Same
        direction as the auto-friend skip matrix (friends.lua Decide).

    Nothing here errors on any input. Every step is a type guard, and junk of any
    shape anywhere in another addon's saved table falls through to an empty list.
    Read-only, always: no function in this file writes to DaseekiNexusData.

    Clean-room: the Nexus shape above was read from OUR OWN Daseeki-Nexus repo. No
    third-party addon source was opened.
--]]

local ADDON, ns = ...

local Network = {}
ns.Network = Network

-- ════════════════════════════════════════════════════════════════════════════
--  Constants
-- ════════════════════════════════════════════════════════════════════════════

Network.ADDON_NAME  = "Daseeki-Nexus"
Network.DATA_GLOBAL = "DaseekiNexusData"   -- the churny data SV (accounts + inventory)

-- The highest Store.STORAGE_VERSION whose ACCOUNTS graph this build reads.
Network.DATA_VERSION = 1

-- The highest Store.INVENTORY_SCHEMA whose OWNERS graph this build reads.
Network.INVENTORY_SCHEMA = 1

-- ════════════════════════════════════════════════════════════════════════════
--  Pure helpers
-- ════════════════════════════════════════════════════════════════════════════

-- Realm comparison form: spaces stripped, folded. "" for anything unusable, which
-- callers read as "unknown" (and therefore "do not filter on it").
local function normRealm(realm)
    if type(realm) ~= "string" then return "" end
    return (realm:gsub("%s+", ""):lower())
end

-- Split a Nexus "Name-Realm" key on the FIRST hyphen: a character name can never
-- contain one, a realm name can (e.g. "Ravenholdt"-style compound keys are single
-- tokens here, but the rule costs nothing and is the safe direction). Returns nil
-- for anything that is not a well-formed key.
function Network.SplitKey(key)
    if type(key) ~= "string" then return nil end
    local name, realm = key:match("^([^-]+)%-(.+)$")
    if not name or name == "" then return nil end
    return name, realm
end

-- "Alliance"/"Horde", or nil for absent/unknown/anything else. An unrecognised
-- string is deliberately flattened to nil rather than kept: a value we cannot
-- compare must read as UNKNOWN, which includes rather than excludes.
local function faction(v)
    if v == "Alliance" or v == "Horde" then return v end
    return nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE CORE  (`G` and `me` are injectable so the harness never touches _G)
-- ════════════════════════════════════════════════════════════════════════════

-- Fold one "Name-Realm" key + whatever faction its record carries into the
-- accumulator. `acc` is keyed by the LOWERED base name so two graphs disagreeing
-- about capitalisation contribute one row, not two.
--
-- The faction verdict is accumulated rather than decided on the spot, because a
-- character can appear in both graphs with a faction in one and none in the other:
-- an entry is dropped only when EVERY explicit faction seen for it conflicts with
-- ours. Any matching sighting, or no explicit sighting at all, keeps it.
local function fold(acc, order, key, rec, ctx)
    local name, realm = Network.SplitKey(key)
    if not name then return end
    if ctx.realm ~= "" and normRealm(realm) ~= ctx.realm then return end

    local lower = name:lower()
    if ctx.me ~= "" and lower == ctx.me then return end

    local slot = acc[lower]
    if not slot then
        slot = { name = name }
        acc[lower] = slot
        order[#order + 1] = slot
    end

    if ctx.faction then
        local f = (type(rec) == "table") and faction(rec.faction) or nil
        if f == ctx.faction then slot.sawOurs = true
        elseif f then slot.sawOther = true end
    end
end

-- The one collector. `G` defaults to the live globals; `me` is
-- { name, realm, faction }, any field of which may be nil (headless, or a client
-- that has not answered yet). Returns a fresh sorted array of BASE names.
function Network.CollectAltNames(G, me)
    G = G or _G
    if type(G) ~= "table" then return {} end
    if type(me) ~= "table" then me = {} end

    local ctx = {
        me      = (type(me.name) == "string") and me.name:lower() or "",
        realm   = normRealm(me.realm),
        faction = faction(me.faction),
    }

    local data = G[Network.DATA_GLOBAL]
    if type(data) ~= "table" then return {} end

    local acc, order = {}, {}

    -- ── Area 1: the character graph ──────────────────────────────────────────
    local version = tonumber(data.version)
    if not (version and version > Network.DATA_VERSION) then
        local accounts = data.accounts
        if type(accounts) == "table" then
            for _, bucket in pairs(accounts) do
                if type(bucket) == "table" then
                    local chars = bucket.characters
                    if type(chars) == "table" then
                        for key, rec in pairs(chars) do fold(acc, order, key, rec, ctx) end
                    end
                    local homeless = bucket.homeless
                    if type(homeless) == "table" then
                        for key, rec in pairs(homeless) do fold(acc, order, key, rec, ctx) end
                    end
                end
            end
        end
    end

    -- ── Area 2: the inventory owners graph ───────────────────────────────────
    local inv = data.inventory
    if type(inv) == "table" then
        local schema = tonumber(inv.schema)
        if not (schema and schema > Network.INVENTORY_SCHEMA) then
            local owners = inv.owners
            if type(owners) == "table" then
                for key, entry in pairs(owners) do
                    local payload = (type(entry) == "table") and entry.data or nil
                    fold(acc, order, key, payload, ctx)
                end
            end
        end
    end

    -- ── The faction verdict, then a stable order ─────────────────────────────
    local out = {}
    for _, slot in ipairs(order) do
        if slot.sawOurs or not slot.sawOther then out[#out + 1] = slot.name end
    end

    -- Case-insensitive, with the raw string as the tiebreak: pairs() order is not
    -- reproducible, so two spellings that fold the same must still sort the same
    -- way every build or the dropdown would shuffle between sessions.
    table.sort(out, function(a, b)
        local la, lb = a:lower(), b:lower()
        if la ~= lb then return la < lb end
        return a < b
    end)
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  LIVE wrappers
-- ════════════════════════════════════════════════════════════════════════════

-- This character, as much of it as the client will admit to. Every call is
-- guarded: the harness (and an early login) has no unit API at all.
local function whoAmI()
    local name, realm, side
    if type(UnitName) == "function" then
        local n = UnitName("player")
        if type(n) == "string" then name = n end
    end
    if type(GetRealmName) == "function" then
        local r = GetRealmName()
        if type(r) == "string" then realm = r end
    end
    if type(UnitFactionGroup) == "function" then
        local f = UnitFactionGroup("player")
        if type(f) == "string" then side = f end
    end
    -- A name may still arrive realm-qualified; the rules engine owns that split.
    if name and ns.Rules and ns.Rules.BaseName then name = ns.Rules.BaseName(name) end
    return { name = name, realm = realm, faction = side }
end

-- Sorted alt base names for this realm, or {} when there is nothing to offer.
function Network.GetAltNames()
    return Network.CollectAltNames(_G, whoAmI())
end

-- True only when the picker would have at least one row. options.lua builds the
-- dropdown's choices ONCE at editor-build time and hides the row when this is
-- false, and an empty "— alts —" dropdown is worse than no dropdown at all.
function Network.Available()
    return #Network.GetAltNames() > 0
end

return Network
