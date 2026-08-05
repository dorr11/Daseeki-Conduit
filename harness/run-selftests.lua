-- =====================================================================
-- Daseeki-Conduit headless self-test harness (REAL Lua 5.1)
--
-- Follows the Daseeki suite harness pattern (see Daseeki-Buff-Tracker/harness):
-- stub the minimal WoW API, load the REAL addon files under a real Lua
-- interpreter, drive the REAL code, exit non-zero on any failure.
--
-- Conduit already owns a self-test REGISTRY (core.lua ns:RegisterSelfTest, driven
-- in game by /conduit debug selftest), so this harness does not reimplement any
-- assertion: it loads the shipped suites and RUNS them, then adds the gates that
-- only make sense outside the game (parse, firewall, SavedVariables additivity,
-- and an end-to-end auto-friend drive against a stubbed C_FriendList).
--
-- Gates:
--   0        TOC PARSE   loadfile (parse only) every .lua the .toc lists.
--   FW       FIREWALL    no third-party addon identifier in the repo's text.
--   SUITES   the shipped pure suites (rules / batches / gold / recipients /
--            mail queue / Raid-Prep migration / auto-friend / sync bridge /
--            Nexus alt names).
--   SV       InitDB adds the auto-friend keys to a PRE-EXISTING save without
--            touching rules, and without a schema bump (additive-only).
--   FRIEND   the REAL Friends.RunPass against a stubbed C_FriendList:
--            adds once, marks, never re-adds — including after the user
--            deliberately unfriends — and stops cleanly at the list cap.
--   MUT      MUTATION TEST of the boon plan builder: twelve one-operator
--            mutants of boons.lua, every one of which must be killed by the
--            checks. A survivor is a rule the suite only appears to cover.
--
-- Usage:  lua5.1 run-selftests.lua [CONDUIT_DIR]   (exit 0 = ALL PASS)
-- =====================================================================

local realprint = print   -- kept before the addon's print is swallowed below

local HARNESS_DIR = (arg[0]:match("^(.*)[\\/][^\\/]+$")) or "."
local function slash(p) return (p:gsub("\\", "/")) end
HARNESS_DIR = slash(HARNESS_DIR)
local DIR = slash(arg[1] or (HARNESS_DIR .. "/.."))
local function P(rel) return DIR .. "/" .. rel end

local TOC_FILE   = "Daseeki-Conduit.toc"
local ADDON_NAME = "Daseeki-Conduit"

local FAILS = 0
local function fail(m) FAILS = FAILS + 1; realprint("  FAIL  " .. m) end
local function ok(m)   realprint("  ok    " .. m) end
local function ck(cond, m) if cond then ok(m) else fail(m) end end

local function readFile(path)
    local fh = io.open(path, "r"); if not fh then return nil end
    local s = fh:read("*a"); fh:close(); return s
end

----------------------------------------------------------------------
-- GATE 0: TOC PARSE
----------------------------------------------------------------------
local function readTocLuaFiles(tocPath)
    local fh = io.open(tocPath, "r"); if not fh then return nil end
    local out = {}
    for line in fh:lines() do
        line = line:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and line:lower():sub(-4) == ".lua" then
            out[#out + 1] = (line:gsub("\\", "/"))
        end
    end
    fh:close()
    return out
end

realprint("=== GATE 0: toc parse (loadfile every .lua in " .. TOC_FILE .. ") ===")
local TOC_LUA = readTocLuaFiles(P(TOC_FILE))
if not TOC_LUA or #TOC_LUA == 0 then realprint("  FAIL  cannot read .toc lua list"); os.exit(1) end
for _, rel in ipairs(TOC_LUA) do
    local chunk, err = loadfile(P(rel))
    if chunk then ok("parse " .. rel) else fail("parse " .. rel .. " -> " .. tostring(err)) end
end
if FAILS > 0 then realprint("=== GATE 0: FAIL (a file does not compile) ==="); os.exit(1) end
realprint("=== GATE 0: PASS ===\n")

----------------------------------------------------------------------
-- GATE FW: CLEAN-ROOM FIREWALL
--
-- Product identifiers of absorption-target / third-party addons (not generic
-- words). Conduit is an ORIGINAL Daseeki addon; the only other addons it may name
-- are Daseeki's own (Raid Prep, Nexus, Core), which are not on this list.
----------------------------------------------------------------------
local FORBIDDEN = {
    "portalmage", "totemtimers", "druidbar", "pallypower",
    "weakauras", "weakaurassaved", "aura_env",
    "shadownetwork", "novainstancetracker", "novaworldbuffs",
    "bigwigs", "elvui", "bartender4", "dominos",
    "postal", "tradeskillmaster", "altoholic", "baggins", "bagnon",
}
realprint("=== GATE FW: clean-room firewall ===")
local FW_FILES = { "CHANGELOG.md", "README.md", TOC_FILE }
for _, rel in ipairs(TOC_LUA) do FW_FILES[#FW_FILES + 1] = rel end
for _, rel in ipairs(FW_FILES) do
    local src = readFile(P(rel))
    if src then
        local lower = src:lower()
        local bad = {}
        for _, tok in ipairs(FORBIDDEN) do
            if lower:find(tok, 1, true) then bad[#bad + 1] = tok end
        end
        if #bad > 0 then fail(rel .. " contains: " .. table.concat(bad, ", ")) else ok(rel) end
    end
end
if FAILS > 0 then realprint("=== GATE FW: FAIL ==="); os.exit(1) end
realprint("=== GATE FW: PASS ===\n")

----------------------------------------------------------------------
-- Minimal WoW stub — only what the loaded files touch AT LOAD, plus the handful
-- the pure/driven paths read at call time. Deliberately NOT loaded here:
-- panel.lua / options.lua (DaseekiUI frame construction) and mail.lua (live mail
-- API); nothing they own is pure, and GATE 0 already proves they compile.
----------------------------------------------------------------------
local CHAT = {}
_G.print = function(...)                       -- capture the addon's chat output
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    CHAT[#CHAT + 1] = table.concat(parts, " ")
end
_G.geterrorhandler = function() return function(err) error(err, 0) end end
_G.CreateFrame = function()
    local f = {}
    function f:RegisterEvent() end
    function f:UnregisterEvent() end
    function f:SetScript(_, fn) self._onEvent = fn end
    function f:GetScript() return self._onEvent end
    return f
end
_G.SlashCmdList = {}
_G.UnitName          = function() return _G.__TESTNAME or "Hero" end
_G.GetRealmName      = function() return "Whitemane" end
_G.UnitFactionGroup  = function() return _G.__TESTFACTION or "Alliance" end
_G.strfind, _G.strmatch, _G.strsub, _G.format =
    string.find, string.match, string.sub, string.format

local function chatFind(needle)
    for _, line in ipairs(CHAT) do if line:find(needle, 1, true) then return line end end
    return nil
end
local function chatClear() for i = #CHAT, 1, -1 do CHAT[i] = nil end end

----------------------------------------------------------------------
-- Load the REAL addon files into one shared namespace, in .toc order.
----------------------------------------------------------------------
local ns = {}
local LOAD = { "core.lua", "rules.lua", "migrate.lua", "network.lua", "boons.lua",
               "friends.lua", "syncbridge.lua", "selftest.lua" }
for _, rel in ipairs(LOAD) do
    local chunk, err = loadfile(P(rel))
    if not chunk then realprint("  FAIL  loadfile " .. rel .. " -> " .. tostring(err)); os.exit(2) end
    local good, rerr = pcall(chunk, ADDON_NAME, ns)
    if not good then realprint("  FAIL  executing " .. rel .. " -> " .. tostring(rerr)); os.exit(2) end
end

----------------------------------------------------------------------
-- GATE SUITES: run the shipped self-test registry (the same code
-- /conduit debug selftest runs in game).
----------------------------------------------------------------------
realprint("=== GATE SUITES: ns:RunSelfTests (the shipped pure suites) ===")
chatClear()
local suitesOk, suitesErr = pcall(function() return ns:RunSelfTests(true) end)
if not suitesOk then
    fail("RunSelfTests errored -> " .. tostring(suitesErr))
else
    for _, line in ipairs(CHAT) do
        if line:find("FAIL", 1, true) then realprint("  " .. line) end
    end
    ck(chatFind("ALL SUITES PASS") ~= nil, "every registered suite passes")
    -- A suite that silently fails to register would still report ALL PASS, so name
    -- the ones whose files this harness loads for their own sake.
    ck(chatFind("auto-friend:") ~= nil, "the auto-friend suite ran")
    ck(chatFind("sync-bridge:") ~= nil, "the sync-bridge suite ran")
    ck(chatFind("network:") ~= nil, "the network suite ran")
    ck(chatFind("mailbox-close:") ~= nil, "the mailbox-teardown suite ran")
    ck(chatFind("boon-plan:") ~= nil, "the boon plan-builder suite ran")
    ck(chatFind("boon-arming:") ~= nil, "the boon arming-matrix suite ran")
    ck(chatFind("boon-queue:") ~= nil, "the boon queue/preview suite ran")
end

----------------------------------------------------------------------
-- The teardown coordinator's WIRING, which the pure suite cannot see: the panel
-- and the send engine must actually be ON the live closer list, or "the panel
-- closes with the mail window" is true only in the test. panel.lua / mail.lua are
-- not loadable here (DaseekiUI frames + live mail API), so assert the registration
-- calls exist in the shipped source instead — a regression that drops one back to
-- its own MAIL_CLOSED handler, or to none at all, fails here.
----------------------------------------------------------------------
do
    local function sourceHas(rel, needle, label)
        local src = readFile(P(rel))
        ck(src ~= nil and src:find(needle, 1, true) ~= nil, label)
    end
    sourceHas("panel.lua", "ns:RegisterMailboxCloser",
        "panel.lua registers a mailbox closer (the panel hides with the mail window)")
    sourceHas("mail.lua", "ns:RegisterMailboxCloser",
        "mail.lua registers a mailbox closer (the batch aborts with the mail window)")
    sourceHas("mail.lua", 'StaticPopup_Hide("DASEEKI_CONDUIT_SEND_CONFIRM")',
        "...and dismisses the send-confirm popup with it")
    -- Both MailFrame scripts now go in through the install-once guard rather than a
    -- bare mf:HookScript, so the pin follows them there (GATE HDR (d) checks the
    -- guard itself; the mailbox-close suite drives it for real).
    sourceHas("core.lua", '{ "OnHide", function()',
        "core.lua hooks MailFrame OnHide as well as MAIL_CLOSED")
    -- THERE IS ONE SEND PATH. Boon replenishment must ride mail.lua's confirm-first
    -- engine, not grow a second one; a regression that reaches for SendMail from
    -- boons.lua (or skips the confirm popup) fails right here.
    sourceHas("boons.lua", "ns.Mail.RunQueue",
        "boons.lua sends through the shared mail engine")
    do
        local src = readFile(P("boons.lua")) or ""
        ck(src:find("SendMail", 1, true) == nil,
           "...and never calls SendMail itself (the confirm gate cannot be routed around)")
        ck(src:find("StaticPopup_Show", 1, true) == nil,
           "...nor raises its own send popup")
    end
    sourceHas("mail.lua", "SplitContainerItem",
        "mail.lua can attach PART of a stack (a top-up to ten is not a whole stack)")
end
if FAILS > 0 then realprint("=== GATE SUITES: FAIL ==="); os.exit(1) end
realprint("=== GATE SUITES: PASS ===\n")

----------------------------------------------------------------------
-- GATE SV: the auto-friend keys are ADDITIVE.
--
-- A user sitting on a shipped v0.1.0 save must gain the new keys and lose
-- nothing — and the schema must NOT move, because nothing was reshaped.
----------------------------------------------------------------------
realprint("=== GATE SV: InitDB is additive on a pre-existing save ===")
chatClear()
_G.DaseekiConduitDB = {
    schema        = 1,
    rules         = { { id = 1, name = "Ore to Bank", enabled = true, kind = "items",
                        recipient = "Bankalt", filter = { mode = "category", classID = 7 } } },
    settings      = { __sentinel = true },
    disabledChars = { ["Someone-Whitemane"] = true },
    nextRuleId    = 2,
    migratedRaidPrep = true,
}
ns:InitDB()
local db = _G.DaseekiConduitDB
ck(db.schema == 1, "schema NOT bumped (the new keys are additive)")
ck(#db.rules == 1 and db.rules[1].recipient == "Bankalt", "existing rules preserved untouched")
ck(db.settings.__sentinel == true, "existing settings preserved")
ck(db.disabledChars["Someone-Whitemane"] == true, "per-character disables preserved")
ck(db.migratedRaidPrep == true, "the Raid Prep migration marker survives")
ck(type(db.friendDir) == "table", "friendDir created")
ck(db.friendDirRev == 1, "friendDirRev seeded")
ck(type(db.friended) == "table", "friended (per-character markers) created")
realprint("=== GATE SV: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE FRIEND: drive the REAL Friends.RunPass against a stubbed C_FriendList.
----------------------------------------------------------------------
realprint("=== GATE FRIEND: real Friends.RunPass (add once, mark, never re-add) ===")
local F = ns.Friends

local FRIENDS, ADDED = {}, {}
_G.C_FriendList = {
    GetNumFriends        = function() return #FRIENDS end,
    GetFriendInfoByIndex = function(i) return FRIENDS[i] and { name = FRIENDS[i] } or nil end,
    AddFriend            = function(name) ADDED[#ADDED + 1] = name; FRIENDS[#FRIENDS + 1] = name end,
    ShowFriends          = function() end,
}
-- No C_Timer: SchedulePass then runs inline, which is exactly what we want here.

-- (a) settings default + the local-only path (no Nexus on this _G).
ck(F.IsEnabled() == true, "(a) auto-friend defaults ON (absent key reads as enabled)")
ck(ns.SyncBridge.Available() == false, "(a) no Nexus present -> the sync bridge is inactive")
ck(ns.SyncBridge.Publish() == false, "(a) ...and publishing is a clean no-op, not an error")

-- (b) first Refresh stamps the directory from this character's rules and bumps rev.
chatClear()
ck(F.Refresh() == true, "(b) first Refresh stamps the directory")
ck(db.friendDir["bankalt-whitemane"] ~= nil, "(b) the rule's recipient is in the directory")
ck(db.friendDir["bankalt-whitemane"].faction == "Alliance", "(b) attributed with this character's faction")
ck(db.friendDir["bankalt-whitemane"].realm == "whitemane", "(b) attributed with this character's realm")
ck(db.friendDirRev == 2, "(b) revision bumped for the mesh")
ck(F.Refresh() == false, "(b) a second Refresh changes nothing")
ck(db.friendDirRev == 2, "(b) ...and does not bump the revision")

-- (c) the pass adds the recipient exactly once and says so.
chatClear()
F.RunPass()
ck(#ADDED == 1 and ADDED[1] == "Bankalt", "(c) Bankalt added to the friends list")
ck(db.friended["Hero-Whitemane"]["bankalt-whitemane"] == true, "(c) per-character marker written")
ck(chatFind("without Blizzard's confirmation") ~= nil, "(c) one informative chat line")

-- (d) re-running is silent and adds nothing (already a friend + marked).
chatClear()
F.RunPass()
ck(#ADDED == 1, "(d) a second pass adds nothing")
ck(#CHAT == 0, "(d) ...and says nothing (no re-nag)")

-- (e) THE OWNER RULE: a deliberate unfriend is never undone.
chatClear()
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end     -- user removed them by hand
F.RunPass()
ck(#ADDED == 1, "(e) an unfriended recipient is NOT re-added (the marker is intent)")
ck(#CHAT == 0, "(e) ...and nothing is said about it")

-- (f) the current character is never friended, even when named by a rule.
chatClear()
db.rules[#db.rules + 1] = { id = 2, name = "Self", enabled = true, kind = "gold",
                            recipient = "Hero", keepCopper = 0 }
F.Refresh()
ck(db.friendDir["hero-whitemane"] == nil, "(f) the logged-in character never enters the directory")
F.RunPass()
ck(#ADDED == 1, "(f) ...and is never added")

-- (g) another character on the account: fresh markers, and it friends the recipient
--     the first character configured (account-wide directory, per-character marker).
chatClear()
_G.__TESTNAME = "Alt"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.RunPass()
ck(#ADDED == 2 and ADDED[2] == "Bankalt", "(g) a second character friends the same recipient")
ck(db.friended["Alt-Whitemane"]["bankalt-whitemane"] == true, "(g) its own marker is written")
ck(db.friended["Hero-Whitemane"]["bankalt-whitemane"] == true, "(g) the first character's marker is untouched")

-- (h) a HORDE character on the same account skips the Alliance recipient silently.
chatClear()
_G.__TESTNAME    = "Hordie"
_G.__TESTFACTION = "Horde"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.RunPass()
ck(#ADDED == 2, "(h) a cross-faction recipient is skipped")
ck(#CHAT == 0, "(h) ...silently")
ck(db.friended["Hordie-Whitemane"]["bankalt-whitemane"] == nil,
   "(h) ...and NOT marked, so a same-faction character can still act on it")

-- (i) the cap: one chat line, no add, no marker (a freed slot retries later).
chatClear()
_G.__TESTNAME    = "Capped"
_G.__TESTFACTION = "Alliance"
_G.MAX_FRIENDS   = 1
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
FRIENDS[1] = "Someoneelse"
F.RunPass()
ck(#ADDED == 2, "(i) nothing added once the list is full")
ck(chatFind("friends list is full") ~= nil, "(i) one chat line explains why")
ck(db.friended["Capped-Whitemane"]["bankalt-whitemane"] == nil,
   "(i) ...and no marker, so freeing a slot lets it retry")
_G.MAX_FRIENDS = nil

-- (j) the setting off is a hard stop.
chatClear()
_G.__TESTNAME = "OptedOut"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
F.SetEnabled(false)
ck(F.IsEnabled() == false, "(j) the toggle reads back off")
F.RunPass()
ck(#ADDED == 2, "(j) the pass does nothing while off")
ck(#CHAT == 0, "(j) ...and says nothing")
F.SetEnabled(true)

-- (k) a peer's directory reaches the pass through the sync bridge's consumer path.
chatClear()
_G.__TESTNAME = "Reader"
for i = #FRIENDS, 1, -1 do FRIENDS[i] = nil end
ns.SyncBridge.OnRemote("account-b", { v = 1, recipients = {
    ["peerbank-whitemane"] = { name = "Peerbank", realm = "whitemane", faction = "Alliance" },
    ["farbank-faerlina"]   = { name = "Farbank",  realm = "faerlina",  faction = "Alliance" },
} })
F.RunPass()
local sawPeer = false
for _, n in ipairs(ADDED) do if n == "Peerbank" then sawPeer = true end end
ck(sawPeer, "(k) a peer account's recipient is friended here")
for _, n in ipairs(ADDED) do
    if n == "Farbank" then fail("(k) an other-realm peer recipient must never be added") end
end
ok("(k) an other-realm peer recipient is skipped")
ck(db.friendDir["peerbank-whitemane"] == nil,
   "(k) a peer's entry is never written into OUR saved directory")

-- (l) a peer payload from a newer build is refused rather than guessed at.
chatClear()
_G.__TESTNAME = "Reader2"
local beforeRemote = F.remote["account-c"]
ns.SyncBridge.OnRemote("account-c", { v = 99, recipients = {
    ["future-whitemane"] = { name = "Future", realm = "whitemane", faction = "Alliance" } } })
ck(F.remote["account-c"] == beforeRemote, "(l) a newer payload version is dropped")
ck(tostring(ns.SyncBridge._lastReject):find("newer") ~= nil, "(l) ...with a readable reason recorded")

realprint("=== GATE FRIEND: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE MUT: MUTATION-TEST THE BOON PLAN BUILDER
--
-- The plan builder decides who receives ten scarce consumables and who receives
-- none, off a snapshot that is always a little out of date. "The suite is green"
-- is not evidence that the suite would NOTICE a broken builder, so this gate
-- proves it: each mutant below is boons.lua with one operator flipped, and every
-- one of them MUST be killed by the checks. A surviving mutant means a rule the
-- tests only appear to cover, and it fails the build.
--
-- The checks below deliberately duplicate the shipped suite's core assertions
-- rather than calling into it: the shipped suite prints through ns:Print and
-- reports pass/fail counts, whereas a mutation gate needs one boolean per mutant.
----------------------------------------------------------------------
realprint("=== GATE MUT: mutation-test the boon plan builder ===")
do
    local ITEM = 184937
    local function ch(name, level, have, extra)
        local e = { name = name, level = level }
        if have ~= nil then e.counts = { [ITEM] = have } end
        for k, v in pairs(extra or {}) do e[k] = v end
        return e
    end
    -- The load-bearing behaviour, as one boolean. Any error counts as a kill.
    local function planChecks(B)
        local function run()
            local function P(entries, over)
                local o = { source = "Bankalt", faction = "Alliance", stock = 999, itemID = ITEM }
                for k, v in pairs(over or {}) do o[k] = v end
                return B.BuildPlan(entries, o)
            end
            local function at(p, i) return p.targets[i] end
            local function order(p)
                local out = {}
                for _, x in ipairs(p.targets) do out[#out + 1] = x.name .. ":" .. x.send end
                return table.concat(out, ",")
            end

            -- the owner's example, verbatim
            local mesh = { ch("Poonyx", 60, 3), ch("Shalk", 60, 9), ch("Orn", 60, 0) }
            local p = P(mesh)
            if #p.targets ~= 3 then return false end
            if order(p) ~= "Orn:10,Poonyx:7,Shalk:1" then return false end
            if p.totalNeed ~= 18 or p.totalSend ~= 18 or p.shortfall ~= 0 then return false end

            -- rationing under a shortfall
            local s = P(mesh, { stock = 12 })
            if order(s) ~= "Orn:10,Poonyx:2,Shalk:0" then return false end
            if s.totalSend ~= 12 or s.shortfall ~= 6 or s.remaining ~= 0 then return false end

            -- filters
            -- Zerolevel is here on purpose: Nexus writes level 0 for "never
            -- captured", so 0 must land in unknownLevel and NOT in under-level.
            local f = P({ ch("Bankalt", 60, 0), ch("Lowbie", 30, 0), ch("Nolevel", nil, 0),
                          ch("Zerolevel", 0, 0),
                          ch("Hordie", 60, 0, { faction = "Horde" }), ch("Keep", 60, 0),
                          ch("Stocked", 60, 10) })
            if #f.targets ~= 1 or at(f, 1).name ~= "Keep" then return false end
            if f.counts.source ~= 1 or f.counts.level ~= 1 or f.counts.unknownLevel ~= 2
               or f.counts.faction ~= 1 or f.counts.stocked ~= 1 then return false end

            -- an absent count is a full ten
            local g = P({ ch("Ghost", 60, nil) })
            if #g.targets ~= 1 or at(g, 1).send ~= 10 or at(g, 1).have ~= 0 then return false end

            -- equal needs are ordered by name
            if order(P({ ch("zeta", 60, 4), ch("Alpha", 60, 4) })) ~= "Alpha:6,zeta:6" then return false end

            -- ages
            if B.FormatAge(89) ~= "just now" or B.FormatAge(90) ~= "1m" then return false end
            if B.FormatAge(3600) ~= "1h" or B.FormatAge(172800) ~= "2d" then return false end
            local NOW = 1700000000
            local a = B.BuildPlan({ ch("Aged", 60, 1, { countsAt = NOW - 7200 }) },
                                  { source = "S", stock = 99, itemID = ITEM, now = NOW })
            if at(a, 1).ageText ~= "2h" then return false end
            return true
        end
        local okRun, res = pcall(run)
        return okRun and res == true
    end

    local SRC = readFile(P("boons.lua"))
    ck(SRC ~= nil, "boons.lua is readable")

    -- Sanity: the REAL builder must pass the very checks the mutants must fail.
    ck(planChecks(ns.Boons), "the shipped plan builder passes the mutation checks")

    -- name, exact source fragment, replacement. Each fragment must appear ONCE.
    local MUTANTS = {
        { "source filter inverted",      "if lower == srcName then",
                                         "if lower ~= srcName then" },
        { "faction filter inverted",     "side ~= srcSide then",
                                         "side == srcSide then" },
        { "unknown level admitted",      "elseif not lvl or lvl <= 0 then",
                                         "elseif not lvl or lvl < 0 then" },
        { "level boundary off by one",   "elseif lvl < minLevel then",
                                         "elseif lvl <= minLevel then" },
        { "need arithmetic flipped",     "local need = target - have",
                                         "local need = target + have" },
        { "stocked boundary off by one", "if need <= 0 then",
                                         "if need < 0 then" },
        { "rationing order reversed",    "if a.need ~= b.need then return a.need > b.need end",
                                         "if a.need ~= b.need then return a.need < b.need end" },
        { "name tiebreak reversed",      "if la ~= lb then return la < lb end\n        return a.name < b.name",
                                         "if la ~= lb then return la > lb end\n        return a.name < b.name" },
        { "stock clamp removed",         "if give > remaining then give = remaining end",
                                         "if give > remaining then give = give end" },
        { "stock never consumed",        "remaining = remaining - give",
                                         "remaining = remaining - 0" },
        { "shortfall sign flipped",      "plan.shortfall  = plan.totalNeed - plan.totalSend",
                                         "plan.shortfall  = plan.totalSend - plan.totalNeed" },
        { "age threshold moved",         'if n < 90 then return "just now" end',
                                         'if n < 900 then return "just now" end' },
    }

    local survivors = 0
    for _, m in ipairs(MUTANTS) do
        local name, from, to = m[1], m[2], m[3]
        local head, tail = SRC:find(from, 1, true)
        if not head then
            fail("MUTANT '" .. name .. "': its source fragment no longer exists (stale mutation)")
        elseif SRC:find(from, tail + 1, true) then
            fail("MUTANT '" .. name .. "': fragment is not unique (the mutation is ambiguous)")
        else
            local mutated = SRC:sub(1, head - 1) .. to .. SRC:sub(tail + 1)
            local chunk, cerr = loadstring(mutated, "@mutant:" .. name)
            if not chunk then
                ok("MUTANT killed at compile: " .. name .. " (" .. tostring(cerr) .. ")")
            else
                local mutNs = { Network = ns.Network }
                local loaded = pcall(chunk, ADDON_NAME, mutNs)
                if not loaded or type(mutNs.Boons) ~= "table" then
                    ok("MUTANT killed at load: " .. name)
                elseif planChecks(mutNs.Boons) then
                    survivors = survivors + 1
                    fail("MUTANT SURVIVED: " .. name .. " — the checks do not cover this rule")
                else
                    ok("MUTANT killed: " .. name)
                end
            end
        end
    end
    ck(survivors == 0, "every mutant of the plan builder is killed")
end
realprint("=== GATE MUT: " .. (FAILS == 0 and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
-- GATE HDR: the panel header's control cluster (gear + close).
--
-- Owner request: "can we add a settings icon next to the 'x' in conduit? update
-- the icons for both to match the suite". That is an APPEARANCE change, which a
-- headless harness cannot see — and panel.lua is deliberately never LOADED here
-- (it builds DaseekiUI frames; GATE 0 only proves it compiles). So this gate pins
-- the things that make the appearance true and that a later edit could silently
-- undo:
--
--   (a) THE ART IS OURS AND UNMODIFIED. icon-close/icon-gear are byte copies of
--       Daseeki-Nexus/textures — the same bytes Raid Prep and Bags 2.0 ship, which
--       is the whole point: the gear and the close mark are pixel-identical across
--       the suite. The digests below are the ones Raid Prep pins, independently
--       recomputed here. (A Nexus checkout is not reachable from a git worktree, so
--       the ORIGINAL cannot be diffed at test time — the digest is the portable
--       form of that diff.) Nothing is authored for this window: no glyph in the
--       cluster is new, so unlike Raid Prep's gavel there is no dev/ generator.
--
--   (b) THE HEADER USES THE GLYPH PATTERN, at the suite's metrics, with the tint
--       contract; and stock/text art survives ONLY as the no-Core fallback.
--
--   (c) THE GEAR IS THE SAME DOOR AS THE SLASH COMMAND — one ns:OpenSettings in
--       core.lua, called by both, so the hub target cannot drift between them.
----------------------------------------------------------------------
local HDR_BEFORE = FAILS
realprint("=== GATE HDR: header control cluster ===")
do
    local function readBinary(path)
        local fh = io.open(path, "rb"); if not fh then return nil end
        local s = fh:read("*a"); fh:close(); return s
    end

    -- djb2 over the whole file, kept in double-exact range (hash*33 + b < 2^53).
    local function digest(s)
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return h
    end

    -- 64x64 32bpp uncompressed true-colour, top-left origin => 18 + 64*64*4 bytes.
    -- The runtime tints the white mask with a theme token, so a paletted or 24bpp
    -- re-export would render wrong rather than merely different.
    local TGA_BYTES = 16402
    local GLYPHS = {
        { "icon-close.tga", 1198911579 },
        { "icon-gear.tga",  1303632799 },
    }
    for _, g in ipairs(GLYPHS) do
        local name, want = g[1], g[2]
        local raw = readBinary(P("art/" .. name))
        ck(raw ~= nil, "(a) art/" .. name .. " ships (copied from Daseeki-Nexus/textures)")
        if raw then
            ck(#raw == TGA_BYTES, "(a) " .. name .. " is a 64x64 32bpp TGA (" .. #raw .. " bytes)")
            ck(raw:byte(3) == 2 and raw:byte(17) == 32 and raw:byte(18) == 0x28,
               "(a) " .. name .. " header: uncompressed true-colour, 32bpp, top-left origin")
            ck(digest(raw) == want, "(a) " .. name .. " is byte-identical to the suite glyph")
        end
    end

    local src = readFile(P("panel.lua")) or ""

    -- The metrics ARE the parity: 22/2/8 is the Nexus dashboard button verbatim.
    ck(src:find("local ICONBTN    = 22", 1, true) ~= nil, "(b) 22px control button (suite parity)")
    ck(src:find("local ICON_INSET = 2", 1, true)  ~= nil, "(b) 2px glyph inset => 18x18 drawn")
    ck(src:find("local ICON_SPACE = 8", 1, true)  ~= nil, "(b) 8px gap between controls")
    ck(src:find('"Interface\\\\AddOns\\\\" .. tostring(ADDON) .. "\\\\art\\\\"', 1, true) ~= nil,
       "(b) art is loaded from the addon's OWN art/ directory")

    -- The pattern itself, and the tint contract it carries.
    ck(src:find("local function makeGlyphButton", 1, true) ~= nil, "(b) the glyph-button factory exists")
    ck(src:find("UI.FLAT_BACKDROP", 1, true) ~= nil,        "(b) the button is the suite FLAT_BACKDROP object")
    ck(src:find('UI.Color("borderLite")', 1, true) ~= nil,  "(b) borderLite edge, as Nexus/Bags/Raid Prep")
    ck(src:find('self._hot and hot or "muted"', 1, true) ~= nil,
       "(b) the GLYPH carries the hover: muted at rest, hot on enter")
    ck(src:find('hot = "danger"', 1, true) ~= nil, "(b) the close hovers danger (destructive affordance)")

    -- Both controls are built through the factory, on our own glyphs, and BOTH are
    -- the same size — the owner asked for icons that match each other, not merely
    -- icons that exist.
    for _, icon in ipairs({ "icon-close", "icon-gear" }) do
        ck(src:find('icon = "' .. icon .. '"', 1, true) ~= nil, "(b) the cluster draws " .. icon)
    end
    ck(src:find("b:SetSize(ICONBTN, ICONBTN)", 1, true) ~= nil,
       "(b) every control in the cluster is the SAME square (matching sizes)")

    -- The older-Core install must still get a working header, and stock/text art
    -- must live BELOW that marker — one drifting up into the themed path is the
    -- regression this round removes.
    ck(src:find("local function glyphCapable", 1, true) ~= nil,
       "(b) the themed path is guarded (an older Core has no FLAT_BACKDROP)")
    local markAt = src:find("NO-CORE FALLBACK", 1, true)
    ck(markAt ~= nil, "(b) the fallback branch is declared")
    if markAt then
        for _, stock in ipairs({ "Interface/Icons/", "Interface/Buttons/", 'cx:SetText("X")' }) do
            local at, bad = 0, false
            while true do
                at = src:find(stock, at + 1, true)
                if not at then break end
                if at < markAt then bad = true end
            end
            ck(not bad, "(b) stock/text art '" .. stock .. "' survives only below NO-CORE FALLBACK")
        end
    end

    -- (c) one door to the hub.
    local core = readFile(P("core.lua")) or ""
    ck(core:find("function ns:OpenSettings", 1, true) ~= nil,
       "(c) core.lua owns the single settings action")
    ck(core:find('DaseekiSuite:Open("conduit")', 1, true) ~= nil,
       "(c) ...which opens the hub's Conduit section")
    ck(src:find("ns:OpenSettings()", 1, true) ~= nil, "(c) the gear calls it")
    ck(src:find("DaseekiSuite", 1, true) == nil,
       "(c) the panel never re-derives the hub target itself")

    -- The refresh wiring this round adds, pinned where the harness can see it:
    -- panel.lua is not loaded, so its REGISTRATION is asserted textually while the
    -- guard and fan-out it depends on are driven for real in the mailbox-close suite.
    ck(src:find("ns:RegisterMailboxRefresher(", 1, true) ~= nil,
       "(d) the panel refreshes when the mail window actually becomes visible")
    ck(src:find('f:SetScript("OnShow"', 1, true) ~= nil,
       "(d) ...and whenever the panel itself is shown")
    ck(core:find('{ "OnShow", function()', 1, true) ~= nil,
       "(d) core.lua hooks MailFrame's OnShow, not just its OnHide")
    ck(core:find("ns.HookOnce(mailFrameHook, _G.MailFrame", 1, true) ~= nil,
       "(d) ...through the install-once guard (never hooked twice)")
end
local V_HDR = (FAILS == HDR_BEFORE)
realprint("=== GATE HDR: " .. (V_HDR and "PASS" or "FAIL") .. " ===\n")

----------------------------------------------------------------------
realprint("############################################################")
realprint("# Daseeki-Conduit self-tests")
realprint("#   GATE 0      toc parse             : PASS")
realprint("#   GATE FW     clean-room firewall   : PASS")
realprint("#   GATE SUITES shipped pure suites   : PASS")
realprint("#   GATE SV     additive SavedVariables : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE FRIEND real auto-friend pass : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE MUT    boon plan mutations  : " .. (FAILS == 0 and "PASS" or "FAIL"))
realprint("#   GATE HDR    header control cluster : " .. (V_HDR and "PASS" or "FAIL"))
realprint("#")
realprint("#   RESULT: " .. (FAILS == 0 and "ALL PASS" or (FAILS .. " FAILURE(S) — RED")))
realprint("############################################################")
os.exit(FAILS == 0 and 0 or 1)
