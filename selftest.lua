--[[
    Daseeki Conduit — selftest.lua

    Pure-Lua self-tests for the rules engine's testable core: rule matching, the
    12-attachment batch split, gold math with the postage buffer, recipient
    validation, and a mail-queue integration check. No WoW API is touched at call
    time, so the same suites run in-game (/conduit debug selftest) and headless
    under a bare Lua VM (the fengari harness) as a build gate.
--]]

local ADDON, ns = ...
local Rules = ns.Rules

-- ── Tiny assert framework ─────────────────────────────────────────────────────
local function newT(name)
    return { name = name, pass = 0, fail = 0, msgs = {} }
end
local function check(t, cond, label)
    if cond then t.pass = t.pass + 1
    else t.fail = t.fail + 1; t.msgs[#t.msgs + 1] = "FAIL: " .. label end
end
local function eq(t, got, want, label)
    check(t, got == want, label .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
end
local function report(t, verbose)
    if verbose or t.fail > 0 then
        for _, m in ipairs(t.msgs) do ns:Print("  " .. m) end
        ns:Print(("  %s: %d passed, %d failed"):format(t.name, t.pass, t.fail))
    end
    return t.fail == 0
end

-- ── Suite 1: rule matching ────────────────────────────────────────────────────
ns:RegisterSelfTest("rule-matching", function(verbose)
    local t = newT("rule-matching")

    local cat = { kind = "items", filter = { mode = "category", classID = 7, subClasses = {} } }
    check(t,  Rules.MatchesRule(cat, { itemID = 1, classID = 7, subClassID = 1 }),  "category class 7 matches class 7")
    check(t, not Rules.MatchesRule(cat, { itemID = 2, classID = 0, subClassID = 1 }), "category class 7 rejects class 0")

    local catSub = { kind = "items", filter = { mode = "category", classID = 7, subClasses = { [7] = true } } }
    check(t,  Rules.MatchesRule(catSub, { itemID = 3, classID = 7, subClassID = 7 }),  "subclass 7 matches")
    check(t, not Rules.MatchesRule(catSub, { itemID = 4, classID = 7, subClassID = 1 }), "subclass 1 rejected when only 7 selected")

    local list = { kind = "items", filter = { mode = "list", items = { [111] = true, [222] = true } } }
    check(t,  Rules.MatchesRule(list, { itemID = 111, classID = 0 }), "list matches member")
    check(t, not Rules.MatchesRule(list, { itemID = 333, classID = 0 }), "list rejects non-member")

    local gold = { kind = "gold", keepCopper = 0 }
    check(t, not Rules.MatchesRule(gold, { itemID = 111, classID = 7 }), "gold rule never matches items")

    -- Defensive: nil inputs never match / never error.
    check(t, not Rules.MatchesRule(nil, { itemID = 1 }), "nil rule → false")
    check(t, not Rules.MatchesRule(cat, nil), "nil info → false")

    return report(t, verbose)
end)

-- ── Suite 2: 12-attachment batch splitting ────────────────────────────────────
ns:RegisterSelfTest("batch-splitting", function(verbose)
    local t = newT("batch-splitting")

    local function mk(n) local a = {}; for i = 1, n do a[i] = i end; return a end

    local b0 = Rules.SplitBatches(mk(0), 12)
    eq(t, #b0, 0, "0 items → 0 batches")

    local b12 = Rules.SplitBatches(mk(12), 12)
    eq(t, #b12, 1, "12 items → 1 batch")
    eq(t, #b12[1], 12, "batch holds 12")

    local b13 = Rules.SplitBatches(mk(13), 12)
    eq(t, #b13, 2, "13 items → 2 batches")
    eq(t, #b13[1], 12, "first batch 12")
    eq(t, #b13[2], 1, "second batch 1")

    local b25 = Rules.SplitBatches(mk(25), 12)
    eq(t, #b25, 3, "25 items → 3 batches")
    eq(t, #b25[3], 1, "last batch 1")

    -- Order preserved.
    eq(t, b13[1][1], 1, "order preserved (first)")
    eq(t, b13[2][1], 13, "order preserved (spillover)")

    -- Different cap.
    local b5 = Rules.SplitBatches(mk(5), 2)
    eq(t, #b5, 3, "5 items cap 2 → 3 batches")

    return report(t, verbose)
end)

-- ── Suite 3: gold math with postage buffer ────────────────────────────────────
ns:RegisterSelfTest("gold-math", function(verbose)
    local t = newT("gold-math")
    local BUF = 30 * 100   -- 30 silver, the design's postage buffer

    -- 130g wallet, keep 100g, 30s buffer → 29g 70s = 297000 copper.
    eq(t, Rules.ComputeGoldSend(130 * 10000, 100 * 10000, BUF), 297000, "excess over keep, minus buffer")

    -- Below keep → 0.
    eq(t, Rules.ComputeGoldSend(50 * 10000, 100 * 10000, BUF), 0, "below keep → 0")

    -- Exactly keep + buffer → 0 (nothing safe to send).
    eq(t, Rules.ComputeGoldSend(100 * 10000 + BUF, 100 * 10000, BUF), 0, "exactly keep+buffer → 0")

    -- One copper above keep+buffer → 1.
    eq(t, Rules.ComputeGoldSend(100 * 10000 + BUF + 1, 100 * 10000, BUF), 1, "one over → 1")

    -- Empty wallet → 0, never negative.
    eq(t, Rules.ComputeGoldSend(0, 0, BUF), 0, "empty wallet → 0")

    -- Never returns more than money.
    local send = Rules.ComputeGoldSend(500, 0, 0)
    check(t, send <= 500, "send never exceeds wallet")

    return report(t, verbose)
end)

-- ── Suite 4: recipient validation ─────────────────────────────────────────────
ns:RegisterSelfTest("recipient-validation", function(verbose)
    local t = newT("recipient-validation")

    local function ok(r, me) local o = Rules.ValidateRecipient(r, me); return o end
    check(t, not ok("", "Hero"), "empty → invalid")
    check(t,     ok("Bank", "Hero"), "plain name → valid")
    check(t,     ok("Bank-Firemaw", "Hero"), "name-realm → valid")
    check(t, not ok("Hero", "Hero"), "self → invalid")
    check(t, not ok("Hero-Realm", "Hero-Realm"), "self with realm → invalid")
    check(t, not ok("Bad Name", "Hero"), "space → malformed")
    check(t, not ok("Name2", "Hero"), "digit → malformed")
    check(t, not ok("A", "Hero"), "too short → malformed")

    eq(t, Rules.BaseName("Bank-Firemaw"), "Bank", "BaseName strips realm")

    return report(t, verbose)
end)

-- ── Suite 5: mail-queue integration (injected scan + money; still pure) ───────
ns:RegisterSelfTest("mail-queue", function(verbose)
    local t = newT("mail-queue")

    -- Item rule matching 13 fake stacks → 2 mails (12 + 1).
    local itemRule = { id = 1, enabled = true, kind = "items", recipient = "Bank",
                       filter = { mode = "list", items = {} } }
    local stacks = {}
    for i = 1, 13 do stacks[i] = { bag = 0, slot = i, itemID = 100 + i, count = 1 } end

    local queue, summary = Rules.BuildMailQueue({ itemRule }, {
        me = "Hero", money = 0, maxAttach = 12, postageBuffer = 0,
        scan = function() return stacks end,
    })
    eq(t, #queue, 2, "13 stacks → 2 mails")
    eq(t, summary.itemCount, 13, "13 items counted")
    eq(t, summary.mailCount, 2, "2 mails in summary")

    -- Two gold rules share one wallet — no double-spend.
    local g1 = { id = 2, enabled = true, kind = "gold", recipient = "Bank", keepCopper = 0 }
    local g2 = { id = 3, enabled = true, kind = "gold", recipient = "Vault", keepCopper = 0 }
    local q2, sum2 = Rules.BuildMailQueue({ g1, g2 }, { me = "Hero", money = 1000, postageBuffer = 0 })
    -- First gold rule drains the balance; the second finds nothing left.
    eq(t, #q2, 1, "second gold rule finds nothing after first drains wallet")
    eq(t, sum2.goldCopper, 1000, "total gold queued equals wallet")

    -- Self-recipient and bad-recipient rules are skipped, not queued.
    local bad = { id = 4, enabled = true, kind = "items", recipient = "Hero",
                  filter = { mode = "list", items = {} } }
    local q3, _, skipped = Rules.BuildMailQueue({ bad }, {
        me = "Hero", scan = function() return { { bag = 0, slot = 1, itemID = 5, count = 1 } } end,
    })
    eq(t, #q3, 0, "self-recipient rule not queued")
    check(t, skipped and #skipped == 1, "self-recipient rule reported as skipped")

    -- Disabled rule is ignored entirely.
    local off = { id = 5, enabled = false, kind = "gold", recipient = "Bank", keepCopper = 0 }
    local q4 = Rules.BuildMailQueue({ off }, { me = "Hero", money = 1000, postageBuffer = 0 })
    eq(t, #q4, 0, "disabled rule not queued")

    return report(t, verbose)
end)

-- ── Suite 6: Raid-Prep → Conduit settings migration (pure; migrate.lua) ────────
ns:RegisterSelfTest("raidprep-migration", function(verbose)
    local t = newT("raidprep-migration")
    local M = ns.Migrate

    local function count(set) local n = 0; for _ in pairs(set) do n = n + 1 end; return n end

    -- A Raid-Prep-shaped SavedVariables fixture.
    --   item set = union(class itemIDs) + mailExtra - mailIgnored
    --            = {13442, 13446, 20520}  (13444 removed by mailIgnored)
    local prepDB = {
        classes = {
            WARRIOR = { { itemID = 13442 }, { itemID = 13446 } },
            MAGE    = { { itemID = 13444 }, { itemID = 13446 } },  -- 13446 dup across classes
        },
        mailExtra   = { [20520] = true },   -- Dark Rune added by hand
        mailIgnored = { [13444] = true },   -- Major Mana Potion unchecked
        mailTo      = { Alliance = "Bankalt", Horde = "Hordebank" },
    }

    -- ComputeItemSet: union - ignored, de-duplicated.
    local set = M.ComputeItemSet(prepDB)
    eq(t, count(set), 3, "item set has 3 items (dup collapsed, ignored removed)")
    check(t, set[13442] == true, "kept class item 13442")
    check(t, set[13446] == true, "kept class item 13446 (from two classes)")
    check(t, set[20520] == true, "kept mailExtra item 20520")
    check(t, set[13444] == nil,  "mailIgnored 13444 excluded")

    -- FactionRecipients: both factions, Alliance first.
    local recips = M.FactionRecipients(prepDB)
    eq(t, #recips, 2, "both faction recipients found")
    eq(t, recips[1].faction, "Alliance", "Alliance ordered first")
    eq(t, recips[1].recipient, "Bankalt", "Alliance recipient")
    eq(t, recips[2].recipient, "Hordebank", "Horde recipient")

    -- BuildConsumesRules: one list-mode rule per faction, distinct item copies.
    local id = 0
    local function alloc() id = id + 1; return id end
    local rules = M.BuildConsumesRules(prepDB, alloc)
    eq(t, #rules, 2, "two rules built (one per faction)")
    eq(t, rules[1].name, "Send Consumes (Alliance)", "Alliance rule named")
    eq(t, rules[2].name, "Send Consumes (Horde)", "Horde rule named")
    eq(t, rules[1].kind, "items", "rule kind is items")
    eq(t, rules[1].filter.mode, "list", "rule filter is list mode")
    eq(t, rules[1].recipient, "Bankalt", "Alliance rule recipient")
    eq(t, count(rules[1].filter.items), 3, "rule 1 carries the full item set")
    eq(t, count(rules[2].filter.items), 3, "rule 2 carries the full item set")
    check(t, rules[1].filter.items ~= rules[2].filter.items, "each rule owns a distinct items table")
    rules[1].filter.items[13442] = nil
    check(t, rules[2].filter.items[13442] == true, "mutating rule 1 items does not affect rule 2")

    -- Single-faction fixture => one plain "Send Consumes" (no suffix).
    local solo = { classes = {}, mailExtra = { [13510] = true }, mailIgnored = {},
                   mailTo = { Alliance = "Solobank", Horde = "" } }
    id = 0
    local soloRules = M.BuildConsumesRules(solo, alloc)
    eq(t, #soloRules, 1, "single faction => one rule")
    eq(t, soloRules[1].name, "Send Consumes", "single-faction rule unsuffixed")
    eq(t, soloRules[1].recipient, "Solobank", "single-faction recipient")

    -- Legacy bare-string mailTo is honored.
    local legacy = { classes = {}, mailExtra = {}, mailIgnored = {}, mailTo = "OldBank" }
    local legRules = M.BuildConsumesRules(legacy, alloc)
    eq(t, #legRules, 1, "legacy string mailTo => one rule")
    eq(t, legRules[1].recipient, "OldBank", "legacy recipient migrated")

    -- Apply: idempotent + non-destructive marker behavior.
    local db = { rules = {}, nextRuleId = 1 }
    local added = M.Apply(db, prepDB)
    eq(t, added, 2, "first Apply adds 2 rules")
    eq(t, #db.rules, 2, "db has 2 rules after first Apply")
    check(t, db.migratedRaidPrep == true, "marker set after Apply")
    eq(t, db.nextRuleId, 3, "nextRuleId advanced past the 2 assigned ids")

    local added2 = M.Apply(db, prepDB)
    eq(t, added2, 0, "second Apply is a no-op (idempotent)")
    eq(t, #db.rules, 2, "no duplicate rules on re-apply")

    -- Apply with no Raid-Prep data present: no rules, marker NOT set (door open).
    local db2 = { rules = {}, nextRuleId = 1 }
    eq(t, M.Apply(db2, nil), 0, "absent prepDB adds nothing")
    check(t, db2.migratedRaidPrep ~= true, "absent prepDB leaves marker unset")

    -- Apply with Raid-Prep present but no recipient configured: 0 rules, marker set.
    local db3 = { rules = {}, nextRuleId = 1 }
    local noRcpt = { classes = { WARRIOR = { { itemID = 13442 } } }, mailExtra = {},
                     mailIgnored = {}, mailTo = { Alliance = "", Horde = "" } }
    eq(t, M.Apply(db3, noRcpt), 0, "no recipient => 0 rules")
    check(t, db3.migratedRaidPrep == true, "marker set (data seen) even with 0 rules")

    return report(t, verbose)
end)

-- ── Suite 7: auto-friend directory + skip matrix (pure; friends.lua) ───────────
ns:RegisterSelfTest("auto-friend", function(verbose)
    local t = newT("auto-friend")
    local F = ns.Friends

    -- ── canonicalisation ──────────────────────────────────────────────────────
    eq(t, F.NormalizeRealm("Blood Sail Buccaneers"), "bloodsailbuccaneers", "realm strips spaces + case")
    eq(t, F.NormalizeRealm(nil), "", "nil realm normalizes to empty")
    eq(t, F.CanonicalKey("Bankalt", "Whitemane"), "bankalt-whitemane", "key = name-realm, folded")
    eq(t, F.CanonicalKey("Bankalt-Faerlina", "Whitemane"), "bankalt-faerlina",
       "an explicit -Realm in the name beats the stamping realm")
    eq(t, F.CanonicalKey("  BankAlt  ", "Whitemane"), "bankalt-whitemane", "key trims + folds")
    check(t, F.CanonicalKey("", "Whitemane") == nil, "empty name has no key")

    local sBase, sRealm = F.SplitRecipient("Bank-Blood Sail Buccaneers")
    eq(t, sBase, "Bank", "split takes the base name")
    eq(t, sRealm, "Blood Sail Buccaneers", "split keeps the raw realm")

    -- ── collection from rules (self / malformed / empty all excluded) ──────────
    local ctx = { me = "Hero", realm = "whitemane", faction = "Alliance" }
    local collected = F.CollectFromRules({
        { recipient = "Bankalt" },
        { recipient = "Bankalt", enabled = false },   -- dup + disabled: still one entry
        { recipient = "" },                           -- no recipient
        { recipient = "Hero" },                       -- self
        { recipient = "Bad Name" },                   -- malformed (space)
        { recipient = "Vault-Whitemane" },
    }, ctx)
    local nCollected = 0; for _ in pairs(collected) do nCollected = nCollected + 1 end
    eq(t, nCollected, 2, "only the two valid recipients collected")
    check(t, collected["bankalt-whitemane"] ~= nil, "Bankalt collected")
    check(t, collected["vault-whitemane"] ~= nil, "Vault-Whitemane collected")
    check(t, collected["hero-whitemane"] == nil, "self never collected")
    eq(t, collected["bankalt-whitemane"].faction, "Alliance", "entry attributed with the stamping faction")
    eq(t, collected["bankalt-whitemane"].realm, "whitemane", "entry attributed with the stamping realm")
    eq(t, collected["bankalt-whitemane"].name, "Bankalt", "entry keeps the typed spelling")

    -- ── directory stamping: additive, first attribution wins, fills gaps ───────
    local dir = {}
    local changed, added = F.StampDirectory(dir, collected, 1000)
    check(t, changed, "first stamp reports a change")
    eq(t, added, 2, "two entries added")
    check(t, not (F.StampDirectory(dir, collected, 2000)), "re-stamping the same entries is a no-op")

    -- A Horde character can never re-attribute an Alliance recipient.
    F.StampDirectory(dir, { ["bankalt-whitemane"] =
        { name = "Bankalt", realm = "whitemane", faction = "Horde" } }, 3000)
    eq(t, dir["bankalt-whitemane"].faction, "Alliance", "first attribution wins (never re-factioned)")

    -- ...but a MISSING attribution is filled in.
    F.StampDirectory(dir, { ["ghost-whitemane"] = { name = "Ghost", realm = "", faction = nil } }, 4000)
    local fillChanged = F.StampDirectory(dir, { ["ghost-whitemane"] =
        { name = "Ghost", realm = "whitemane", faction = "Horde" } }, 5000)
    check(t, fillChanged, "filling an unknown attribution reports a change")
    eq(t, dir["ghost-whitemane"].faction, "Horde", "unknown faction filled in")
    eq(t, dir["ghost-whitemane"].realm, "whitemane", "unknown realm filled in")

    -- ── merge: local always wins, peers fold in deterministically ─────────────
    local merged = F.MergeDirectories(
        { ["mine-whitemane"] = { name = "Mine", realm = "whitemane", faction = "Alliance" } },
        {
            ["acct-b"] = {
                ["mine-whitemane"]  = { name = "Mine",  realm = "whitemane", faction = "Horde" },
                ["their-whitemane"] = { name = "Their", realm = "whitemane", faction = "Alliance" },
            },
        })
    eq(t, merged["mine-whitemane"].faction, "Alliance", "our own attribution beats a peer's")
    check(t, merged["their-whitemane"] ~= nil, "a peer-only recipient reaches the merged view")
    check(t, F.MergeDirectories(nil, nil) ~= nil, "nil inputs merge to an empty map, never nil")

    -- ── THE SKIP MATRIX ───────────────────────────────────────────────────────
    local function mkCtx(over)
        local c = { enabled = true, me = "Hero", realm = "whitemane", faction = "Alliance",
                    friends = {}, marked = {}, numFriends = 0, maxFriends = 100 }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end
    local ally = { name = "Bankalt", realm = "whitemane", faction = "Alliance" }
    local function act(entry, over, key)
        return (F.Decide(key or "bankalt-whitemane", entry, mkCtx(over)))
    end

    eq(t, act(ally), "add", "same realm + same faction + not a friend -> add")
    eq(t, act(ally, { enabled = false }), "skip", "setting off -> skip")
    eq(t, act({ name = "Hero", realm = "whitemane", faction = "Alliance" }, nil, "hero-whitemane"),
       "skip", "the current character is never friended")
    eq(t, act(ally, { marked = { ["bankalt-whitemane"] = true } }), "skip",
       "a recipient already handled here is never re-added (a deliberate unfriend stands)")
    eq(t, act({ name = "Bankalt", realm = "faerlina", faction = "Alliance" }), "skip", "other realm -> skip")
    eq(t, act({ name = "Bankalt", realm = "whitemane", faction = "Horde" }), "skip", "other faction -> skip")
    eq(t, act(ally, { friends = { bankalt = true } }), "mark",
       "already on the friends list -> mark only, no add")
    eq(t, act(ally, { numFriends = 100 }), "cap", "friends list full -> cap")
    eq(t, act(ally, { numFriends = 100, maxFriends = 150 }), "add", "a higher cap still allows the add")
    eq(t, act({ name = "Bankalt", realm = "whitemane", faction = nil }), "add",
       "unknown faction is attempted, not silently dropped")
    eq(t, act({ name = "Bankalt", realm = "", faction = "Alliance" }), "add",
       "unknown realm is attempted, not silently dropped")
    eq(t, act(nil), "skip", "nil entry -> skip, never an error")
    eq(t, act({ name = "" }), "skip", "empty name -> skip")

    -- ── the plan: deterministic order, cap consumed across a batch ────────────
    local batch = {}
    for i = 1, 4 do
        batch["alt" .. i .. "-whitemane"] =
            { name = "Alt" .. i, realm = "whitemane", faction = "Alliance" }
    end
    local plan = F.Plan(batch, mkCtx({ numFriends = 98 }))
    eq(t, #plan, 4, "every directory entry appears in the plan")
    eq(t, plan[1].key, "alt1-whitemane", "plan is sorted by canonical key")
    eq(t, plan[1].action, "add", "first add fits")
    eq(t, plan[2].action, "add", "second add fills the last slot")
    eq(t, plan[3].action, "cap", "third hits the cap")
    eq(t, plan[4].action, "cap", "and so does the fourth (no doomed AddFriend calls)")

    local plan2 = F.Plan(batch, mkCtx())
    local adds = 0
    for _, s in ipairs(plan2) do if s.action == "add" then adds = adds + 1 end end
    eq(t, adds, 4, "with room, every entry is added")
    eq(t, #F.Plan(nil, mkCtx()), 0, "a nil directory plans nothing")

    return report(t, verbose)
end)

-- ── Suite 8: cross-account bridge probe + payload (pure; syncbridge.lua) ───────
ns:RegisterSelfTest("sync-bridge", function(verbose)
    local t = newT("sync-bridge")
    local B = ns.SyncBridge

    -- A minimal v2-shaped Daseeki.Sync surface (the exact functions we call).
    local function fakeSync(version)
        return { Daseeki = { Sync = {
            VERSION = version,
            RegisterNamespace = function() end,
            MarkDirty         = function() end,
            DeliverRemote     = function() end,
        } } }
    end
    local function why(G) return select(2, B.Sync(G)) end

    -- ── the guarded probe: every failure has a readable reason, none error ────
    check(t, B.Sync({}) == nil, "no Daseeki namespace -> no store")
    check(t, why({}):find("not installed") ~= nil, "absence gives a readable reason")
    check(t, B.Sync({ Daseeki = {} }) == nil, "Daseeki without Sync -> no store")
    check(t, B.Sync({ Daseeki = { Sync = {} } }) == nil, "Sync without the namespace API -> no store")

    local v1 = fakeSync(1)
    check(t, B.Sync(v1) == nil, "a v1 Sync store is refused")
    check(t, why(v1):find("v2") ~= nil, "the refusal names the version it needs")

    local v2 = fakeSync(2)
    check(t, B.Sync(v2) ~= nil, "a v2 Sync store is accepted")
    check(t, B.Available(v2) == true, "Available() agrees")
    check(t, B.Available({}) == false, "...and is false with no Nexus at all")

    -- ── payload round-trip ────────────────────────────────────────────────────
    local dir = {
        ["bankalt-whitemane"] = { name = "Bankalt", realm = "whitemane", faction = "Alliance", ts = 5 },
        ["vault-whitemane"]   = { name = "Vault",   realm = "whitemane", faction = "Alliance", ts = 6 },
        ["junk-whitemane"]    = { name = "",        realm = "whitemane" },   -- unnamed: never ships
    }
    local payload = B.BuildPayload(dir, 1700000000)
    eq(t, payload.v, B.PAYLOAD_VERSION, "payload carries its version")
    eq(t, payload.ts, 1700000000, "payload carries its stamp")
    check(t, payload.recipients["junk-whitemane"] == nil, "an unnamed entry never ships")

    local parsed, rejected = B.ParsePayload(payload)
    check(t, parsed ~= nil and rejected == nil, "our own payload parses back")
    eq(t, parsed["bankalt-whitemane"].name, "Bankalt", "name survives the round-trip")
    eq(t, parsed["bankalt-whitemane"].faction, "Alliance", "faction survives the round-trip")

    -- ── a peer cannot smuggle junk (or a future shape) past us ────────────────
    check(t, B.ParsePayload(nil) == nil, "nil payload refused")
    check(t, B.ParsePayload("nope") == nil, "non-table payload refused")
    check(t, B.ParsePayload({ v = 1 }) == nil, "payload without a recipients map refused")
    check(t, select(2, B.ParsePayload({ v = 99, recipients = {} })):find("newer") ~= nil,
       "a payload newer than this build reads is refused, not guessed at")

    local dirty = B.ParsePayload({ v = 1, recipients = {
        ["ok-whitemane"]     = { name = "Ok",  realm = "whitemane", faction = "Alliance" },
        ["bad-faction"]      = { name = "Bad", realm = "whitemane", faction = "Pirates" },
        ["noname-whitemane"] = { name = "" },
        [42]                 = { name = "Numeric" },
        ["nottable"]         = "nope",
    } })
    eq(t, dirty["ok-whitemane"].name, "Ok", "the good entry survives sanitising")
    check(t, dirty["bad-faction"].faction == nil, "an unknown faction string is dropped to nil")
    check(t, dirty["noname-whitemane"] == nil, "an unnamed entry is dropped")
    check(t, dirty[42] == nil, "a non-string key is dropped")
    check(t, dirty["nottable"] == nil, "a non-table entry is dropped")

    return report(t, verbose)
end)
