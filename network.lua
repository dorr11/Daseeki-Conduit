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
    Two fields are read off a record besides its key: `faction` ("Alliance"/"Horde")
    and the CLASS TOKEN — which is spelled differently in the two areas, because they
    were written by different modules. The character graph calls it `classTag`
    (store.lua Store.NewCharacterRecord: `classTag = nil, -- e.g. "WARLOCK"`); the
    inventory owners payload calls it `class` (inventory.lua, filled from
    UnitClass's classFile). Both hold the same upper-case English token, so both are
    accepted and the first sighting wins. Everything else on a record is ignored.

    Owner keys and character keys are both "Name-Realm" with the realm's spaces
    stripped, which is what lets the two graphs union by key at all.

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
        Nexus keys already strip realm spaces, GetRealmName() does not. This one is a
        CORRECTNESS constraint, not a preference: a bare name typed at a mailbox on
        another realm addresses a different character, or nobody.
      * NEVER the current character. Mail to yourself is rejected by the rules
        engine anyway (Rules.ValidateRecipient), so offering it is only a trap.
      * EVERY faction. See below.

    ── The faction call (and why the picker no longer filters on it) ─────────────
    An earlier build of this file DROPPED alts whose record carried the other
    faction. That is wrong, and the reason is in the .toc: `## SavedVariables:
    DaseekiConduitDB` — one ACCOUNT-WIDE table, with `rules` a flat array and
    `disabledChars[charKey]` the only per-character switch. A rule authored on your
    Alliance main is LIVE on every Horde character on the account unless it is
    explicitly disabled there. So the editing character's faction says nothing about
    who the rule will eventually mail; filtering the picker by it hides exactly the
    recipients an account-wide rule exists to reach.

    The picker therefore offers every same-realm alt and LABELS the ones on the other
    faction — informative rather than prohibitive (BRAND_SPEC §6), and the layer that
    actually knows the answer already handles it: friends.lua Decide runs per
    character at the mailbox and returns "skip"/"other faction" there, quietly. An
    entry whose faction is unknown or uncomparable is never labelled: a missing field
    is not evidence, and a guess printed next to a name reads as fact.

    Rows are grouped same-faction-first (unknown counts as same: it is not a known
    conflict), name-sorted within each group, so the likely target is at the top and
    the cross-faction tail is out of the way without being hidden.

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

-- The class token as the two graphs spell it: `classTag` on a character record,
-- `class` on an inventory owner's payload. Upper-case English token or nil. Anything
-- that is not a plain non-empty string reads as unknown.
local function classToken(rec)
    if type(rec) ~= "table" then return nil end
    local v = rec.classTag
    if type(v) ~= "string" or v == "" then v = rec.class end
    if type(v) ~= "string" or v == "" then return nil end
    return v:upper()
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE CORE  (`G` and `me` are injectable so the harness never touches _G)
-- ════════════════════════════════════════════════════════════════════════════

-- Fold one "Name-Realm" key + whatever its record carries into the accumulator.
-- `acc` is keyed by the LOWERED base name so two graphs disagreeing about
-- capitalisation contribute one row, not two.
--
-- Faction is ACCUMULATED, never decided on the spot: a character can appear in both
-- graphs with a faction in one and none in the other, or with two graphs that
-- disagree. A sighting that matches OUR faction always wins the record — an alt some
-- graph calls ours must never be labelled cross-faction — and otherwise the first
-- explicit sighting stands. No explicit sighting anywhere leaves it nil (unknown),
-- which is never labelled at all.
--
-- Class is first-explicit-wins, which favours the character graph: the collector
-- walks accounts before inventory, and the character record is the more current of
-- the two (the inventory payload is a snapshot taken at a bag scan).
--
-- Level is HIGHEST-WINS rather than first-wins, because in Classic Era a level only
-- ever goes up: whichever graph carries the bigger number is the more recent truth,
-- and 0 / absent / non-numeric is UNKNOWN and never overwrites a real level.
--
-- Item counts come only from the inventory graph, and the NEWEST STAMP wins (an
-- unstamped payload fills an empty slot but never displaces a stamped one). The map
-- is kept BY REFERENCE and never copied — this file's contract is read-only on
-- another addon's saved table, so a reference costs nothing and no reader of it is
-- permitted to write. `stamp` is the owning entry's `updatedAt`, which lives on the
-- wrapper rather than on the payload, hence the extra argument.
local function fold(acc, order, key, rec, ctx, stamp)
    local name, realm = Network.SplitKey(key)
    if not name then return end
    if ctx.realm ~= "" and normRealm(realm) ~= ctx.realm then return end

    local lower = name:lower()
    if ctx.me ~= "" and lower == ctx.me then return end

    local slot = acc[lower]
    if not slot then
        slot = { name = name, realm = realm }
        acc[lower] = slot
        order[#order + 1] = slot
    end

    local f = faction(type(rec) == "table" and rec.faction or nil)
    if f then
        if ctx.faction and f == ctx.faction then
            slot.faction = f                          -- a matching sighting is final
        elseif slot.faction == nil then
            slot.faction = f                          -- otherwise first explicit wins
        end
    end

    if slot.class == nil then slot.class = classToken(rec) end

    if type(rec) == "table" then
        local lvl = tonumber(rec.level)
        if lvl and lvl > 0 and (slot.level == nil or lvl > slot.level) then
            slot.level = math.floor(lvl)
        end

        if type(rec.itemCounts) == "table" then
            local at = tonumber(stamp) or tonumber(rec.ts)
            if slot.counts == nil then
                slot.counts, slot.countsAt = rec.itemCounts, at
            elseif at and (slot.countsAt == nil or at > slot.countsAt) then
                slot.counts, slot.countsAt = rec.itemCounts, at
            end
        end
    end
end

-- The one collector. `G` defaults to the live globals; `me` is
-- { name, realm, faction }, any field of which may be nil (headless, or a client
-- that has not answered yet).
--
-- Returns a fresh array of ENTRIES:
--     { name    = "Bankalt",     -- base name; this is what the picker writes
--       realm   = "Whitemane",   -- as the Nexus key spelled it (space-stripped)
--       faction = "Horde"|nil,   -- nil = unknown, and unknown is never labelled
--       class   = "WARLOCK"|nil, -- upper-case token, for the class colour
--       level   = 60|nil,        -- highest sighting; nil = never recorded
--       counts  = <table>|nil,   -- Nexus's itemCounts map, BY REFERENCE, read-only
--       countsAt= <epoch>|nil,   -- when that map was stamped (its staleness)
--       otherFaction = true|nil} -- explicit conflict with `me` — the ONLY flag the
--                                -- label layer is allowed to act on
--
-- The label layer reads only name/class/faction; level and counts exist for the
-- boon planner (boons.lua), which needs to know WHO is 60 and WHAT they hold.
-- Order: same-faction-and-unknown first, then the explicit cross-faction tail, each
-- group sorted case-insensitively with the raw string as tiebreak (pairs() order is
-- not reproducible, so two spellings that fold together must still sort the same way
-- every session or the dropdown would shuffle between logins).
function Network.CollectAlts(G, me)
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
                    local stamp   = (type(entry) == "table") and tonumber(entry.updatedAt) or nil
                    fold(acc, order, key, payload, ctx, stamp)
                end
            end
        end
    end

    -- ── The faction verdict, then a stable order ─────────────────────────────
    for _, slot in ipairs(order) do
        if ctx.faction and slot.faction and slot.faction ~= ctx.faction then
            slot.otherFaction = true
        end
    end

    table.sort(order, function(a, b)
        local ao, bo = a.otherFaction and 1 or 0, b.otherFaction and 1 or 0
        if ao ~= bo then return ao < bo end
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    return order
end

-- Back-compatible name-only view of the same core: a fresh array of BASE NAMES in
-- the same order. Kept because a name list is what the rule stores and what anything
-- downstream of the picker has ever needed.
function Network.CollectAltNames(G, me)
    local out = {}
    for _, e in ipairs(Network.CollectAlts(G, me)) do out[#out + 1] = e.name end
    return out
end

-- How many of `itemID` an entry's Nexus snapshot says that character holds.
--
-- ZERO IS THE ANSWER FOR "NO SNAPSHOT" as well as for "a snapshot that says none",
-- and the two are NOT the same thing: `countsAt` is what tells them apart, and any
-- caller that acts on a count is expected to show its age. Guarded end to end, so a
-- junk map in another addon's saved table reads as zero rather than erroring.
function Network.ItemCount(entry, itemID)
    if type(entry) ~= "table" or type(entry.counts) ~= "table" then return 0 end
    local n = tonumber(entry.counts[itemID])
    if not n or n ~= n or n < 0 then return 0 end
    return math.floor(n)
end

-- The roster row for a base name (case-insensitive, realm suffix ignored), or nil.
function Network.FindEntry(entries, name)
    if type(entries) ~= "table" or type(name) ~= "string" then return nil end
    local want = (name:match("^([^-]+)") or name):match("^%s*(.-)%s*$"):lower()
    if want == "" then return nil end
    for _, e in ipairs(entries) do
        if type(e) == "table" and type(e.name) == "string" and e.name:lower() == want then
            return e
        end
    end
    return nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  LABELS  (pure: every source of colour is injected)
-- ════════════════════════════════════════════════════════════════════════════

-- Colour escape for a class token, or "" when we cannot know one.
--
-- `colors` is a RAID_CLASS_COLORS-shaped table — the Blizzard global, which Classic
-- Era ships. Two shapes are accepted because the game has used both: a `.colorStr`
-- hex string ("ff8787ed") and plain r/g/b numbers. Neither is required; a client (or
-- the harness) with no palette gets an uncoloured name, which is a cosmetic loss and
-- nothing else. BRAND_SPEC §3 sanctions class colour on character names.
function Network.ClassColorEscape(class, colors)
    if type(class) ~= "string" or class == "" then return "" end
    if type(colors) ~= "table" then return "" end
    local c = colors[class]
    if type(c) ~= "table" then return "" end
    if type(c.colorStr) == "string" and #c.colorStr == 8 then return "|c" .. c.colorStr end
    local r, g, b = c.r, c.g, c.b
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return "" end
    local function byte(v)
        v = math.floor(v * 255 + 0.5)
        if v < 0 then v = 0 elseif v > 255 then v = 255 end
        return v
    end
    return ("|cff%02x%02x%02x"):format(byte(r), byte(g), byte(b))
end

-- One dropdown row's display text for an entry.
--
--   opts = { classColors = <RAID_CLASS_COLORS-shaped table or nil>,
--            tagColor    = "|cffA79B84" or nil }   -- muted, from the live theme
--
-- The name is class-coloured when we can; a cross-faction entry gains a plain
-- parenthesised faction tag. Nothing else is added: the row is a name, not a record.
-- Unknown faction produces NO tag (see the header) and an unknown class produces no
-- colour, so a sparse store degrades to a plain sorted name list.
function Network.AltLabel(entry, opts)
    if type(entry) ~= "table" or type(entry.name) ~= "string" then return "" end
    opts = (type(opts) == "table") and opts or {}

    local esc = Network.ClassColorEscape(entry.class, opts.classColors)
    local label = (esc ~= "") and (esc .. entry.name .. "|r") or entry.name

    if entry.otherFaction and type(entry.faction) == "string" then
        local tag = "(" .. entry.faction .. ")"
        local tc = opts.tagColor
        if type(tc) == "string" and tc:sub(1, 2) == "|c" then tag = tc .. tag .. "|r" end
        label = label .. " " .. tag
    end
    return label
end

-- The picker's choice list, ready for UI.MakeDropdown: value = the BARE NAME that
-- goes into the rule, text = the decorated label. Splitting the two is what keeps
-- the dropdown a convenience over the free-text field rather than a replacement for
-- it — a name chosen here and the same name typed there produce the identical rule.
function Network.BuildAltChoices(entries, opts)
    local out = {}
    for _, e in ipairs(entries or {}) do
        if type(e) == "table" and type(e.name) == "string" then
            out[#out + 1] = { value = e.name, text = Network.AltLabel(e, opts) }
        end
    end
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

-- The muted token as a colour escape, for the faction tag. Core's kit is optional
-- from here — Conduit's options page only ever draws inside it, but this file must
-- not assume that — so an absent kit simply means an uncoloured tag.
local function mutedEscape()
    local UI = _G.DaseekiUI
    if type(UI) ~= "table" or type(UI.Color) ~= "function" then return nil end
    local okRun, r, g, b = pcall(UI.Color, "muted")
    if not okRun or type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
        return nil
    end
    return ("|cff%02x%02x%02x"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Sorted alt entries for this realm, or {} when there is nothing to offer.
function Network.GetAlts()
    return Network.CollectAlts(_G, whoAmI())
end

-- Sorted alt base names — the value list, unchanged contract.
function Network.GetAltNames()
    return Network.CollectAltNames(_G, whoAmI())
end

-- The ready-to-hand choice list for the rule editor's Alt dropdown.
function Network.GetAltChoices()
    return Network.BuildAltChoices(Network.GetAlts(), {
        classColors = _G.RAID_CLASS_COLORS,
        tagColor    = mutedEscape(),
    })
end

-- The same-realm roster INCLUDING the logged-in character.
--
-- The Alt picker must never offer you yourself — mail to self is refused, so the row
-- would only ever be a trap. A SOURCE picker is the opposite case: the bank alt you
-- are designating is very often the character you are sitting on while you designate
-- it, and leaving it out would make the setting impossible to complete from there.
-- Same collector, same store reads, same class colours; only `me.name` is withheld.
function Network.GetRoster()
    local me = whoAmI()
    return Network.CollectAlts(_G, { name = nil, realm = me.realm, faction = me.faction })
end

-- The roster as dropdown rows (bare name as value, decorated label as text).
function Network.GetRosterChoices()
    return Network.BuildAltChoices(Network.GetRoster(), {
        classColors = _G.RAID_CLASS_COLORS,
        tagColor    = mutedEscape(),
    })
end

-- True only when the picker would have at least one row. options.lua builds the
-- dropdown's choices ONCE at editor-build time and hides the row when this is
-- false, and an empty "— alts —" dropdown is worse than no dropdown at all.
function Network.Available()
    return #Network.GetAlts() > 0
end

return Network
