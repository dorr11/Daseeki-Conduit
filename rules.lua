--[[
    Daseeki Conduit — rules.lua

    The rules engine. Split into:
      * PURE logic (no WoW API at call time) — rule matching, 12-attachment batch
        splitting, gold math with postage buffer, recipient validators. These are
        exercised directly by the self-test harness (selftest.lua) under a bare Lua
        VM, so they must never touch a WoW global at call time.
      * RUNTIME helpers — bag scanning + mail-queue building, which read live bag
        contents via C_Container / C_Item. Only ever called in-game.

    Rule shape (stored in DaseekiConduitDB.rules):
      {
        id        = <number>,     -- stable unique id (from db.nextRuleId)
        name      = "Ore to Bank",
        enabled   = true,
        kind      = "items" | "gold",
        recipient = "BankAlt",    -- character name (optionally "Name-Realm")

        -- kind == "items":
        filter = {
          mode       = "category" | "list",
          classID    = 7,               -- category mode: item class (7 = Trade Goods)
          subClasses = { [7] = true },  -- category: optional subclass narrowing
                                        --   (nil/empty = whole class)
          items      = { [itemID] = true },  -- list mode: explicit item set
        },

        -- kind == "gold":
        keepCopper = 1000000,     -- keep at least this many copper; send the excess
      }
--]]

local ADDON, ns = ...

local Rules = {}
ns.Rules = Rules

-- ════════════════════════════════════════════════════════════════════════════
--  PURE LOGIC  (self-test targets — no WoW API here)
-- ════════════════════════════════════════════════════════════════════════════

-- Does a bag item (info = { itemID, classID, subClassID }) match an item rule?
-- Category mode matches by item class, optionally narrowed to a subclass set.
-- List mode matches an explicit itemID set. Gold rules never match items.
function Rules.MatchesRule(rule, info)
    if not rule or not info or not info.itemID then return false end
    if rule.kind ~= "items" then return false end
    local f = rule.filter
    if not f then return false end

    if f.mode == "list" then
        return f.items ~= nil and f.items[info.itemID] == true
    elseif f.mode == "category" then
        if f.classID == nil then return false end
        if info.classID ~= f.classID then return false end
        -- An empty/absent subclass set means "the whole class".
        if f.subClasses and next(f.subClasses) ~= nil then
            return f.subClasses[info.subClassID] == true
        end
        return true
    end
    return false
end

-- Split an ordered list of stack descriptors into batches of at most maxAttach
-- (12 in Classic). One batch == one mail. Pure; order-preserving.
function Rules.SplitBatches(items, maxAttach)
    maxAttach = maxAttach or 12
    if maxAttach < 1 then maxAttach = 1 end
    local batches, cur = {}, nil
    for i = 1, #items do
        if not cur or #cur >= maxAttach then
            cur = {}
            batches[#batches + 1] = cur
        end
        cur[#cur + 1] = items[i]
    end
    return batches
end

-- How much copper to send for a gold rule: everything above keepCopper, minus a
-- postage buffer so the mail's own postage can never dip the wallet below keep.
-- Returns 0 when there is nothing safe to send. Never returns more than `money`.
function Rules.ComputeGoldSend(money, keepCopper, postageBuffer)
    money         = money or 0
    keepCopper    = keepCopper or 0
    postageBuffer = postageBuffer or 0
    local send = money - keepCopper - postageBuffer
    if send < 0 then send = 0 end
    if send > money then send = money end
    return send
end

-- ── Recipient validators (pure string logic; also self-tested) ────────────────

-- The name part of "Name" or "Name-Realm".
function Rules.BaseName(name)
    name = name or ""
    return name:match("^([^-]+)") or name
end

-- Is `recipient` the player themselves? (self-mail wastes gold/time and is refused)
-- `me` is injected so this stays pure/testable; runtime callers pass UnitName.
function Rules.IsSelfRecipient(recipient, me)
    me = me or ""
    if me == "" then return false end
    return Rules.BaseName(recipient):lower() == Rules.BaseName(me):lower()
end

-- Basic malformed-name guard. Character names have no spaces or digits and are at
-- least 2 characters; an optional "-Realm" suffix is allowed. We do NOT restrict to
-- ASCII so localized/accented names are not falsely rejected. (Existence can't be
-- verified here — the confirm popup + server are the real backstop.)
function Rules.LooksMalformed(recipient)
    local nm = Rules.BaseName(recipient)
    nm = nm:match("^%s*(.-)%s*$")   -- trim
    if #nm < 2 then return true end
    if nm:find("%s") then return true end
    if nm:find("%d") then return true end
    return false
end

-- Combined recipient gate. Returns ok, reason. Pure (me injected).
function Rules.ValidateRecipient(recipient, me)
    recipient = (recipient or ""):match("^%s*(.-)%s*$")
    if recipient == "" then return false, "no recipient set" end
    if Rules.LooksMalformed(recipient) then return false, "not a valid character name" end
    if Rules.IsSelfRecipient(recipient, me) then return false, "cannot mail to yourself" end
    return true, nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  ITEM-CATEGORY CATALOG  (UI-facing; names resolved at runtime, static fallback)
-- ════════════════════════════════════════════════════════════════════════════

-- Item classes worth routing, Trade Goods first (the materials headline). Names
-- are resolved live via C_Item.GetItemClassInfo; the static name is the fallback
-- so the picker never shows a blank.
Rules.ROUTABLE_CLASSES = {
    { classID = 7,  name = "Trade Goods" },
    { classID = 0,  name = "Consumable" },
    { classID = 5,  name = "Reagent" },
    { classID = 9,  name = "Recipe" },
    { classID = 15, name = "Miscellaneous" },
    { classID = 4,  name = "Armor" },
    { classID = 2,  name = "Weapon" },
}

-- Localized class name (falls back to the static label above).
function Rules.ClassName(classID)
    if C_Item and C_Item.GetItemClassInfo then
        local nm = C_Item.GetItemClassInfo(classID)
        if nm and nm ~= "" then return nm end
    end
    for _, c in ipairs(Rules.ROUTABLE_CLASSES) do
        if c.classID == classID then return c.name end
    end
    return "Class " .. tostring(classID)
end

-- Ordered list of { subClassID, name } for a class, using the AH subclass table
-- (catalog-verified C_AuctionHouse.GetAuctionItemSubClasses) + localized names.
function Rules.SubClassesFor(classID)
    local out = {}
    local ids = C_AuctionHouse and C_AuctionHouse.GetAuctionItemSubClasses
        and C_AuctionHouse.GetAuctionItemSubClasses(classID)
    if type(ids) == "table" then
        for _, sub in ipairs(ids) do
            local nm = C_Item and C_Item.GetItemSubClassInfo and C_Item.GetItemSubClassInfo(classID, sub)
            out[#out + 1] = { subClassID = sub, name = (nm and nm ~= "" and nm) or ("Subclass " .. tostring(sub)) }
        end
    end
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME  (bag scanning + mail-queue building — in-game only)
-- ════════════════════════════════════════════════════════════════════════════

-- classID for Quest items (class 12 in Classic). Quest items are never mailable;
-- we exclude them up front regardless of any rule so a rule can't queue one.
local QUEST_CLASS = 12

-- Resolve the class/subclass/binding of a bag slot's item. Returns an info table
-- { itemID, classID, subClassID, isBound, count } or nil for an empty/unknown slot.
function Rules.SlotInfo(bag, slot)
    local C = C_Container
    if not (C and C.GetContainerItemInfo) then return nil end
    local ci = C.GetContainerItemInfo(bag, slot)
    if not ci or not ci.itemID then return nil end
    local classID, subClassID
    if C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, _, _, cID, scID = C_Item.GetItemInfoInstant(ci.itemID)
        classID, subClassID = cID, scID
    end
    return {
        itemID     = ci.itemID,
        classID    = classID,
        subClassID = subClassID,
        isBound    = ci.isBound and true or false,
        count      = ci.stackCount or 1,
    }
end

-- Can this slot's item be mailed? Soulbound and quest items cannot; anything else
-- that still can't (conjured, etc.) is caught by the post-attach verification in
-- the send engine, which skips a slot that failed to attach.
function Rules.IsMailable(info)
    if not info or not info.itemID then return false end
    if info.isBound then return false end
    if info.classID == QUEST_CLASS then return false end
    return true
end

-- Scan bags for mailable stacks matching a single item rule.
-- Returns { { bag=, slot=, itemID=, count= }, ... } (order = bag/slot order).
function Rules.ScanStacksForRule(rule)
    local out = {}
    if rule.kind ~= "items" then return out end
    local C = C_Container
    if not (C and C.GetContainerNumSlots) then return out end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local n = C.GetContainerNumSlots(bag) or 0
        for slot = 1, n do
            local info = Rules.SlotInfo(bag, slot)
            if info and Rules.IsMailable(info) and Rules.MatchesRule(rule, info) then
                out[#out + 1] = { bag = bag, slot = slot, itemID = info.itemID, count = info.count }
            end
        end
    end
    return out
end

-- Build the ordered mail queue for a set of rules. Each queue entry is ONE mail:
--   { recipient=, subject=, stacks = { {bag,slot,itemID,count}, ... } }   (item mail)
--   { recipient=, subject=, money = <copper> }                            (gold mail)
--
-- `me` (UnitName) and `money` (GetMoney) are injected so this stays deterministic
-- and unit-testable; runtime callers pass the live values. Rules that fail the
-- recipient gate, or that have nothing to send, are skipped (and reported in the
-- returned `skipped` list so the UI can explain why).
--
-- Returns queue, summary where
--   summary = { itemCount, goldCopper, mailCount, byRecipient = { [name]={items,gold,mails} } }
--   skipped = { { rule=, reason= }, ... }
function Rules.BuildMailQueue(rules, opts)
    opts = opts or {}
    local me       = opts.me or ""
    local money    = opts.money or 0
    local maxAttach = opts.maxAttach or ns.MAX_ATTACH or 12
    local buffer   = opts.postageBuffer or ns.POSTAGE_BUFFER or 0
    local subject  = opts.subject or ns.MAIL_SUBJECT or "Daseeki Conduit"

    local queue = {}
    local skipped = {}
    local summary = { itemCount = 0, goldCopper = 0, mailCount = 0, byRecipient = {} }

    local function bump(recipient, dItems, dGold, dMails)
        local r = summary.byRecipient[recipient]
        if not r then r = { items = 0, gold = 0, mails = 0 }; summary.byRecipient[recipient] = r end
        r.items = r.items + (dItems or 0)
        r.gold  = r.gold  + (dGold or 0)
        r.mails = r.mails + (dMails or 0)
    end

    for _, rule in ipairs(rules or {}) do
        if rule.enabled then
            local okRcpt, reason = Rules.ValidateRecipient(rule.recipient, me)
            if not okRcpt then
                skipped[#skipped + 1] = { rule = rule, reason = reason }
            elseif rule.kind == "items" then
                local stacks = opts.scan and opts.scan(rule) or Rules.ScanStacksForRule(rule)
                if #stacks == 0 then
                    skipped[#skipped + 1] = { rule = rule, reason = "no matching items in bags" }
                else
                    local batches = Rules.SplitBatches(stacks, maxAttach)
                    for _, batch in ipairs(batches) do
                        queue[#queue + 1] = { recipient = rule.recipient, subject = subject, stacks = batch }
                        summary.itemCount = summary.itemCount + #batch
                        summary.mailCount = summary.mailCount + 1
                        bump(rule.recipient, #batch, 0, 1)
                    end
                end
            elseif rule.kind == "gold" then
                local send = Rules.ComputeGoldSend(money, rule.keepCopper or 0, buffer)
                if send <= 0 then
                    skipped[#skipped + 1] = { rule = rule, reason = "nothing over the keep amount" }
                else
                    queue[#queue + 1] = { recipient = rule.recipient, subject = subject, money = send }
                    summary.goldCopper = summary.goldCopper + send
                    summary.mailCount  = summary.mailCount + 1
                    bump(rule.recipient, 0, send, 1)
                    -- A single wallet funds every gold rule; once we've queued one
                    -- gold send, reduce the notional balance so a second gold rule
                    -- doesn't double-spend the same copper.
                    money = money - send
                end
            end
        end
    end

    return queue, summary, skipped
end

-- ── Rule construction helpers ─────────────────────────────────────────────────

-- Allocate the next stable rule id from the DB counter.
function Rules.NextId()
    local db = ns.db
    if not db then return 1 end
    db.nextRuleId = (db.nextRuleId or 1)
    local id = db.nextRuleId
    db.nextRuleId = id + 1
    return id
end

function Rules.NewItemRule(name)
    return {
        id      = Rules.NextId(),
        name    = name or "New Item Rule",
        enabled = true,
        kind    = "items",
        recipient = "",
        filter  = { mode = "category", classID = 7, subClasses = {}, items = {} },
    }
end

function Rules.NewGoldRule(name)
    return {
        id      = Rules.NextId(),
        name    = name or "Send Gold",
        enabled = true,
        kind    = "gold",
        recipient  = "",
        keepCopper = 0,
    }
end

-- The "Send Consumes" preset: an explicit-list item rule seeded with a curated set
-- of raid/dungeon consumables (own config; no shared SavedVariables with Raid-Prep).
function Rules.NewConsumesPreset()
    local r = {
        id      = Rules.NextId(),
        name    = "Send Consumes",
        enabled = true,
        kind    = "items",
        recipient = "",
        filter  = { mode = "list", classID = 7, subClasses = {}, items = {} },
    }
    for itemID in pairs(Rules.ConsumablesSeed) do
        r.filter.items[itemID] = true
    end
    return r
end

-- Find a rule by id; returns rule, index.
function Rules.FindById(id)
    local db = ns.db
    if not db or not db.rules then return nil end
    for i, r in ipairs(db.rules) do
        if r.id == id then return r, i end
    end
    return nil
end

-- ── Consumables seed (itemID -> name) — own data; IDs verified vs wowhead/classic ─
-- Used both to seed the Send Consumes preset and as a keyword-search DB in the list
-- editor so cache-cold items still resolve a name.
Rules.ConsumablesSeed = {
    -- Potions
    [13446] = "Major Healing Potion",   [13444] = "Major Mana Potion",
    [9030]  = "Restorative Potion",     [18253] = "Major Rejuvenation Potion",
    [20007] = "Mageblood Potion",       [13462] = "Purification Potion",
    [20008] = "Living Action Potion",   [5634]  = "Free Action Potion",
    [13455] = "Greater Stoneshield Potion", [13442] = "Mighty Rage Potion",
    [3387]  = "Limited Invulnerability Potion",
    -- Runes
    [12662] = "Demonic Rune",           [20520] = "Dark Rune",
    -- Flasks
    [13510] = "Flask of the Titans",    [13511] = "Flask of Distilled Wisdom",
    [13512] = "Flask of Supreme Power", [13513] = "Flask of Chromatic Resistance",
    [13506] = "Flask of Petrification",
    -- Elixirs
    [13452] = "Elixir of the Mongoose", [9206]  = "Elixir of Giants",
    [9187]  = "Elixir of Greater Agility", [3825]  = "Elixir of Fortitude",
    [9264]  = "Elixir of Shadow Power", [21546] = "Elixir of Greater Fire Power",
    [6373]  = "Elixir of Fire Power",   [13454] = "Greater Arcane Elixir",
    [9155]  = "Arcane Elixir",          [13453] = "Elixir of Brute Force",
    [9224]  = "Elixir of Demonslaying", [3391]  = "Elixir of Ogre's Strength",
    [3386]  = "Elixir of Poison Resistance", [9233] = "Elixir of Superior Defense",
    -- Protection potions
    [13457] = "Greater Fire Protection Potion", [13456] = "Greater Frost Protection Potion",
    [13459] = "Greater Shadow Protection Potion", [13458] = "Greater Nature Protection Potion",
    [13461] = "Greater Arcane Protection Potion", [13460] = "Greater Holy Protection Potion",
    -- Food
    [13931] = "Nightfin Soup",          [13928] = "Grilled Squid",
    [12217] = "Dragonbreath Chili",     [12218] = "Monster Omelet",
    [18254] = "Runn Tum Tuber Surprise", [20452] = "Smoked Desert Dumplings",
    [21217] = "Sagefish Delight",       [13810] = "Blessed Sunfruit",
    -- Weapon oils / stones
    [20748] = "Brilliant Mana Oil",     [20749] = "Brilliant Wizard Oil",
    [20747] = "Lesser Mana Oil",        [20746] = "Lesser Wizard Oil",
    [8956]  = "Oil of Immolation",      [3829]  = "Frost Oil",
    [12404] = "Dense Sharpening Stone", [18262] = "Elemental Sharpening Stone",
    [12643] = "Dense Weightstone",
    -- Jujus / Zanza / misc buffs
    [12451] = "Juju Power",             [12460] = "Juju Might",
    [12459] = "Juju Escape",            [12455] = "Juju Ember",
    [12457] = "Juju Chill",             [12820] = "Winterfall Firewater",
    [20079] = "Spirit of Zanza",        [20080] = "Sheen of Zanza",
    [20081] = "Swiftness of Zanza",     [9088]  = "Gift of Arthas",
    [8410]  = "R.O.I.D.S.",
    -- Engineering / bandages / rogue
    [18641] = "Dense Dynamite",         [10646] = "Goblin Sapper Charge",
    [14530] = "Heavy Runecloth Bandage", [7676]  = "Thistle Tea",
}

-- Keyword search over the seed DB (list-editor add UX). Numeric text = direct id.
function Rules.SearchConsumables(text)
    if not text or text == "" then return {} end
    local results = {}
    local id = tonumber(text)
    if id then
        results[#results + 1] = { itemID = id, name = Rules.ConsumablesSeed[id] or ("Item #" .. id) }
        return results
    end
    local lower = text:lower()
    for itemID, name in pairs(Rules.ConsumablesSeed) do
        if name:lower():find(lower, 1, true) then
            results[#results + 1] = { itemID = itemID, name = name }
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    return results
end
