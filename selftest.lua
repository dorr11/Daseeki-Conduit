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


-- ── Suite 9: the Nexus roster read + the Alt picker's rows (pure; network.lua) ─
--
-- The picker reads ANOTHER addon's SavedVariables, so every fixture below is a
-- hand-built fake `G`: the real _G is never touched and no test can depend on
-- whether Nexus happens to be installed.
ns:RegisterSelfTest("network", function(verbose)
    local t = newT("network")
    local N = ns.Network

    local ME = { name = "Hero", realm = "Whitemane", faction = "Alliance" }

    local function alts(data, me) return N.CollectAlts({ DaseekiNexusData = data }, me or ME) end
    local function collect(data, me) return N.CollectAltNames({ DaseekiNexusData = data }, me or ME) end
    local function joined(data, me) return table.concat(collect(data, me), ",") end
    local function bucket(chars, homeless)
        return { isSelf = true, characters = chars or {}, homeless = homeless or {},
                 segments = {}, segmentHashes = {} }
    end
    local function inv(owners, schema) return { schema = schema or 1, owners = owners } end
    -- The one entry a fixture produced, by base name.
    local function entry(data, name, me)
        for _, e in ipairs(alts(data, me)) do if e.name == name then return e end end
        return nil
    end

    -- ── absence: no Nexus, or junk where the store should be ──────────────────
    eq(t, #N.CollectAltNames({}, ME), 0, "no Nexus store -> empty list")
    eq(t, #N.CollectAltNames(nil, ME), 0, "the live globals carry no Nexus store headless")
    eq(t, #N.CollectAltNames("nope", ME), 0, "a non-table global environment -> empty")
    eq(t, #collect("nope"), 0, "a string where the store should be -> empty")
    eq(t, #collect(42), 0, "a number where the store should be -> empty")
    eq(t, #collect({}), 0, "a store with neither area -> empty")

    -- ── malformed areas fall through, they never error ────────────────────────
    eq(t, #collect({ accounts = "nope" }), 0, "accounts not a table -> empty")
    eq(t, #collect({ accounts = { ["1"] = "nope" } }), 0, "a bucket that is not a table -> empty")
    eq(t, #collect({ accounts = { ["1"] = { characters = 7, homeless = "x" } } }), 0,
       "characters / homeless that are not tables -> empty")
    eq(t, #collect({ inventory = "nope" }), 0, "inventory not a table -> empty")
    eq(t, #collect({ inventory = { schema = 1, owners = 5 } }), 0, "owners not a table -> empty")
    eq(t, #collect({ accounts = { ["1"] = bucket({
        [42] = {}, ["NoHyphen"] = {}, ["-Whitemane"] = {}, ["Trailing-"] = {} }) } }), 0,
       "non-string and unparseable keys are skipped")

    -- Guild and friend lists are OTHER PEOPLE. They are never alts and never read.
    eq(t, #collect({ social = { guild = { ["Guildie-Whitemane"] = { faction = "Alliance" } } } }), 0,
       "the social area is never read")

    -- ── two areas, two independent version gates ──────────────────────────────
    eq(t, joined({ accounts = { ["1"] = bucket({ ["Nostamp-Whitemane"] = {} }) } }), "Nostamp",
       "an unstamped graph is read, not refused")
    eq(t, joined({
        version   = 99,
        accounts  = { ["1"] = bucket({ ["Refused-Whitemane"] = {} }) },
        inventory = inv({ ["Kept-Whitemane"] = { rev = 1, data = {} } }),
    }), "Kept", "a newer storage version refuses the accounts graph ONLY")
    eq(t, joined({
        version   = 1,
        accounts  = { ["1"] = bucket({ ["Kept-Whitemane"] = {} }) },
        inventory = inv({ ["Refused-Whitemane"] = { rev = 1, data = {} } }, 99),
    }), "Kept", "a newer inventory schema refuses that area ONLY")

    -- ── the union, and the dedupe across it ───────────────────────────────────
    eq(t, joined({
        version   = 1,
        accounts  = { ["1"] = bucket({ ["Graphonly-Whitemane"] = {}, ["Shared-Whitemane"] = {} }) },
        inventory = inv({
            ["Invonly-Whitemane"] = { rev = 1, updatedAt = 5, data = {} },
            ["shared-Whitemane"]  = { rev = 1, updatedAt = 5, data = {} },  -- same character, other case
        }),
    }), "Graphonly,Invonly,Shared",
       "both graphs contribute and a name in both appears once (first spelling wins)")

    -- ── every bucket counts, including "" and the homeless table ──────────────
    eq(t, joined({ accounts = {
        [""]  = bucket({ ["Orphan-Whitemane"] = {} }),               -- unattributed characters
        ["7"] = bucket(nil, { ["Drifter-Whitemane"] = {} }),         -- no manifest slot yet
    } }), "Drifter,Orphan", "the orphan bucket and homeless records both contribute")

    -- ── never offer the current character ─────────────────────────────────────
    eq(t, joined({ accounts = { ["1"] = bucket({
        ["hero-Whitemane"] = {}, ["Alt-Whitemane"] = {} }) } }), "Alt",
       "the current character is excluded whatever its capitalisation")

    -- ── same realm only (a bare-name recipient is same-realm mail) ────────────
    local twoRealms = { accounts = { ["1"] = bucket({
        ["Near-Whitemane"] = {}, ["Far-Faerlina"] = {} }) } }
    eq(t, joined(twoRealms), "Near", "another realm is dropped")
    eq(t, joined(twoRealms, { name = "Hero", realm = nil, faction = "Alliance" }), "Far,Near",
       "an unknown player realm skips the realm filter entirely")
    eq(t, joined({ accounts = { ["1"] = bucket({ ["Pirate-BloodSailBuccaneers"] = {} }) } },
                 { name = "Hero", realm = "Blood Sail Buccaneers", faction = "Alliance" }), "Pirate",
       "a spaced player realm matches the space-stripped key realm")

    -- ── FACTION: labelled, never filtered ─────────────────────────────────────
    --
    -- DaseekiConduitDB is account-wide and `rules` is a flat array, so a rule
    -- authored here runs on every character on the account. The editing character's
    -- faction therefore cannot decide who the rule may name; friends.lua Decide
    -- makes that call per character at the mailbox ("skip"/"other faction").
    local mixed = { accounts = { ["1"] = bucket({
        ["Ally-Whitemane"]    = { faction = "Alliance" },
        ["Hordie-Whitemane"]  = { faction = "Horde" },
        ["Unknown-Whitemane"] = {},                        -- no faction field at all
        ["Garbage-Whitemane"] = { faction = "Pirates" },   -- uncomparable: reads as unknown
    }) } }
    eq(t, joined(mixed), "Ally,Garbage,Unknown,Hordie",
       "every faction is offered; the explicit other-faction row sorts to the tail")
    eq(t, entry(mixed, "Hordie").otherFaction, true, "the other-faction row is flagged")
    eq(t, entry(mixed, "Hordie").faction, "Horde", "...and keeps the faction it was seen with")
    eq(t, entry(mixed, "Ally").otherFaction, nil, "our own faction is never flagged")
    eq(t, entry(mixed, "Unknown").otherFaction, nil, "an absent faction is not a conflict")
    eq(t, entry(mixed, "Unknown").faction, nil, "...and is recorded as unknown, not guessed")
    eq(t, entry(mixed, "Garbage").faction, nil, "an uncomparable faction string reads as unknown")
    eq(t, joined(mixed, { name = "Hero", realm = "Whitemane", faction = nil }),
       "Ally,Garbage,Hordie,Unknown", "an unknown player faction flags nothing, so nothing tails")

    eq(t, joined({ inventory = inv({ ["Redside-Whitemane"] = { data = { faction = "Horde" } } }) }),
       "Redside", "the inventory graph's faction lives on entry.data")
    eq(t, entry({ inventory = inv({ ["Redside-Whitemane"] = { data = { faction = "Horde" } } }) },
                "Redside").otherFaction, true, "...and flags from there too")
    eq(t, joined({ inventory = inv({ ["Noside-Whitemane"] = { rev = 1 } }) }), "Noside",
       "an inventory entry carrying no payload is unknown-faction, not excluded")

    local split = {
        accounts  = { ["1"] = bucket({ ["Split-Whitemane"] = { faction = "Horde" } }) },
        inventory = inv({ ["Split-Whitemane"] = { data = { faction = "Alliance" } } }),
    }
    eq(t, entry(split, "Split").faction, "Alliance",
       "a sighting that matches US wins over one that does not, whichever graph it came from")
    eq(t, entry(split, "Split").otherFaction, nil, "...so a disputed alt is never mislabelled")
    local bothOther = {
        accounts  = { ["1"] = bucket({ ["Gone-Whitemane"] = { faction = "Horde" } }) },
        inventory = inv({ ["Gone-Whitemane"] = { data = { faction = "Horde" } } }),
    }
    eq(t, #alts(bothOther), 1, "an entry EVERY graph calls other-faction is still OFFERED")
    eq(t, entry(bothOther, "Gone").otherFaction, true, "...and is the one that gets the tag")

    -- ── class token: two graphs, two spellings ────────────────────────────────
    eq(t, entry({ accounts = { ["1"] = bucket({
        ["Locky-Whitemane"] = { classTag = "WARLOCK" } }) } }, "Locky").class, "WARLOCK",
       "the character graph's classTag is read")
    eq(t, entry({ inventory = inv({
        ["Sneaky-Whitemane"] = { data = { class = "rogue" } } }) }, "Sneaky").class, "ROGUE",
       "the inventory payload's `class` is read and normalised upper-case")
    eq(t, entry({ accounts = { ["1"] = bucket({
        ["Nameless-Whitemane"] = { classTag = "" } }) } }, "Nameless").class, nil,
       "an empty class token reads as unknown")
    eq(t, entry({ accounts = { ["1"] = bucket({
        ["Weird-Whitemane"] = { classTag = 7, class = {} } }) } }, "Weird").class, nil,
       "a non-string class token reads as unknown")
    eq(t, entry({
        accounts  = { ["1"] = bucket({ ["Both-Whitemane"] = { classTag = "MAGE" } }) },
        inventory = inv({ ["Both-Whitemane"] = { data = { class = "PRIEST" } } }),
    }, "Both").class, "MAGE", "the character graph wins the class when both graphs answer")

    -- ── output shape: base names, deterministic order ─────────────────────────
    local ordered = collect({ accounts = { ["1"] = bucket({
        ["zeta-Whitemane"] = {}, ["Alpha-Whitemane"] = {}, ["mid-Whitemane"] = {} }) } })
    eq(t, table.concat(ordered, ","), "Alpha,mid,zeta", "sorted case-insensitively, not by byte")
    local suffixed = false
    for _, n in ipairs(ordered) do if n:find("-", 1, true) then suffixed = true end end
    check(t, not suffixed, "every row is a base name (the realm suffix is stripped)")
    eq(t, entry({ accounts = { ["1"] = bucket({ ["Near-Whitemane"] = {} }) } }, "Near").realm,
       "Whitemane", "each entry carries the realm its key named")

    -- ── the label layer ───────────────────────────────────────────────────────
    local PALETTE = {
        WARLOCK = { colorStr = "ff8787ed" },
        ROGUE   = { r = 1, g = 0.96, b = 0.41 },
        DRUID   = { r = "bad", g = 0, b = 0 },
    }
    eq(t, N.AltLabel({ name = "Plain" }), "Plain", "no class and no faction -> the bare name")
    eq(t, N.AltLabel({ name = "Plain" }, { classColors = PALETTE }), "Plain",
       "an unknown class is not coloured")
    eq(t, N.AltLabel({ name = "Locky", class = "WARLOCK" }, { classColors = PALETTE }),
       "|cff8787edLocky|r", "a colorStr palette entry colours the name")
    eq(t, N.AltLabel({ name = "Sneaky", class = "ROGUE" }, { classColors = PALETTE }),
       "|cfffff569Sneaky|r", "an r/g/b palette entry is converted to an escape")
    eq(t, N.AltLabel({ name = "Bear", class = "DRUID" }, { classColors = PALETTE }), "Bear",
       "a malformed palette entry degrades to plain text")
    eq(t, N.AltLabel({ name = "Locky", class = "WARLOCK" }), "Locky",
       "no palette at all (headless / early login) degrades to plain text")
    eq(t, N.AltLabel({ name = "Hordie", faction = "Horde", otherFaction = true }),
       "Hordie (Horde)", "a cross-faction row is tagged with the faction it is on")
    eq(t, N.AltLabel({ name = "Hordie", faction = "Horde", otherFaction = true },
                     { tagColor = "|cffA79B84" }),
       "Hordie |cffA79B84(Horde)|r", "the tag takes the muted colour when one is supplied")
    eq(t, N.AltLabel({ name = "Hordie", faction = "Horde", otherFaction = true },
                     { tagColor = "not an escape" }),
       "Hordie (Horde)", "a junk tag colour is ignored, not concatenated")
    eq(t, N.AltLabel({ name = "Quiet", faction = "Horde" }), "Quiet",
       "a faction alone never tags -- only an explicit conflict does")
    eq(t, N.AltLabel({ name = "Nofaction", otherFaction = true }), "Nofaction",
       "a flag with no faction to name produces no tag")
    eq(t, N.AltLabel(nil), "", "a nil entry labels as empty, never an error")
    eq(t, N.AltLabel({ name = 42 }), "", "a non-string name labels as empty")
    eq(t, N.ClassColorEscape("WARLOCK", nil), "", "no palette -> no escape")
    eq(t, N.ClassColorEscape(nil, PALETTE), "", "no class -> no escape")
    eq(t, N.ClassColorEscape("WARLOCK", "nope"), "", "a non-table palette -> no escape")

    -- ── the choice list handed to the dropdown ────────────────────────────────
    local choices = N.BuildAltChoices(alts(mixed), { classColors = PALETTE })
    eq(t, #choices, 4, "every collected alt becomes one row")
    eq(t, choices[1].value, "Ally", "rows carry the BARE NAME as their value...")
    eq(t, choices[1].text, "Ally", "...and the label as their text")
    eq(t, choices[4].value, "Hordie", "the cross-faction row is last and still selectable")
    eq(t, choices[4].text, "Hordie (Horde)", "...carrying its tag")
    local sameAsTyped = true
    for _, c in ipairs(choices) do
        if c.value:find("|", 1, true) or c.value:find("(", 1, true) then sameAsTyped = false end
    end
    check(t, sameAsTyped,
       "no row's value carries decoration -- picking equals typing the same name")
    eq(t, #N.BuildAltChoices(nil), 0, "a nil entry list builds no rows")
    eq(t, #N.BuildAltChoices({ "junk", {}, { name = 7 }, { name = "Ok" } }), 1,
       "junk entries are skipped, real ones survive")

    -- ── FIRST-EXPLICIT-WINS IS A RULE, NOT A COIN FLIP (CDT-1, async Class 8) ──
    --
    -- The fold decides class, faction and — the one that leaves the addon — the
    -- SPELLING of the name by first sighting. That is only a rule if the walk that
    -- produces "first" is ordered. Under a raw `pairs()` walk the winner was
    -- whichever entry the table handed over first, so two accounts holding
    -- "Bankalt" and "bankalt" could put a different spelling on a mail recipient
    -- between logins, and the same alt could be a warrior on Monday and a mage on
    -- Tuesday in the dropdown's colouring.
    --
    -- Each fixture below is chosen ADVERSARIALLY: its raw `pairs()` order is the
    -- reverse of its sorted order in this interpreter, so the assertion really is
    -- discriminating. `rawFirst` proves that, so a fixture that stops being
    -- adverse fails here instead of quietly passing for the wrong reason.
    local function rawFirst(tbl)
        for k in pairs(tbl) do return k end
    end
    -- The winner is read through this rather than indexed directly: when the walk
    -- is unordered the sorted-first spelling is simply ABSENT, and a nil index
    -- would abort the suite with a stack trace instead of naming the row.
    local function classOf(data, name) local e = entry(data, name); return e and e.class end
    local function spellingOf(data, name) local e = entry(data, name); return e and e.name end

    -- (a) two ACCOUNT buckets holding the same character, spelled differently.
    local twoAccounts = {
        acctA = bucket({ ["Bankalt-Whitemane"] = { classTag = "WARRIOR" } }),
        acctB = bucket({ ["BANKALT-Whitemane"] = { classTag = "MAGE" } }),
    }
    eq(t, rawFirst(twoAccounts), "acctB",
       "fixture check: pairs() really does hand over the LATER account first")
    eq(t, classOf({ accounts = twoAccounts }, "Bankalt"), "WARRIOR",
       "the sorted-first account decides the class, not whichever pairs() dealt")
    eq(t, #alts({ accounts = twoAccounts }), 1, "...and the two spellings still fold to one row")

    -- (b) two SPELLINGS inside one bucket. The winning spelling is what the picker
    --     writes into a rule and what the mail form is addressed with.
    local twoSpellings = {
        ["Bankalt-Whitemane"] = { classTag = "WARRIOR" },
        ["bankalt-Whitemane"] = { classTag = "MAGE" },
    }
    eq(t, rawFirst(twoSpellings), "bankalt-Whitemane",
       "fixture check: pairs() really does hand over the lower-case spelling first")
    eq(t, spellingOf({ accounts = { ["1"] = bucket(twoSpellings) } }, "Bankalt"), "Bankalt",
       "the sorted-first SPELLING is the one recorded, so the recipient is stable")
    eq(t, classOf({ accounts = { ["1"] = bucket(twoSpellings) } }, "Bankalt"), "WARRIOR",
       "...and it brings its own class with it")

    -- (c) the same, in the homeless table and in the inventory owners map — every
    --     walk that feeds the fold, not just the one that was noticed.
    local homelessPair = {
        ["Wanderer-Whitemane"] = { classTag = "PRIEST" },
        ["wanderer-Whitemane"] = { classTag = "ROGUE" },
    }
    eq(t, rawFirst(homelessPair), "wanderer-Whitemane", "fixture check: homeless pairs() is adverse")
    eq(t, classOf({ accounts = { ["1"] = bucket(nil, homelessPair) } }, "Wanderer"), "PRIEST",
       "the homeless walk is ordered too")

    local ownerPair = {
        ["Owner-Whitemane"] = { rev = 1, data = { class = "HUNTER" } },
        ["owner-Whitemane"] = { rev = 1, data = { class = "WARLOCK" } },
    }
    eq(t, rawFirst(ownerPair), "owner-Whitemane", "fixture check: owners pairs() is adverse")
    eq(t, classOf({ inventory = inv(ownerPair) }, "Owner"), "HUNTER",
       "the inventory owners walk is ordered too")

    -- And the ordering never overrides the rules the fold already had: the accounts
    -- graph still beats the inventory graph, and a faction matching OURS still wins
    -- outright regardless of who was seen first.
    eq(t, classOf({
        accounts  = { ["zzz"] = bucket({ ["Both-Whitemane"] = { classTag = "MAGE" } }) },
        inventory = inv({ ["aaa-Whitemane"] = { data = { class = "PRIEST" } },
                          ["Both-Whitemane"] = { data = { class = "PRIEST" } } }),
    }, "Both"), "MAGE",
       "sorting is within an area; the accounts graph still wins the class overall")

    -- ── the no-error contract, against deliberately hostile junk ──────────────
    local hostile = {
        version   = "banana",
        accounts  = {
            [1]   = { characters = { [true] = {}, ["A-B"] = 7 }, homeless = 3 },
            ["x"] = {},
            [2]   = false,
        },
        inventory = { schema = {}, owners = { ["Q-Whitemane"] = 5, [{}] = {} } },
        social    = { guild = { ["Someone-Whitemane"] = true } },
    }
    local okRun, res = pcall(N.CollectAlts, { DaseekiNexusData = hostile }, ME)
    check(t, okRun, "a deliberately hostile saved table never errors")
    check(t, okRun and type(res) == "table", "...and still returns a list")
    local okBuild, rows = pcall(N.BuildAltChoices, okRun and res or nil, { classColors = hostile })
    check(t, okBuild and type(rows) == "table",
       "...and the rows built from it never error either")

    return report(t, verbose)
end)

-- ── Suite 10: mailbox teardown — the panel closes with the mail window ─────────
--
-- The owner rule: when the mail window closes, Conduit closes. core.lua's teardown
-- coordinator is what makes that true for EVERY route out (walking away from the
-- mailbox, Escape, the mail window's ✕, another panel taking its slot) and for
-- everything the mailbox owns (the rule panel, an in-flight batch, the confirm
-- popup). This suite drives the coordinator's two pure halves directly — the latch
-- and the closer fan-out — so it never fires the LIVE closers and is therefore safe
-- to run at an open mailbox.
ns:RegisterSelfTest("mailbox-close", function(verbose)
    local t = newT("mailbox-close")

    -- ── the latch: exactly one teardown per mailbox visit ─────────────────────
    local savedOpen = ns.mailboxOpen           -- never disturb a live mailbox
    check(t, ns.ConsumeMailboxOpen ~= nil, "the coordinator exposes its latch")

    ns.mailboxOpen = false
    eq(t, ns:ConsumeMailboxOpen(), false, "closing with no mailbox open is a no-op")

    ns:MailboxOpened()
    eq(t, ns.mailboxOpen, true, "MAIL_SHOW arms the teardown")
    eq(t, ns:ConsumeMailboxOpen(), true, "the first close signal tears down")
    eq(t, ns:ConsumeMailboxOpen(), false,
       "the second signal of the same visit does nothing (MAIL_CLOSED + OnHide collapse)")

    ns:MailboxOpened()
    eq(t, ns:ConsumeMailboxOpen(), true, "re-opening the mailbox re-arms it")
    ns.mailboxOpen = savedOpen

    -- ── the fan-out: order, completeness, error isolation ─────────────────────
    local log = {}
    local closers = {
        function(reason) log[#log + 1] = "abort:" .. tostring(reason) end,
        function() log[#log + 1] = "hidePanel" end,
    }
    eq(t, ns.RunClosers(closers, "MAIL_CLOSED"), 2, "every closer runs")
    eq(t, log[1], "abort:MAIL_CLOSED", "the batch abort runs first (load order = run order)")
    eq(t, log[2], "hidePanel", "...and the panel hides after it")

    -- The whole point of isolating them: a module that blows up on the way out must
    -- not leave the panel stranded on screen.
    local errs, ran = {}, {}
    local hostile = {
        function() error("closer one exploded") end,
        function() ran[#ran + 1] = "panel" end,
    }
    eq(t, ns.RunClosers(hostile, "MAIL_CLOSED", function(e) errs[#errs + 1] = e end), 2,
       "a closer that errors does not stop the rest")
    eq(t, ran[1], "panel", "the panel still hides after an earlier closer errored")
    eq(t, #errs, 1, "the error is surfaced, not swallowed")

    -- Defensive shapes: teardown must never be the thing that errors.
    eq(t, ns.RunClosers(nil, "x"), 0, "a missing closer list is a clean no-op")
    eq(t, ns.RunClosers({}, "x"), 0, "an empty closer list is a clean no-op")
    check(t, pcall(ns.RunClosers, closers, nil), "a nil reason never errors")

    -- ── the OTHER half: MailFrame's hooks install exactly once ────────────────
    --
    -- A HookScript cannot be undone, so a second installation is permanent double
    -- work on every open and close of the player's mail window — and the whole
    -- OnShow refresh path hangs off this guard. Driven against a STAND-IN frame:
    -- hooking the real MailFrame from a self-test would leave that hook behind
    -- forever, and /conduit debug selftest is run at open mailboxes.
    check(t, ns.HookOnce ~= nil, "the coordinator exposes its install-once guard")

    local installs, state = {}, {}
    local stand = { HookScript = function(_, ev) installs[#installs + 1] = ev end }
    local scripts = { { "OnHide", function() end }, { "OnShow", function() end } }

    eq(t, ns.HookOnce(state, stand, scripts), true, "the first call installs")
    eq(t, #installs, 2, "...both scripts, in one pass")
    eq(t, installs[1], "OnHide", "OnHide installs first (declared order, not pairs order)")
    eq(t, installs[2], "OnShow", "...then OnShow, the visibility signal")

    eq(t, ns.HookOnce(state, stand, scripts), false, "the second call is a no-op")
    eq(t, ns.HookOnce(state, stand, scripts), false, "...and so is every one after it")
    eq(t, #installs, 2, "no script is ever hooked twice")

    -- A fresh state hooks a fresh target: the latch is per-target, not global.
    local state2 = {}
    eq(t, ns.HookOnce(state2, stand, { { "OnShow", function() end } }), true,
       "an independent guard installs independently")

    -- Defensive shapes: the install must never be the thing that errors.
    eq(t, ns.HookOnce({}, nil, scripts), false, "a missing target installs nothing")
    eq(t, ns.HookOnce({}, {}, scripts), false, "a target with no HookScript installs nothing")
    eq(t, ns.HookOnce({}, stand, nil), true, "no scripts is a clean latch")
    eq(t, ns.HookOnce(nil, stand, scripts), false, "a missing guard installs nothing")

    -- ── and the refreshers fan out like the closers, WITHOUT the latch ────────
    -- Refreshers are idempotent redraws: every OnShow must re-ask, so unlike the
    -- teardown there is nothing here that fires only once per visit.
    check(t, ns.RegisterMailboxRefresher ~= nil, "the coordinator accepts refreshers")
    check(t, ns.MailboxShown ~= nil, "...and exposes the fan-out")
    local redraws = {}
    local refreshers = { function(reason) redraws[#redraws + 1] = tostring(reason) end }
    eq(t, ns.RunClosers(refreshers, "mail window shown"), 1, "a refresher runs")
    eq(t, ns.RunClosers(refreshers, "mail window shown"), 1, "and runs AGAIN on the next show")
    eq(t, #redraws, 2, "no latch consumes the second redraw")

    return report(t, verbose)
end)

-- ══════════════════════════════════════════════════════════════════════════════
--  Suites 11-13: Chronoboon replenishment (pure; boons.lua)
--
--  The plan builder is the piece that decides who gets ten scarce consumables and
--  who gets none, off a snapshot that is always a little bit out of date. It is
--  therefore the most heavily asserted thing in this addon, AND the harness
--  mutation-tests it (GATE MUT) — these checks exist to be strong enough to kill
--  a mutant, not merely to describe the happy path.
-- ══════════════════════════════════════════════════════════════════════════════

-- One roster row, Network.CollectAlts-shaped, for the fixtures below.
local function boonChar(name, level, have, opts)
    opts = opts or {}
    local e = { name = name, realm = "Whitemane", level = level,
                faction = opts.faction, class = opts.class }
    if have ~= nil then
        e.counts   = { [184937] = have }
        e.countsAt = opts.at
    end
    return e
end

ns:RegisterSelfTest("boon-plan", function(verbose)
    local t = newT("boon-plan")
    local B = ns.Boons

    eq(t, B.ITEM_ID, 184937, "the item is the Chronoboon Displacer (Classic Era id)")
    eq(t, B.TARGET, 10, "a full pocket is ten")
    eq(t, B.MIN_LEVEL, 60, "only level 60 is worth stocking")

    local function plan(entries, over)
        local o = { source = "Bankalt", faction = "Alliance", stock = 999 }
        for k, v in pairs(over or {}) do o[k] = v end
        return B.BuildPlan(entries, o)
    end
    local function byName(p, name)
        for _, x in ipairs(p.targets) do if x.name == name then return x end end
        return nil
    end
    local function order(p)
        local out = {}
        for _, x in ipairs(p.targets) do out[#out + 1] = x.name .. ":" .. x.send end
        return table.concat(out, ",")
    end
    local function skipKind(p, name)
        for _, s in ipairs(p.skipped) do if s.name == name then return s.kind end end
        return nil
    end

    -- ── THE OWNER'S EXAMPLE, VERBATIM ─────────────────────────────────────────
    -- "Poonyx has 3, Shalk 9, Orn 0 -> send 7, 1, 10."
    local mesh = { boonChar("Poonyx", 60, 3), boonChar("Shalk", 60, 9), boonChar("Orn", 60, 0) }
    local p = plan(mesh)
    eq(t, #p.targets, 3, "all three characters are in the plan")
    eq(t, byName(p, "Poonyx").send, 7, "Poonyx has 3 -> send 7")
    eq(t, byName(p, "Shalk").send,  1, "Shalk has 9 -> send 1")
    eq(t, byName(p, "Orn").send,   10, "Orn has 0 -> send 10")
    eq(t, p.totalNeed, 18, "18 boons needed in total")
    eq(t, p.totalSend, 18, "...and with stock to spare, 18 go")
    eq(t, p.shortfall, 0, "no shortfall when stock covers it")
    eq(t, p.mailCount, 3, "three mails, one per character")
    -- Biggest need first, always: the send ORDER is the rationing rule made visible.
    eq(t, order(p), "Orn:10,Poonyx:7,Shalk:1", "the plan is ordered by descending need")

    -- ── an absent count is a full ten, not an exclusion ───────────────────────
    local noData = plan({ boonChar("Ghost", 60, nil) })
    eq(t, #noData.targets, 1, "a character with no inventory snapshot is still planned for")
    eq(t, byName(noData, "Ghost").have, 0, "...reading as zero held")
    eq(t, byName(noData, "Ghost").send, 10, "...and therefore needing a full ten")
    eq(t, byName(noData, "Ghost").hasData, nil, "...flagged as having no snapshot behind it")
    eq(t, byName(noData, "Ghost").ageText, nil, "...and no age to show for it")

    -- ── already stocked is not a target ───────────────────────────────────────
    local full = plan({ boonChar("Full", 60, 10), boonChar("Over", 60, 14) })
    eq(t, #full.targets, 0, "a character at ten (or over) is not mailed")
    eq(t, skipKind(full, "Full"), "stocked", "...and is reported as stocked, not silently dropped")
    eq(t, skipKind(full, "Over"), "stocked", "...over ten too (never a negative send)")
    eq(t, full.totalNeed, 0, "nothing needed")

    -- ── the three filters ─────────────────────────────────────────────────────
    local filtered = plan({
        boonChar("Bankalt",  60, 0),                              -- the source itself
        boonChar("bankalt2", 60, 0),                              -- NOT the source
        boonChar("Lowbie",   19, 0),
        boonChar("Fiftynine",59, 0),
        boonChar("Sixtyone", 61, 0),                              -- boosted/unusual: still in
        boonChar("Nolevel",  nil, 0),
        boonChar("Zerolevel",  0, 0),
        boonChar("Hordie",   60, 0, { faction = "Horde" }),
        boonChar("Ally",     60, 0, { faction = "Alliance" }),
        boonChar("Unknownside", 60, 0),                           -- no faction recorded
    })
    eq(t, skipKind(filtered, "Bankalt"), "source", "the source never mails itself")
    check(t, byName(filtered, "bankalt2") ~= nil,
       "a DIFFERENT name that merely starts the same is not mistaken for the source")
    eq(t, skipKind(filtered, "Lowbie"), "level", "a low-level character is skipped")
    eq(t, skipKind(filtered, "Fiftynine"), "level", "fifty-nine is not sixty")
    check(t, byName(filtered, "Sixtyone") ~= nil, "above the minimum is still in")
    eq(t, skipKind(filtered, "Nolevel"), "unknownLevel",
       "an unrecorded level is EXCLUDED (ten boons on a bank mule is not recoverable)")
    eq(t, skipKind(filtered, "Zerolevel"), "unknownLevel", "level 0 is Nexus for 'never captured'")
    eq(t, skipKind(filtered, "Hordie"), "faction", "the other faction cannot be mailed")
    check(t, byName(filtered, "Ally") ~= nil, "our own faction is in")
    check(t, byName(filtered, "Unknownside") ~= nil,
       "an unrecorded faction is INCLUDED (a wrong guess only bounces the mail back)")
    eq(t, filtered.counts.unknownLevel, 2, "both unknown-level characters are counted")
    eq(t, filtered.counts.level, 2, "both under-level characters are counted")
    eq(t, filtered.counts.faction, 1, "the cross-faction character is counted")

    -- A source with no faction of its own filters nobody on faction.
    local noSide = B.BuildPlan({ boonChar("Hordie", 60, 0, { faction = "Horde" }) },
                               { source = "Bankalt", faction = nil, stock = 99 })
    eq(t, #noSide.targets, 1, "an unknown SOURCE faction filters nobody")

    -- The source match is on the base name, case-insensitively, realm suffix or not.
    eq(t, skipKind(plan({ boonChar("BANKALT", 60, 0) }), "BANKALT"), "source",
       "the source is matched case-insensitively")
    eq(t, skipKind(B.BuildPlan({ boonChar("Bankalt", 60, 0) },
        { source = "Bankalt-Whitemane", faction = "Alliance", stock = 9 }), "Bankalt"), "source",
       "a realm-qualified source still matches its own row")

    -- ── RATIONING: descending need, and what a shortfall looks like ───────────
    -- Stock 12 against the owner's 18: Orn's ten, then Poonyx gets the last two.
    local short = plan(mesh, { stock = 12 })
    eq(t, order(short), "Orn:10,Poonyx:2,Shalk:0", "the stock walks DOWN the need order")
    eq(t, short.totalSend, 12, "every boon in the bags is allocated")
    eq(t, short.shortfall, 6, "the shortfall is stated, not hidden")
    eq(t, short.remaining, 0, "nothing is left over")
    eq(t, byName(short, "Poonyx").partial, true, "the boundary character is flagged partial")
    eq(t, byName(short, "Shalk").partial, nil, "one that got nothing is not 'partial'")
    check(t, byName(short, "Shalk") ~= nil,
       "an unfunded character stays IN the plan (an omission is not a report)")
    eq(t, short.mailCount, 2, "only the funded characters become mails")

    -- Exactly enough, and one short of exactly enough.
    eq(t, plan(mesh, { stock = 18 }).shortfall, 0, "stock == need -> no shortfall")
    eq(t, plan(mesh, { stock = 17 }).shortfall, 1, "one under -> a shortfall of one")
    eq(t, order(plan(mesh, { stock = 17 })), "Orn:10,Poonyx:7,Shalk:0",
       "...and it is the SMALLEST need that goes without")

    -- No stock at all: a plan of zeros, never a crash and never a phantom mail.
    local dry = plan(mesh, { stock = 0 })
    eq(t, dry.totalSend, 0, "no stock sends nothing")
    eq(t, dry.mailCount, 0, "...and queues no mails")
    eq(t, dry.shortfall, 18, "...and the whole need is the shortfall")
    eq(t, #dry.targets, 3, "...while still naming everyone who needed some")

    -- Equal needs sort by name, so the plan never shuffles between sessions.
    local tie = plan({ boonChar("zeta", 60, 4), boonChar("Alpha", 60, 4), boonChar("mid", 60, 4) })
    eq(t, order(tie), "Alpha:6,mid:6,zeta:6", "equal needs are ordered by name, case-insensitively")

    -- ── STALENESS is carried, never computed away ─────────────────────────────
    local NOW = 1700000000
    local aged = B.BuildPlan({
        boonChar("Fresh",  60, 1, { at = NOW - 30 }),
        boonChar("Hourly", 60, 2, { at = NOW - 7200 }),
        boonChar("Daysold",60, 3, { at = NOW - 86400 * 4 }),
        boonChar("Nodate", 60, 4),
    }, { source = "Bankalt", faction = "Alliance", stock = 99, now = NOW })
    eq(t, byName(aged, "Fresh").ageText,   "just now", "a fresh count says so")
    eq(t, byName(aged, "Hourly").ageText,  "2h", "a two-hour-old count says so")
    eq(t, byName(aged, "Daysold").ageText, "4d", "a four-day-old count says so")
    eq(t, byName(aged, "Nodate").ageText,  nil, "an unstamped count has no age to claim")
    eq(t, byName(aged, "Fresh").age, 30, "the raw age is carried too")
    -- With no clock injected there are no ages at all — and no wrong ones.
    eq(t, byName(plan({ boonChar("X", 60, 1, { at = NOW }) }), "X").ageText, nil,
       "without a clock, no age is invented")

    eq(t, B.FormatAge(0), "just now", "zero seconds")
    eq(t, B.FormatAge(89), "just now", "under 90 seconds is still 'just now'")
    eq(t, B.FormatAge(90), "1m", "ninety seconds is a minute")
    eq(t, B.FormatAge(3599), "59m", "just under an hour")
    eq(t, B.FormatAge(3600), "1h", "an hour")
    eq(t, B.FormatAge(172799), "47h", "under two days is still hours")
    eq(t, B.FormatAge(172800), "2d", "two days")
    eq(t, B.FormatAge(-5), "just now", "a clock that ran backwards is not a negative age")
    eq(t, B.FormatAge(nil), nil, "no age in -> no age out")
    eq(t, B.FormatAge("soon"), nil, "junk in -> no age out")

    -- ── the no-error contract ─────────────────────────────────────────────────
    local hostile = { "junk", {}, { name = "" }, { name = 42 },
                      { name = "Ok", level = "sixty" },
                      { name = "Weird", level = 60, counts = "nope" },
                      { name = "Neg", level = 60, counts = { [184937] = -5 } },
                      { name = "Frac", level = 60, counts = { [184937] = 3.7 } } }
    local okRun, res = pcall(B.BuildPlan, hostile, { source = "Bankalt", stock = 99 })
    check(t, okRun, "a hostile roster never errors")
    check(t, okRun and type(res) == "table", "...and still returns a plan")
    eq(t, byName(res, "Weird").send, 10, "a junk counts map reads as zero held")
    eq(t, byName(res, "Neg").send, 10, "a negative count reads as zero held")
    eq(t, byName(res, "Frac").have, 3, "a fractional count is floored, never rounded up")
    check(t, byName(res, "Ok") == nil, "a non-numeric level is unknown, and unknown is out")
    check(t, pcall(B.BuildPlan, nil, nil), "nil inputs plan nothing, and do not error")
    eq(t, #B.BuildPlan(nil, nil).targets, 0, "...returning an empty plan")

    return report(t, verbose)
end)

ns:RegisterSelfTest("boon-arming", function(verbose)
    local t = newT("boon-arming")
    local B = ns.Boons

    -- `pairs` cannot carry a nil, and "this field is absent" is half the matrix, so
    -- an override of NIL means "delete the key" rather than "leave the default".
    local NIL = {}
    local function ctxOf(over)
        local c = { source = "Bankalt", me = "Bankalt", mailbox = true,
                    mesh = true, disabled = false, active = false }
        for k, v in pairs(over or {}) do c[k] = (v ~= NIL) and v or nil end
        return c
    end
    local function state(over) return (B.ButtonState(ctxOf(over))) end
    local function hint(over)  return (select(2, B.ButtonState(ctxOf(over)))) end

    -- ── THE MATRIX ────────────────────────────────────────────────────────────
    eq(t, state(), "armed", "the source, at a mailbox, with mesh data -> armed")
    eq(t, state({ mailbox = false }), "nomailbox", "the source with no mailbox open -> not armed")
    eq(t, state({ me = "Someoneelse" }), "elsewhere", "any other character -> not armed")
    eq(t, state({ source = NIL }), "off", "no source designated -> the row is not drawn")
    eq(t, state({ source = "" }), "off", "an empty source is no source")
    eq(t, state({ source = "   " }), "off", "a whitespace source is no source")
    eq(t, state({ mesh = false }), "nomesh", "no Nexus inventory data -> a hint, never an error")
    eq(t, state({ disabled = true }), "disabled", "Conduit off on this character -> greyed")
    eq(t, state({ active = true }), "busy", "a send already in flight -> greyed")

    -- Identity is base-name, case-insensitive: the same character however spelled.
    eq(t, state({ me = "BANKALT" }), "armed", "capitalisation does not change who you are")
    eq(t, state({ me = "Bankalt-Whitemane" }), "armed", "nor does a realm suffix on the name")
    eq(t, state({ source = "Bankalt-Whitemane", me = "Bankalt" }), "armed",
       "nor one on the stored source")
    eq(t, state({ me = "Bankalt2" }), "elsewhere", "a different character is a different character")
    eq(t, state({ me = NIL }), "elsewhere", "an unknown character is never the source")

    -- ── WHO you are is decided before WHAT data exists ────────────────────────
    eq(t, state({ me = "Someoneelse", mesh = false }), "elsewhere",
       "the other nine characters are told who sends, not about Nexus")

    -- ── the hints ─────────────────────────────────────────────────────────────
    check(t, hint({ me = "Someoneelse" }):find("Bankalt", 1, true) ~= nil,
       "the elsewhere hint NAMES the source")
    check(t, hint({ mesh = false }):find("Nexus", 1, true) ~= nil,
       "the no-data hint names what is missing")
    eq(t, hint(), nil, "an armed row needs no hint")
    eq(t, hint({ source = NIL }), nil, "a row that is not drawn has nothing to say")

    -- ── which states draw a button at all ─────────────────────────────────────
    check(t, B.StateShowsButton("armed"), "armed draws the button")
    check(t, B.StateShowsButton("nomailbox"), "so does a greyed no-mailbox")
    check(t, B.StateShowsButton("disabled"), "so does a greyed opted-out")
    check(t, B.StateShowsButton("busy"), "so does a greyed mid-send")
    check(t, not B.StateShowsButton("off"), "off draws nothing")
    check(t, not B.StateShowsButton("elsewhere"), "elsewhere draws the hint, not the button")
    check(t, not B.StateShowsButton("nomesh"), "nor does the no-data state")

    -- ── the greyed button's tooltip reason (one assertion per state) ──────────
    -- Every state the matrix can return is pinned here, so a new state added to
    -- ButtonState without a matching sentence shows up as a silent nil below rather
    -- than as a mute greyed button in front of the player.
    eq(t, B.StateReason("nomailbox"), "Open a mailbox to send.",
       "a greyed no-mailbox button says to open a mailbox")
    eq(t, B.StateReason("disabled"), "Conduit is disabled on this character.",
       "a greyed opted-out button names the opt-out")
    eq(t, B.StateReason("busy"), "A send is already running.",
       "a greyed mid-send button says a send is running")
    eq(t, B.StateReason("armed"), nil, "an armed button has nothing to excuse")
    eq(t, B.StateReason("off"), nil, "a row that is not drawn has no button to explain")
    eq(t, B.StateReason("elsewhere"), nil, "elsewhere speaks through the hint line, not a tooltip")
    eq(t, B.StateReason("nomesh"), nil, "so does the no-data state")
    eq(t, B.StateReason(nil), nil, "an absent state never errors")

    -- The contract that binds the two together: EVERY greyed-but-drawn state must
    -- carry a reason, and no state that draws nothing may invent one.
    for _, s in ipairs({ "armed", "nomailbox", "disabled", "busy",
                         "off", "elsewhere", "nomesh" }) do
        local drawsGrey = B.StateShowsButton(s) and s ~= "armed"
        check(t, (B.StateReason(s) ~= nil) == drawsGrey,
           "reason <-> greyed-button agreement for '" .. s .. "'")
    end

    -- ── mesh readiness ────────────────────────────────────────────────────────
    check(t, not B.MeshReady(nil), "no roster at all -> not ready")
    check(t, not B.MeshReady({}), "an empty roster -> not ready")
    check(t, not B.MeshReady({ { name = "A", level = 60 } }), "a roster with no counts -> not ready")
    check(t, B.MeshReady({ { name = "A" }, { name = "B", counts = {} } }),
       "one owner carrying an itemCounts map is enough")
    check(t, not B.MeshReady({ { name = "A", counts = "nope" } }), "junk where counts should be -> not ready")

    return report(t, verbose)
end)

ns:RegisterSelfTest("boon-queue", function(verbose)
    local t = newT("boon-queue")
    local B = ns.Boons

    -- ── stock counting off live bag stacks ────────────────────────────────────
    local stacks = { { bag = 0, slot = 1, itemID = 184937, count = 10 },
                     { bag = 0, slot = 5, itemID = 184937, count = 8 },
                     { bag = 2, slot = 3, itemID = 184937, count = 1 } }
    eq(t, B.CountStock(stacks, 184937), 19, "stock is the sum of every mailable stack")
    eq(t, B.CountStock({}, 184937), 0, "no stacks -> no stock")
    eq(t, B.CountStock(nil, 184937), 0, "nil stacks -> no stock, never an error")
    eq(t, B.CountStock({ { itemID = 6948, count = 5 } }, 184937), 0, "another item is not stock")
    eq(t, B.CountStock({ { itemID = 184937, count = "x" },
                         { itemID = 184937, count = -3 } }, 184937), 0, "junk counts are zero")

    -- ── the queue: one mail per funded target, drawn out of real slots ────────
    local plan = B.BuildPlan(
        { { name = "Orn", level = 60, counts = { [184937] = 0 } },
          { name = "Poonyx", level = 60, counts = { [184937] = 3 } },
          { name = "Shalk", level = 60, counts = { [184937] = 9 } } },
        { source = "Bankalt", faction = "Alliance", stock = B.CountStock(stacks, 184937) })
    local q = B.BuildQueue(plan, stacks, { maxAttach = 12, subject = "Daseeki Conduit" })

    eq(t, #q, 3, "three funded targets -> three mails")
    eq(t, q[1].recipient, "Orn", "the mails are in plan (descending-need) order")
    eq(t, q[1].units, 10, "Orn's mail carries ten boons")
    eq(t, #q[1].stacks, 1, "...out of the one slot that could cover it")
    eq(t, q[1].stacks[1].count, 10, "...as a whole ten-stack")
    eq(t, q[2].recipient, "Poonyx", "Poonyx is next")
    eq(t, q[2].units, 7, "...carrying seven")
    eq(t, q[2].stacks[1].slot, 5, "...drawn from the NEXT slot, the first being spent")
    eq(t, q[2].stacks[1].count, 7, "...as a partial split of that stack")
    eq(t, q[2].stacks[1].exact, true,
       "...marked exact, which is what tells the engine to SPLIT rather than take it all")
    eq(t, q[1].stacks[1].exact, true,
       "even a whole-stack draw is exact — a top-up sends the planned number, never more")
    eq(t, q[3].units, 1, "Shalk gets the last one")
    eq(t, q[3].stacks[1].slot, 5, "...out of what Poonyx left in slot 5")
    eq(t, q[3].stacks[1].count, 1, "...one boon")
    eq(t, q[1].subject, "Daseeki Conduit", "every mail carries the addon's subject")
    check(t, q[1].unitLabel and q[1].unitLabel:find("Chronoboon", 1, true) ~= nil,
       "the mail names its unit, so the engine can say '7 Chronoboon Displacers'")

    -- A need that spans several slots is split across attachments, in bag order.
    local many = { { bag = 0, slot = 1, itemID = 184937, count = 2 },
                   { bag = 0, slot = 2, itemID = 184937, count = 3 },
                   { bag = 0, slot = 3, itemID = 184937, count = 9 } }
    local one = B.BuildQueue(
        B.BuildPlan({ { name = "Orn", level = 60, counts = { [184937] = 0 } } },
                    { source = "S", stock = 14 }), many, {})
    eq(t, #one, 1, "one target -> one mail")
    eq(t, #one[1].stacks, 3, "...spanning the three slots it took to fill")
    eq(t, one[1].stacks[3].count, 5, "...the last of which is a partial draw")
    eq(t, one[1].units, 10, "...ten boons in total")

    -- Nothing funded -> nothing queued (the confirm popup is never raised on air).
    eq(t, #B.BuildQueue(B.BuildPlan({ { name = "Orn", level = 60, counts = { [184937] = 0 } } },
        { source = "S", stock = 0 }), stacks, {}), 0, "an unfunded plan queues no mails")
    eq(t, #B.BuildQueue(nil, nil, nil), 0, "nil inputs queue nothing, and do not error")
    eq(t, #B.BuildQueue({ targets = {} }, stacks, {}), 0, "an empty plan queues nothing")

    -- The attachment cap still binds, even here (a need of ten out of ten 1-stacks).
    local ones = {}
    for i = 1, 20 do ones[i] = { bag = 0, slot = i, itemID = 184937, count = 1 } end
    local capped = B.BuildQueue(
        B.BuildPlan({ { name = "Orn", level = 60, counts = { [184937] = 0 } } },
                    { source = "S", stock = 20 }), ones, { maxAttach = 4 })
    eq(t, #capped[1].stacks, 4, "no mail exceeds the attachment cap")
    eq(t, capped[1].units, 4, "...and the mail reports what it can really carry")

    -- ── the completion line ───────────────────────────────────────────────────
    local full = B.BuildPlan({ { name = "Orn", level = 60, counts = { [184937] = 0 } } },
                             { source = "S", stock = 10 })
    check(t, B.FinishLine(full, { units = 10, mails = 1 }):find("10", 1, true) ~= nil,
       "the completion line says how many went")
    check(t, B.FinishLine(full, { units = 10, mails = 1 }):find("short", 1, true) == nil,
       "...and says nothing about a shortfall when there was none")
    local part = B.BuildPlan({ { name = "Orn", level = 60, counts = { [184937] = 0 } } },
                             { source = "S", stock = 4 })
    check(t, B.FinishLine(part, { units = 4, mails = 1 }):find("6 short", 1, true) ~= nil,
       "a shortfall is repeated in the completion line, not only in the preview")
    check(t, pcall(B.FinishLine, nil, nil), "a missing plan never breaks the completion line")

    -- ── the confirm preview names every target, every amount, every age ───────
    local NOW = 1700000000
    local previewPlan = B.BuildPlan({
        { name = "Orn",    level = 60, counts = { [184937] = 0 }, countsAt = NOW - 7200 },
        { name = "Poonyx", level = 60, counts = { [184937] = 3 }, countsAt = NOW - 60 },
        { name = "Shalk",  level = 60, counts = { [184937] = 9 } },
        { name = "Ghost",  level = 60 },
        { name = "Mystery",level = nil },
        { name = "Full",   level = 60, counts = { [184937] = 10 } },
    }, { source = "Bankalt", faction = "Alliance", stock = 12, now = NOW })
    local text = B.PreviewText(previewPlan)
    for _, name in ipairs({ "Orn", "Poonyx", "Shalk", "Ghost" }) do
        check(t, text:find(name, 1, true) ~= nil, "the preview names " .. name)
    end
    check(t, text:find("Mystery", 1, true) ~= nil,
       "...and NAMES the character it left out for an unknown level")
    check(t, text:find("2h", 1, true) ~= nil, "the preview carries each count's age")
    check(t, text:find("no inventory data", 1, true) ~= nil,
       "...and says so outright when there is no snapshot at all")
    check(t, text:find("short", 1, true) ~= nil, "the shortfall is on the preview")
    check(t, text:find("biggest need is filled first", 1, true) ~= nil,
       "...next to the rule that decides who goes without")
    check(t, text:find("include the bank", 1, true) ~= nil,
       "the bank caveat is stated where the decision is made")
    check(t, text:find("1 skipped", 1, true) ~= nil,
       "the already-stocked character is summarised as a count, not listed name by name")
    check(t, not text:find("|c", 1, true), "with no colour source, the preview is plain text")

    local wrapped = B.PreviewText(previewPlan, { wrap = function(tok, s) return "<" .. tok .. ">" .. tostring(s) end })
    check(t, wrapped:find("<text>Orn", 1, true) ~= nil, "a colour source is used when there is one")
    check(t, pcall(B.PreviewText, B.BuildPlan(nil, nil)), "an empty plan still previews")

    return report(t, verbose)
end)

-- ── Suite: the outbound ledger (ledger.lua) ───────────────────────────────────
--
-- The rules that stop an interrupted run over-mailing on re-run. All pure: what
-- goes in, what comes out, and what a plan does with it. The end-to-end drive
-- (a real run, interrupted, resumed) lives in the headless harness, which can
-- stand up a mailbox; this is the row-by-row contract, and it runs in game too.
ns:RegisterSelfTest("ledger", function(verbose)
    local t = newT("ledger")
    local L = ns.Ledger
    if not L then check(t, false, "ledger.lua is loaded"); return report(t, verbose) end

    local ITEM, NOW, DAY = 184937, 1700000000, 86400

    -- keys fold the way the planner's do, so a ledger row and a roster row for the
    -- same character always meet.
    eq(t, L.Key("Erro-Whitemane"), "erro", "a realm suffix is folded away")
    eq(t, L.Key("  ERRO "), "erro", "...as are case and whitespace")
    eq(t, L.Key(nil), "", "junk folds to a key that matches nobody")

    -- what may be recorded
    local e = {}
    check(t, L.Add(e, "Erro", ITEM, 7, NOW) ~= nil, "a well-formed send is recorded")
    check(t, L.Add(e, "", ITEM, 7, NOW) == nil, "a nameless send is not")
    check(t, L.Add(e, "Erro", ITEM, 0, NOW) == nil, "nor a zero quantity")
    check(t, L.Add(e, "Erro", nil, 7, NOW) == nil, "nor a send with no item")
    eq(t, #e, 1, "...and the refusals leave the ledger alone")

    -- in flight, by character and by item
    L.Add(e, "erro-whitemane", ITEM, 2, NOW)
    L.Add(e, "Poonyx", ITEM, 3, NOW)
    L.Add(e, "Erro", 6948, 1, NOW)
    local f = L.InFlight(e, ITEM, NOW)
    eq(t, f["erro"], 9, "two mails to one character add up")
    eq(t, f["poonyx"], 3, "...and other characters stay separate")
    eq(t, L.InFlight(e, 6948, NOW)["erro"], 1, "a different item is counted separately")

    -- evidence retires an entry; the wrong evidence does not
    local one = {}
    L.Add(one, "Erro", ITEM, 7, NOW)
    eq(t, #(L.Reconcile(one, { erro = { count = 10, at = NOW - 60 } }, NOW)), 1,
       "a snapshot from BEFORE the send proves nothing")
    eq(t, #(L.Reconcile(one, { erro = { count = 3, at = NOW + 60 } }, NOW + 60)), 1,
       "a newer snapshot that does not show the goods proves nothing")
    local kept, retired = L.Reconcile(one, { erro = { count = 10, at = NOW + 3700 } }, NOW + 3700)
    eq(t, #kept, 0, "a newer snapshot showing the quantity retires the entry")
    eq(t, retired[1].why, "delivered", "...and says why")

    -- the TTL backstop (Blizzard's own mail expiry)
    eq(t, #(L.Reconcile(one, {}, NOW + 29 * DAY)), 1, "29 days on: still in the post")
    local _, old = L.Reconcile(one, {}, NOW + 31 * DAY)
    eq(t, old[1].why, "expired", "31 days on: retired by the TTL")
    eq(t, L.InFlight(one, ITEM, NOW + 31 * DAY)["erro"], nil,
       "...and an expired entry stops suppressing a top-up at once, sweep or no sweep")

    -- what a plan does with it: in-flight is OWNED
    local B = ns.Boons
    local stockedByPost = B.BuildPlan(
        { { name = "Erro", level = 60, counts = { [ITEM] = 9 }, countsAt = NOW } },
        { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
          inFlight = { erro = 1 }, now = NOW })
    eq(t, #stockedByPost.targets, 0, "has 9 with 1 in the post -> nothing to send")
    eq(t, stockedByPost.skipped[1].reason, "has 9, 1 in transit",
       "...and the reason names the mail rather than pretending they are stocked")

    local partly = B.BuildPlan(
        { { name = "Erro", level = 60, counts = { [ITEM] = 4 }, countsAt = NOW } },
        { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
          inFlight = { erro = 2 }, now = NOW })
    eq(t, partly.targets[1].send, 4, "a partial top-up already posted is subtracted")
    eq(t, partly.targets[1].inTransit, 2, "...and the row carries how much is coming")

    local text = B.PreviewText(B.BuildPlan(
        { { name = "Erro", level = 60, counts = { [ITEM] = 9 }, countsAt = NOW },
          { name = "Orn",  level = 60, counts = { [ITEM] = 0 }, countsAt = NOW } },
        { source = "Bankalt", faction = "Alliance", stock = 99, itemID = ITEM,
          inFlight = { erro = 1 }, now = NOW }))
    check(t, text:find("has 9, 1 in transit", 1, true) ~= nil,
       "the preview states the in-transit count in as many words")
    check(t, text:find("nothing to send", 1, true) ~= nil,
       "...and that it is therefore not being sent")

    -- the debug view
    local rows = L.Describe(e, NOW + 7200, B.FormatAge)
    check(t, #rows == 4, "every valid entry gets a debug row")
    check(t, rows[1]:find("2h", 1, true) ~= nil, "...carrying its age")

    check(t, pcall(L.InFlight, nil, ITEM, NOW), "nil inputs never error")
    check(t, pcall(L.Reconcile, nil, nil, nil), "...on any of the pure entry points")

    return report(t, verbose)
end)
